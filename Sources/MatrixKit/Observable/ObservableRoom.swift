/// Observable per-room view model: metadata, members, typing, and actions.
///
/// Mirrors the backing `RoomActor`, refreshing on every `RoomUpdate`.
import Foundation
import Observation
@Observable @MainActor
public final class ObservableRoom {
    /// The room's Matrix ID. Stable for the room's lifetime; use as the
    /// `ForEach` identity (e.g. `ForEach(rooms, id: \.roomId)`).
    public let roomId: RoomId
    /// Explicit room name from `m.room.name` state. Nil until state arrives.
    public private(set) var name: String?
    /// Room topic from `m.room.topic` state, if set.
    public private(set) var topic: String?
    /// Room avatar from `m.room.avatar` state, if set.
    public private(set) var avatarURL: MXCURI?
    /// The local user's membership in this room (`.join`, `.invite`, …).
    public private(set) var membership: Membership
    /// Known member IDs, sorted by MXID. Complete only after full state;
    /// use `loadMembers()` to fetch on demand with lazy-load filters.
    public private(set) var members: [UserId]
    /// Membership details keyed by user ID (display names, avatars).
    public private(set) var memberDetails: [UserId: MemberContent]
    /// Unread notification count from the latest sync's
    /// `unread_notifications`.
    public private(set) var unreadCount: Int
    /// First unread event ID (oldest message-like event newer than the
    /// read marker), for "New" dividers and unread-focus. Nil when unknown
    /// or the room is fully read.
    public private(set) var firstUnreadEventId: EventId?
    /// Highlighted (mention/keyword) notification count.
    public private(set) var highlightCount: Int
    /// IDs of users currently sending `m.typing` in this room.
    public private(set) var typingUsers: [UserId]
    /// The message list. Nil until the backing `Timeline` is built in `init`.
    public private(set) var timeline: ObservableTimeline?
    /// Canonical alias, if set.
    public private(set) var canonicalAlias: String?
    /// Alternative aliases.
    public private(set) var altAliases: [String] = []
    /// Pinned event IDs.
    public private(set) var pinnedEventIds: [String] = []
    /// Successor room after an upgrade, if any.
    public private(set) var successorRoomId: String?
    /// Last-known sync heroes for the display-name fallback.
    public private(set) var heroes: [UserId] = []
    /// Child rooms from `m.space.child` state (spaces only).
    public private(set) var spaceChildren: Set<RoomId> = []
    /// Parent spaces from `m.space.parent` state. Feeds
    /// `parentSpaceIds`; kept in sync by `refresh(from:)`.
    public private(set) var spaceParents: Set<RoomId> = []
    /// Parent spaces flagged canonical (`canonical: true`).
    public private(set) var canonicalParentIds: Set<RoomId> = []
    /// The canonical parent to use, when one is declared (lowest room ID).
    public var canonicalParentId: RoomId? {
        canonicalParentIds.min { codePointLessThan($0.value, $1.value) }
    }
    /// Whether the room is a space.
    public private(set) var isSpace: Bool = false
    /// Whether the room carries the `m.favourite` tag.
    public private(set) var isFavourite: Bool = false
    /// Whether the room is encrypted.
    public private(set) var isEncrypted: Bool = false
    /// Newest message-like event, for list previews.
    public private(set) var latestMessage: MessageEvent?
    /// Inviter display name for invite rooms, if known.
    public private(set) var inviterName: String?
    /// Inviter avatar MXC URI for invite rooms, if known.
    public private(set) var inviterAvatarURL: MXCURI?
    /// Parent space IDs. Populated on demand via
    /// `SpacesClient.parents(of:)` (room state is not synced into the
    /// actor); the app fills this when building space-filtered lists.
    public var parentSpaceIds: Set<RoomId> = []

    /// Key rooms by `roomId` in `ForEach` (e.g. `ForEach(rooms, id: \.roomId)`).

    /// Display name with heroes and room-ID fallbacks (never empty).
    ///
    /// Rooms without an explicit `m.room.name` fall back to the display
    /// names of up to three joined members besides the local user, then to
    /// sync hero IDs, then to the room ID.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        let heroes = memberDetails
            .filter { $0.key != localUser && $0.value.membership == .join }
            .sorted {
                ($0.value.displayname ?? $0.key.value) < ($1.value.displayname ?? $1.key.value)
            }
            .prefix(3)
            .map { $0.value.displayname ?? $0.key.value }
        if !heroes.isEmpty { return heroes.joined(separator: ", ") }
        let syncHeroes = heroesexcludingSelf.prefix(3).map(\.value)
        if !syncHeroes.isEmpty { return syncHeroes.joined(separator: ", ") }
        return roomId.value
    }

    /// Sync heroes excluding the local user.
    private var heroesexcludingSelf: [UserId] {
        heroes.filter { $0 != localUser }
    }

    /// Whether the room is a direct chat, per `m.direct` account data.
    /// This is the sole signal: member-count heuristics false-positive
    /// under lazy member loading, so they are deliberately not used here.
    public private(set) var isDirect: Bool = false

    private let room: RoomActor
    private let messages: MessageClient
    private let rooms: RoomClient
    private let roomState: RoomStateClient
    private let accountData: AccountDataClient
    private let media: MediaClient
    private let localUser: UserId?
    /// The local user's ID, for outgoing detection and self references.
    public var localUserId: UserId? { localUser }
    /// Encrypted-send closure installed by `MatrixClient` (which owns
    /// `roomCrypto`). Stored weakly at the install site: rooms outlive
    /// nothing here, but the client must not be retained by its cache.
    @ObservationIgnored
    var encryptSender:
        ((RoomId, any Encodable & Sendable, TransactionId) async throws -> EventId)?
    /// On-demand member-profile resolver installed by `MatrixClient`
    /// (backed by `GET /profile/{userId}`). Heals senders whose
    /// `m.room.member` sync omitted under lazy member loading. Stored
    /// weakly at the install site: rooms outlive nothing here, but the
    /// client must not be retained by its cache.
    @ObservationIgnored
    var profileFetcher: (@Sendable (UserId) async -> MemberContent?)?
    /// Senders with an in-flight profile heal (dedupe across refreshes).
    @ObservationIgnored
    private var pendingProfileFetches: Set<UserId> = []
    /// Senders whose profile heal returned nothing. Never retried: an
    /// empty profile stays empty until sync state says otherwise.
    @ObservationIgnored
    private var failedProfileFetches: Set<UserId> = []
    /// Decryptor for paginated history, forwarded to the timeline and
    /// any event-focus window. Set by `MatrixClient` after
    /// `configureEncryption()`.
    private var timelineDecryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    // Set once in `init` (MainActor), cancelled in `deinit`; never mutated after.
    // Ignored by observation (a task handle must not refresh views);
    // `nonisolated(unsafe)` lets the nonisolated `deinit` cancel it.
    @ObservationIgnored
    private nonisolated(unsafe) var observerTask: Task<Void, Never>?

    init(
        room: RoomActor,
        messages: MessageClient,
        rooms: RoomClient,
        roomState: RoomStateClient,
        accountData: AccountDataClient,
        media: MediaClient,
        localUser: UserId?
    ) async {
        self.roomId = room.roomId
        self.room = room
        self.messages = messages
        self.rooms = rooms
        self.roomState = roomState
        self.accountData = accountData
        self.media = media
        self.localUser = localUser
        self.membership = await room.membership
        self.members = []
        self.memberDetails = [:]
        self.unreadCount = 0
        self.highlightCount = 0
        self.typingUsers = []
        await refresh(from: room)
        let timelineActor = Timeline(roomId: room.roomId, messages: messages, room: room)
        self.timeline = await ObservableTimeline(
            timeline: timelineActor, room: room, messages: messages, localUser: localUser)
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await room.updates() {
                await self.refresh(from: room)
            }
        }
    }

    deinit {
        observerTask?.cancel()
    }

    // MARK: - Actions

    /// Send a markdown message (`body` plus generated `formatted_body`)
    /// with local echo. Transport failures mark the echo failed instead
    /// of throwing; sync confirms the echo when the server echoes the
    /// transaction ID back. Returns the echo event ID, or nil when
    /// logged out.
    @discardableResult
    public func send(text: String, mentions: Mentions? = nil) async -> EventId? {
        guard let localUser else { return nil }
        let txn = TransactionId.random()
        let content = MessageContent.markdown(text, mentions: mentions)
        let echo = MessageEvent(
            type: EventType.roomMessage.rawValue,
            eventId: EventId(unchecked: "local:\(txn.value)"),
            sender: localUser,
            roomId: roomId,
            originServerTs: Int(Date.now.timeIntervalSince1970 * 1000),
            content: echoContent(content),
            unsigned: ["transaction_id": .string(txn.value)])
        await room.stageEcho(echo, transactionId: txn)
        do {
            if await room.isEncrypted {
                guard let encryptSender else {
                    throw MatrixError.notAuthenticated
                }
                _ = try await encryptSender(roomId, content, txn)
            } else {
                _ = try await messages.send(
                    roomId, content: content, transactionId: txn)
            }
        } catch {
            await room.failEcho(
                transactionId: txn, reason: error.localizedDescription)
        }
        return echo.eventId
    }

    /// Send an HTML message with plain-text fallback. Encrypted
    /// rooms encrypt it like any other content.
    public func sendHTML(body: String, formattedBody: String) async throws {
        if await room.isEncrypted {
            guard let encryptSender else {
                throw MatrixError.notAuthenticated
            }
            _ = try await encryptSender(
                roomId,
                MessageContent.html(body, formattedBody: formattedBody),
                .random())
            return
        }
        try await messages.sendHTML(roomId, body: body, formattedBody: formattedBody)
    }

    /// Send a file attachment with local echo. Encrypted rooms upload
    /// AES-CTR ciphertext with a `file` dict; plaintext rooms upload
    /// directly (server thumbnails apply). Returns the echo event ID,
    /// or nil when logged out.
    @discardableResult
    public func sendAttachment(
        data: Data, filename: String, mimeType: String, caption: String? = nil,
        width: Int? = nil, height: Int? = nil, duration: Int? = nil,
        thumbnailData: Data? = nil, thumbnailMimeType: String? = nil,
        inReplyTo: EventId? = nil
    ) async -> EventId? {
        guard let localUser else { return nil }
        let txn = TransactionId.random()
        let msgtype: MessageType =
            if mimeType.hasPrefix("image/") { .image }
            else if mimeType.hasPrefix("video/") { .video }
            else if mimeType.hasPrefix("audio/") { .audio }
            else { .file }
        let info = MediaInfo(
            mimeType: mimeType, size: data.count,
            width: width, height: height, duration: duration)
        let echo = MessageEvent(
            type: EventType.roomMessage.rawValue,
            eventId: EventId(unchecked: "local:\(txn.value)"),
            sender: localUser,
            roomId: roomId,
            originServerTs: Int(Date.now.timeIntervalSince1970 * 1000),
            content: echoContent(MessageContent(
                msgtype: msgtype, body: caption ?? filename, info: info)),
            unsigned: ["transaction_id": .string(txn.value)])
        await room.stageEcho(echo, transactionId: txn)
        do {
            if await room.isEncrypted {
                let file = try await media.uploadEncrypted(
                    data, mimeType: mimeType, filename: filename)
                var encryptedInfo = info
                if let thumbnailData {
                    encryptedInfo.thumbnailFile = try await media.uploadEncrypted(
                        thumbnailData,
                        mimeType: thumbnailMimeType ?? "image/png",
                        filename: "\(filename)-thumbnail")
                    encryptedInfo.thumbnailUrl = nil
                }
                guard let encryptSender else {
                    throw MatrixError.notAuthenticated
                }
                _ = try await encryptSender(
                    roomId,
                    MessageContent(
                        msgtype: msgtype, body: caption ?? filename,
                        relatesTo: inReplyTo.map(RelatesTo.reply(to:)),
                        file: file, info: encryptedInfo),
                    txn)
            } else {
                let mxc = try await media.upload(
                    data, mimeType: mimeType, filename: filename)
                _ = try await messages.send(
                    roomId,
                    content: MessageContent(
                        msgtype: msgtype, body: caption ?? filename,
                        relatesTo: inReplyTo.map(RelatesTo.reply(to:)),
                        url: mxc.value, info: info),
                    transactionId: txn)
            }
        } catch {
            await room.failEcho(
                transactionId: txn, reason: error.localizedDescription)
        }
        return echo.eventId
    }

    /// Encode locally-built content for a local echo (always encodes;
    /// empty on internal error).
    private func echoContent<T: Encodable>(_ content: T) -> [String: AnyCodable] {
        guard
            let data = try? JSONEncoder().encode(content),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: data)
        else { return [:] }
        return dict
    }

    /// Reply to an event. Encrypted rooms encrypt the reply (replies
    /// carry no local echo, matching previous behavior).
    public func reply(
        to eventId: EventId, text: String, mentions: Mentions? = nil
    ) async throws {
        if await room.isEncrypted {
            guard let encryptSender else {
                throw MatrixError.notAuthenticated
            }
            _ = try await encryptSender(
                roomId,
                MessageContent.markdown(
                    text, relatesTo: .reply(to: eventId),
                    mentions: mentions),
                .random())
            return
        }
        try await messages.reply(roomId, to: eventId, body: text, mentions: mentions)
    }

    /// Reply inside a thread rooted at `rootEventId`.
    public func threadReply(
        rootEventId: EventId, parentEventId: EventId? = nil, text: String,
        mentions: Mentions? = nil
    ) async throws {
        if await room.isEncrypted {
            guard let encryptSender else {
                throw MatrixError.notAuthenticated
            }
            _ = try await encryptSender(
                roomId,
                MessageContent.markdown(
                    text,
                    relatesTo: .thread(
                        root: rootEventId, replyTo: parentEventId),
                    mentions: mentions),
                .random())
            return
        }
        try await messages.threadReply(
            roomId, root: rootEventId, parent: parentEventId, body: text,
            mentions: mentions)
    }

    /// Edit own message.
    public func edit(
        _ eventId: EventId, newText: String, mentions: Mentions? = nil
    ) async throws {
        if await room.isEncrypted {
            guard let encryptSender else {
                throw MatrixError.notAuthenticated
            }
            _ = try await encryptSender(
                roomId,
                EditContent.markdown(
                    editing: eventId, newText, mentions: mentions),
                .random())
            return
        }
        try await messages.edit(roomId, eventId: eventId, newBody: newText, mentions: mentions)
    }

    /// Redact an event.
    /// Redact an event. Local (unsent) echoes are cancelled instead of
    /// redacted on the server.
    public func redact(_ eventId: EventId, reason: String? = nil) async throws {
        if let txn = await room.echoTransactionId(for: eventId),
            await room.cancelEcho(transactionId: txn)
        {
            return
        }
        try await messages.redact(roomId, eventId: eventId, reason: reason)
    }

    /// Toggle a reaction (adds; server dedupes by sender+key).
    public func react(to eventId: EventId, key: String) async throws {
        try await messages.react(roomId, to: eventId, key: key)
    }

    /// Toggle an emoji reaction with optimistic UI: the badge updates
    /// immediately (staged echo on add, redaction stamp on remove) and
    /// sync confirms it in the background. Transport failures roll the
    /// staged change back; nothing throws.
    public func toggleReaction(target: EventId, key: String) async {
        guard let localUser else { return }
        if let existing = await timeline?.reactionEvent(
            target: target, key: key, sender: localUser)
        {
            await toggleReactionOff(existing, by: localUser)
            return
        }
        let txn = TransactionId.random()
        let echo = MessageEvent(
            type: EventType.reaction.rawValue,
            eventId: EventId(unchecked: "local:\(txn.value)"),
            sender: localUser,
            roomId: roomId,
            originServerTs: Int(Date.now.timeIntervalSince1970 * 1000),
            content: echoContent(ReactionContent.reaction(to: target, key: key)),
            unsigned: ["transaction_id": .string(txn.value)])
        await room.stageEcho(echo, transactionId: txn)
        do {
            try await messages.react(
                roomId, to: target, key: key, transactionId: txn)
        } catch {
            // Send failed: drop the staged badge rather than leaving a
            // zombie reaction no sync will ever confirm.
            await room.cancelEcho(transactionId: txn)
        }
    }

    /// Optimistic toggle-off for a known reaction event.
    private func toggleReactionOff(_ existing: EventId, by localUser: UserId) async {
        if let txn = await room.echoTransactionId(for: existing) {
            // Unconfirmed echo: drop it and suppress the in-flight send's
            // confirmation so no zombie badge arrives later.
            await room.cancelEcho(transactionId: txn)
            await room.suppressTransaction(txn)
            return
        }
        let prior = await room.stampRedaction(
            target: existing,
            stamp: .object([
                "type": .string(EventType.redaction.rawValue),
                "sender": .string(localUser.value),
                "redacts": .string(existing.value),
            ]))
        do {
            try await messages.redact(roomId, eventId: existing)
        } catch {
            await room.restoreUnsigned(target: existing, unsigned: prior)
        }
    }

    /// Invite a user.
    public func invite(_ userId: UserId) async throws {
        try await rooms.invite(roomId, user: userId)
    }

    /// Leave the room.
    public func leave() async throws {
        try await rooms.leave(roomId)
    }

    /// Load the full member list from the server into the store.
    public func loadMembers() async throws {
        let list = try await rooms.members(roomId)
        for member in list {
            // Route through sync-style state application via a synthetic path:
            // simplest is direct memberDetails refresh after store update.
            memberDetails[member.userId] = member.content
        }
        members = memberDetails.keys.sorted { $0.value < $1.value }
    }

    /// Mark an event as read.
    ///
    /// - Parameter receiptType: `"m.read"` for a public receipt, or
    ///   `"m.read.private"` to clear the server's unread count without
    ///   showing other members what was read.
    public func markRead(_ eventId: EventId, receiptType: String = "m.read") async throws {
        try await roomState.sendReceipt(roomId, eventId: eventId, receiptType: receiptType)
        await room.setFullyRead(eventId)
    }

    /// The fully-read marker event ID, if known.
    public func fullyReadEventId() async -> EventId? {
        await room.fullyReadEventId
    }

    /// Advance the fully-read marker via the read-markers endpoint.
    /// Adopts locally even when the POST fails, so the badge and divider
    /// clear immediately; max-only adoption keeps the count cleared when
    /// the server state echoes back.
    public func sendFullyRead(_ eventId: EventId) async throws {
        do {
            try await accountData.setFullyRead(roomId, eventId: eventId)
        } catch {
            await room.setFullyRead(eventId)
            throw error
        }
        await room.setFullyRead(eventId)
    }

    /// Arm (or re-arm) the decryptor for paginated history on the live
    /// timeline; `ObservableTimeline` keeps it for event-focus windows.
    func setTimelineDecryptor(
        _ decryptor: (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    ) async {
        timelineDecryptor = decryptor
        await timeline?.setTimelineDecryptor(decryptor)
    }

    /// Re-decrypt stored ciphertext with newly-arrived sessions (see
    /// `RoomActor.retryDecryption`). Returns the number decrypted.
    @discardableResult
    func retryDecryption() async -> Int {
        guard let timelineDecryptor else { return 0 }
        return await room.retryDecryption(timelineDecryptor)
    }

    /// Send a typing notification as the local user.
    public func setTyping(_ typing: Bool) async throws {
        guard let localUser else { return }
        try await roomState.sendTyping(roomId, userId: localUser, typing: typing)
    }

    /// Change the room name / topic.
    public func setName(_ name: String) async throws {
        try await roomState.setName(roomId, name: name)
    }

    /// Change the room topic.
    public func setTopic(_ topic: String) async throws {
        try await roomState.setTopic(roomId, topic: topic)
    }

    /// One-shot heal for a room whose locally synced avatar is missing:
    /// fetches the authoritative `m.room.avatar` state event and adopts
    /// it, so rooms whose avatar update was missed by sync recover
    /// without waiting for the next avatar change. Returns true when an
    /// avatar was adopted. No-ops when one is already known locally or
    /// the server has none.
    @discardableResult
    public func hydrateMissingAvatar() async -> Bool {
        guard avatarURL == nil else { return false }
        guard
            let content = try? await roomState.getStateEvent(
                roomId, type: EventType.roomAvatar.rawValue),
            let url = content["url"]?.stringValue,
            let uri = try? MXCURI(url)
        else { return false }
        await room.adoptAvatarURL(uri)
        await refresh(from: room)
        return true
    }

    // MARK: - Private

    private func refresh(from room: RoomActor) async {
        name = await room.name
        topic = await room.topic
        avatarURL = await room.avatarURL
        membership = await room.membership
        let details = await room.members
        memberDetails = details
        members = details.keys.sorted { $0.value < $1.value }
        await healUnknownSenders()
        // Badge-driving count: client estimate wins when it exceeds the
        // unreliable server value (the actor's raw server field is kept
        // intact for tests and diagnostics).
        unreadCount = await room.effectiveUnreadCount
        firstUnreadEventId = await room.firstUnreadEventId
        highlightCount = await room.highlightCount
        typingUsers = await room.typingUsers
        canonicalAlias = await room.canonicalAlias
        altAliases = await room.altAliases
        pinnedEventIds = await room.pinnedEventIds
        successorRoomId = await room.successorRoomId
        heroes = await room.heroes
        spaceChildren = await room.spaceChildren
        spaceParents = await room.spaceParents
        canonicalParentIds = await room.canonicalParentIds
        parentSpaceIds = await room.spaceParents
        isSpace = await room.isSpace
        isFavourite = await room.isFavourite
        isEncrypted = await room.isEncrypted
        isDirect = await room.isDirect
        latestMessage = await room.latestMessageEvent()
        if membership == .invite {
            let inviter = details.first { $0.value.membership == .invite }?.key
            inviterName = inviter.flatMap { details[$0]?.displayname }
            inviterAvatarURL = inviter.flatMap { details[$0]?.avatarUrl }.flatMap { try? MXCURI($0) }
        } else {
            inviterName = nil
            inviterAvatarURL = nil
        }
    }

    /// Fetch profiles for senders of timeline events unknown to room
    /// state (lazy member loading omits their `m.room.member` events).
    /// Detection reads the actor's raw timeline rather than the rendered
    /// wrapper so it never races the timeline's own rebuild. Healed
    /// entries route through `RoomActor.adoptMember`, whose
    /// `membersChanged` update re-renders the timeline with resolved
    /// names and avatars. No-op when no fetcher is installed.
    private func healUnknownSenders() async {
        guard let profileFetcher else { return }
        let senders = Set((await room.timeline).map(\.sender))
        for sender in senders where memberDetails[sender] == nil {
            guard
                !pendingProfileFetches.contains(sender),
                !failedProfileFetches.contains(sender)
            else { continue }
            pendingProfileFetches.insert(sender)
            Task { [weak self] in
                guard let self else { return }
                defer { pendingProfileFetches.remove(sender) }
                guard let content = await profileFetcher(sender) else {
                    failedProfileFetches.insert(sender)
                    return
                }
                await room.adoptMember(sender, content: content)
            }
        }
    }

    /// Fetch the room's pinned messages (most recent first as stored).
    public func pinnedMessages() async throws -> [MessageEvent] {
        var events: [MessageEvent] = []
        for id in pinnedEventIds {
            guard let eventId = try? EventId(id) else { continue }
            events.append(try await messages.event(roomId, eventId))
        }
        return events
    }

    /// Set or clear the `m.favourite` tag (read-modify-write, preserving
    /// other tags). Sync converges the same flag.
    public func setFavourite(_ isFavourite: Bool) async throws {
        try await accountData.setFavourite(roomId, isFavourite: isFavourite)
        await room.setFavourite(isFavourite)
    }

    /// Pin an event (adds to `m.room.pinned_events`, read-modify-write).
    public func pin(_ eventId: EventId) async throws {
        var pinned = pinnedEventIds
        if !pinned.contains(eventId.value) {
            pinned.append(eventId.value)
        }
        try await roomState.sendStateEvent(
            roomId, type: EventType.roomPinnedEvents.rawValue,
            content: ["pinned": .array(pinned.map(AnyCodable.string))])
    }

    /// Unpin an event.
    public func unpin(_ eventId: EventId) async throws {
        let pinned = pinnedEventIds.filter { $0 != eventId.value }
        try await roomState.sendStateEvent(
            roomId, type: EventType.roomPinnedEvents.rawValue,
            content: ["pinned": .array(pinned.map(AnyCodable.string))])
    }

    /// Full room snapshot for inspector and settings UI.
    public func roomDetails() async throws -> RoomDetails {
        let state = try await roomState.getState(roomId)
        var name: String?
        var topic: String?
        var avatarURL: MXCURI?
        var canonicalAlias: String?
        var alternativeAliases: [String] = []
        var pinnedEventIds: [String] = []
        var joinRule: String?
        var historyVisibility: String?
        var powerContent: [String: AnyCodable]?
        var creator: UserId?
        for event in state {
            switch EventType(rawValue: event.type) {
            case .roomName:
                name = event.content["name"]?.stringValue
            case .roomTopic:
                topic = event.content["topic"]?.stringValue
            case .roomAvatar:
                avatarURL = event.content["url"]?.stringValue.flatMap { try? MXCURI($0) }
            case .roomCanonicalAlias:
                canonicalAlias = event.content["alias"]?.stringValue
                alternativeAliases =
                    event.content["alt_aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
            case .roomPinnedEvents:
                pinnedEventIds =
                    event.content["pinned"]?.arrayValue?.compactMap(\.stringValue) ?? []
            case .roomPowerLevels:
                powerContent = event.content
            case .roomJoinRules:
                joinRule = event.content["join_rule"]?.stringValue
            case .roomHistoryVisibility:
                historyVisibility = event.content["history_visibility"]?.stringValue
            case .roomCreate:
                creator = event.sender
            case .roomMember, .roomMessage, .roomEncryption, .roomTombstone,
                .roomServerACL, .sticker, .pollStart, .callMember, .redaction, .reaction,
                .typing, .receipt, .presence, .fullyRead, .tag, .custom, .unknown:
                break
            }
        }
        let memberInfos = try await rooms.members(roomId)
        // Only active members belong in the member list: joined users plus
        // pending invites. Banned, departed, and knocking users are excluded.
        let members = memberInfos
            .filter { $0.content.membership == .join || $0.content.membership == .invite }
            .map { info in
            let userId = UserId(unchecked: info.stateKey)
            let level = powerContent.map {
                RoomPermissions.powerLevel(of: userId, in: $0)
            } ?? 0
            return RoomMemberDetails(
                userId: userId,
                displayName: info.content.displayname,
                avatarURL: info.content.avatarUrl.flatMap { try? MXCURI($0) },
                role: .of(level),
                powerLevel: level,
                isCreator: userId == creator)
        }
        let permissions = localUser.flatMap { user in
            powerContent.map { RoomPermissions.evaluate(powerLevels: $0, userId: user) }
        }
        return RoomDetails(
            id: roomId,
            name: name ?? self.name,
            topic: topic ?? self.topic,
            avatarURL: avatarURL ?? self.avatarURL,
            isEncrypted: isEncrypted,
            isPublic: joinRule == "public",
            isDirect: isDirect,
            canonicalAlias: canonicalAlias ?? self.canonicalAlias,
            alternativeAliases: alternativeAliases,
            memberCount: members.count,
            members: members,
            pinnedEventIds: pinnedEventIds.isEmpty ? self.pinnedEventIds : pinnedEventIds,
            joinRule: joinRule,
            historyVisibility: historyVisibility,
            permissions: permissions,
            powerLevelSettings: powerContent.map(RoomPowerLevelSettings.parse))
    }
}
