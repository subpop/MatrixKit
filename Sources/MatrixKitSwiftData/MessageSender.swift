#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// Store-backed room sends: local echoes, encrypted/plaintext dispatch,
/// reactions, edits, redacts, pins, and read markers.
///
/// Ports the retired per-room send surface onto the normalized store:
/// every send stages a local echo through the writer (confirmed by sync
/// via the shared transaction ID, failed locally on transport errors),
/// and encrypted rooms transparently share the Megolm session before
/// sending ciphertext. Construct from a client's namespace actors plus
/// the store writer/reader; the caller owns every lifecycle (including
/// the writer's local user). All work runs on this actor, never on the
/// caller — sends never block UI.
public actor MessageSender {
    private let messages: MessageClient
    private let media: MediaClient
    private let rooms: RoomClient
    private let roomState: RoomStateClient
    private let accountData: AccountDataClient
    private let roomCrypto: RoomCrypto
    private let writer: MatrixStoreWriter
    private let reader: MatrixStoreReader
    private var localUser: UserId?
    private var ownDeviceId: DeviceId?

    public init(
        messages: MessageClient,
        media: MediaClient,
        rooms: RoomClient,
        roomState: RoomStateClient,
        accountData: AccountDataClient,
        roomCrypto: RoomCrypto,
        writer: MatrixStoreWriter,
        reader: MatrixStoreReader,
        localUser: UserId? = nil,
        ownDeviceId: DeviceId? = nil
    ) {
        self.messages = messages
        self.media = media
        self.rooms = rooms
        self.roomState = roomState
        self.accountData = accountData
        self.roomCrypto = roomCrypto
        self.writer = writer
        self.reader = reader
        self.localUser = localUser
        self.ownDeviceId = ownDeviceId
    }

    /// Adopt the sending identity (receipt filtering, own-message
    /// exclusion, key sharing).
    public func setLocalUser(_ userId: UserId?, ownDeviceId: DeviceId? = nil) {
        localUser = userId
        self.ownDeviceId = ownDeviceId
    }

    /// Whether a room is encrypted (stored flag; unknown rooms read as
    /// plaintext). One indexed row fetch per send — sends are
    /// user-paced, never per-tick.
    private func isEncrypted(_ roomId: RoomId) -> Bool {
        (try? reader.roomDetail(roomId))?.isEncrypted ?? false
    }

    /// Share the room's Megolm session with joined members (once per
    /// session), skipping only our current device.
    private func ensureShared(_ roomId: RoomId) async throws(MatrixError) {
        let members = try await rooms.joinedMembers(roomId)
        try await roomCrypto.ensureShared(
            roomId: roomId, users: Array(members.keys),
            excludingDevice: ownDeviceId)
    }

    // MARK: - Text

    /// Send markdown text with a local echo. Transport failures mark
    /// the echo failed instead of throwing, and sync confirms the echo
    /// when the server echoes the transaction ID back. Returns the echo
    /// event ID, or nil when logged out.
    @discardableResult
    public func sendText(
        _ roomId: RoomId, _ body: String,
        relatesTo: RelatesTo? = nil, mentions: Mentions? = nil,
        transactionId: TransactionId = .random()
    ) async -> EventId? {
        guard let localUser else { return nil }
        let content = MessageContent.markdown(
            body, relatesTo: relatesTo, mentions: mentions)
        let echo = stagedEcho(
            roomId: roomId, sender: localUser,
            type: EventType.roomMessage.rawValue, content: content,
            transactionId: transactionId)
        try? await writer.stageEcho(echo, roomId: roomId, transactionId: transactionId)
        do {
            if isEncrypted(roomId) {
                try await ensureShared(roomId)
                _ = try await roomCrypto.sendEncryptedContent(
                    roomId, content, deviceId: ownDeviceId,
                    transactionId: transactionId)
            } else {
                _ = try await messages.send(
                    roomId, content: content, transactionId: transactionId)
            }
        } catch {
            try? await writer.failEcho(
                transactionId: transactionId, reason: error.localizedDescription)
        }
        return echo.eventId
    }

    /// Reply to an event (rich reply with fallback). Encrypted rooms
    /// encrypt the reply. Replies carry no local echo.
    @discardableResult
    public func reply(
        _ roomId: RoomId, to eventId: EventId, body: String,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        if isEncrypted(roomId) {
            try await ensureShared(roomId)
            return try await roomCrypto.sendEncryptedContent(
                roomId,
                MessageContent.markdown(
                    body, relatesTo: .reply(to: eventId), mentions: mentions),
                deviceId: ownDeviceId, transactionId: transactionId)
        }
        return try await messages.reply(
            roomId, to: eventId, body: body, mentions: mentions,
            transactionId: transactionId)
    }

    /// Reply inside a thread (`m.thread` rooted at `root`, with an
    /// `m.in_reply_to` fallback to the direct parent). No local echo.
    @discardableResult
    public func threadReply(
        _ roomId: RoomId, root: EventId, parent: EventId? = nil, body: String,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        if isEncrypted(roomId) {
            try await ensureShared(roomId)
            return try await roomCrypto.sendEncryptedContent(
                roomId,
                MessageContent.markdown(
                    body, relatesTo: .thread(root: root, replyTo: parent),
                    mentions: mentions),
                deviceId: ownDeviceId, transactionId: transactionId)
        }
        return try await messages.threadReply(
            roomId, root: root, parent: parent, body: body,
            mentions: mentions, transactionId: transactionId)
    }

    /// Edit a message (`m.replace` relation + `m.new_content`).
    @discardableResult
    public func edit(
        _ roomId: RoomId, eventId: EventId, newBody: String,
        mentions: Mentions? = nil
    ) async throws(MatrixError) -> EventId {
        if isEncrypted(roomId) {
            try await ensureShared(roomId)
            return try await roomCrypto.sendEncryptedContent(
                roomId,
                EditContent.markdown(editing: eventId, newBody, mentions: mentions),
                deviceId: ownDeviceId)
        }
        return try await messages.edit(
            roomId, eventId: eventId, newBody: newBody, mentions: mentions)
    }

    // MARK: - Attachments

    /// Send a file attachment with local echo. Encrypted rooms upload
    /// AES-CTR ciphertext with a `file` dict; plaintext rooms upload
    /// directly (server thumbnails apply). Returns the echo event ID,
    /// or nil when logged out.
    ///
    /// When `onProgress` is set, it receives the overall upload fraction
    /// (0 to 1): one phase for plaintext rooms, file + thumbnail phases
    /// weighted by byte size for encrypted rooms.
    ///
    /// `onEchoStaged` fires once the local echo is persisted, before the
    /// upload begins. Callers with no sync-driven refresh for local-only
    /// store mutations (e.g. a revision counter keyed off sync deltas)
    /// need this to make the pending bubble appear immediately rather
    /// than only once the real event arrives after the upload finishes.
    @discardableResult
    public func sendAttachment(
        _ roomId: RoomId,
        data: Data, filename: String, mimeType: String,
        caption: String? = nil,
        width: Int? = nil, height: Int? = nil, duration: Int? = nil,
        thumbnailData: Data? = nil, thumbnailMimeType: String? = nil,
        inReplyTo: EventId? = nil,
        onEchoStaged: (@Sendable () -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> EventId? {
        guard let localUser else { return nil }
        let transactionId = TransactionId.random()
        let msgtype: MessageType =
            if mimeType.hasPrefix("image/") { .image }
            else if mimeType.hasPrefix("video/") { .video }
            else if mimeType.hasPrefix("audio/") { .audio }
            else { .file }
        let info = MediaInfo(
            mimeType: mimeType, size: data.count,
            width: width, height: height, duration: duration)
        let echo = stagedEcho(
            roomId: roomId, sender: localUser,
            type: EventType.roomMessage.rawValue,
            content: MessageContent(
                msgtype: msgtype, body: caption ?? filename, info: info),
            transactionId: transactionId)
        try? await writer.stageEcho(echo, roomId: roomId, transactionId: transactionId)
        onEchoStaged?()
        do {
            if isEncrypted(roomId) {
                let total = data.count + (thumbnailData?.count ?? 0)
                let fileShare = total > 0 ? Double(data.count) / Double(total) : 1
                let file = try await media.uploadEncrypted(
                    data, mimeType: mimeType, filename: filename
                ) { fraction in
                    onProgress?(fraction * fileShare)
                }
                var encryptedInfo = info
                if let thumbnailData {
                    encryptedInfo.thumbnailFile = try await media.uploadEncrypted(
                        thumbnailData,
                        mimeType: thumbnailMimeType ?? "image/png",
                        filename: "\(filename)-thumbnail"
                    ) { fraction in
                        onProgress?(fileShare + fraction * (1 - fileShare))
                    }
                    encryptedInfo.thumbnailUrl = nil
                }
                try await ensureShared(roomId)
                _ = try await roomCrypto.sendEncryptedContent(
                    roomId,
                    MessageContent(
                        msgtype: msgtype, body: caption ?? filename,
                        relatesTo: inReplyTo.map(RelatesTo.reply(to:)),
                        file: file, info: encryptedInfo),
                    deviceId: ownDeviceId, transactionId: transactionId)
            } else {
                let mxc = try await media.upload(
                    data, mimeType: mimeType, filename: filename,
                    onProgress: onProgress)
                _ = try await messages.send(
                    roomId,
                    content: MessageContent(
                        msgtype: msgtype, body: caption ?? filename,
                        relatesTo: inReplyTo.map(RelatesTo.reply(to:)),
                        url: mxc.value, info: info),
                    transactionId: transactionId)
            }
        } catch {
            try? await writer.failEcho(
                transactionId: transactionId, reason: error.localizedDescription)
        }
        return echo.eventId
    }

    // MARK: - Reactions

    /// React with an emoji key (`m.reaction`).
    @discardableResult
    public func react(
        _ roomId: RoomId, to eventId: EventId, key: String,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await messages.react(
            roomId, to: eventId, key: key, transactionId: transactionId)
    }

    /// Toggle an emoji reaction with optimistic UI: the badge updates
    /// immediately (staged echo on add, redaction on remove) and sync
    /// confirms it in the background. Transport failures roll the
    /// staged change back; nothing throws.
    public func toggleReaction(
        _ roomId: RoomId, target: EventId, key: String
    ) async {
        guard let localUser else { return }
        if let existing = await ownReactionEvent(
            roomId: roomId, target: target, key: key, sender: localUser)
        {
            if let transactionId = await writer.echoTransactionId(for: existing) {
                // Unconfirmed echo: drop it and suppress the in-flight
                // send's confirmation so no zombie badge arrives later.
                try? await writer.cancelEcho(transactionId: transactionId)
                await writer.suppressTransaction(transactionId)
                return
            }
            try? await messages.redact(roomId, eventId: existing)
            return
        }
        let transactionId = TransactionId.random()
        let echo = stagedEcho(
            roomId: roomId, sender: localUser,
            type: EventType.reaction.rawValue,
            content: ReactionContent.reaction(to: target, key: key),
            transactionId: transactionId)
        try? await writer.stageEcho(echo, roomId: roomId, transactionId: transactionId)
        do {
            try await messages.react(
                roomId, to: target, key: key, transactionId: transactionId)
        } catch {
            // Send failed: drop the staged badge rather than leaving a
            // zombie reaction no sync will ever confirm.
            try? await writer.cancelEcho(transactionId: transactionId)
        }
    }

    /// The local user's reaction event for a target+key: staged echoes
    /// still awaiting confirmation first (the rendered window may omit
    /// them), then stored and related events.
    private func ownReactionEvent(
        roomId: RoomId, target: EventId, key: String, sender: UserId
    ) async -> EventId? {
        if let stored = try? await writer.storedEvents(roomId: roomId),
           let found = stored.reactionEvent(
               target: target, key: key, sender: sender)
        {
            return found
        }
        guard
            let relations = try? await messages.relations(
                roomId, eventId: target, relType: "m.annotation",
                eventType: "m.reaction")
        else { return nil }
        return relations.chunk.reactionEvent(
            target: target, key: key, sender: sender)
    }

    // MARK: - Redaction

    /// Redact an event. Local (unsent) echoes are cancelled instead of
    /// redacted on the server.
    @discardableResult
    public func redact(
        _ roomId: RoomId, eventId: EventId, reason: String? = nil,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        if let transactionId = await writer.echoTransactionId(for: eventId),
           (try? await writer.cancelEcho(transactionId: transactionId)) == true
        {
            return eventId
        }
        return try await messages.redact(
            roomId, eventId: eventId, reason: reason,
            transactionId: transactionId)
    }

    // MARK: - Pins

    /// Pin an event (adds to `m.room.pinned_events`, read-modify-write).
    public func pin(
        _ roomId: RoomId, eventId: EventId
    ) async throws(MatrixError) {
        var pinned = (try? reader.roomDetail(roomId))?.pinnedEventIds ?? []
        if !pinned.contains(eventId.value) {
            pinned.append(eventId.value)
        }
        _ = try await roomState.sendStateEvent(
            roomId, type: EventType.roomPinnedEvents.rawValue,
            content: ["pinned": .array(pinned.map(AnyCodable.string))])
    }

    /// Unpin an event.
    public func unpin(
        _ roomId: RoomId, eventId: EventId
    ) async throws(MatrixError) {
        let pinned = ((try? reader.roomDetail(roomId))?.pinnedEventIds ?? [])
            .filter { $0 != eventId.value }
        _ = try await roomState.sendStateEvent(
            roomId, type: EventType.roomPinnedEvents.rawValue,
            content: ["pinned": .array(pinned.map(AnyCodable.string))])
    }

    // MARK: - Read markers

    /// Advance the fully-read marker (synced across devices), adopting
    /// it locally so unread dividers move without waiting for sync.
    public func setFullyRead(
        _ roomId: RoomId, eventId: EventId
    ) async throws(MatrixError) {
        try await accountData.setFullyRead(roomId, eventId: eventId)
        try? await writer.setFullyRead(roomId: roomId, eventId: eventId)
    }

    /// Send (or stop) a typing notification as the local user.
    public func sendTyping(_ roomId: RoomId, typing: Bool) async {
        guard let localUser else { return }
        try? await roomState.sendTyping(roomId, userId: localUser, typing: typing)
    }

    // MARK: - Private

    /// Encode locally-built content for a local echo (empty on
    /// internal error).
    private func echoContent<T: Encodable>(_ content: T) -> [String: AnyCodable] {
        guard
            let data = try? JSONEncoder().encode(content),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: data)
        else { return [:] }
        return dict
    }

    /// Build a staged local-echo event for a send.
    private func stagedEcho<T: Encodable>(
        roomId: RoomId, sender: UserId, type: String, content: T,
        transactionId: TransactionId
    ) -> MessageEvent {
        MessageEvent(
            type: type,
            eventId: EventId(unchecked: "local:\(transactionId.value)"),
            sender: sender,
            roomId: roomId,
            originServerTs: Int(Date.now.timeIntervalSince1970 * 1000),
            content: echoContent(content),
            unsigned: ["transaction_id": .string(transactionId.value)])
    }
}
#endif
