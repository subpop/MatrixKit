import Foundation
import Logging
import MatrixKitCrypto

/// Megolm room encryption: outbound sessions, key sharing, inbound decrypt.
///
/// `RoomCrypto` owns the room half of E2EE. The Olm half (device lists,
/// to-device transport) stays in `OlmConnector`; `RoomCrypto` talks to it
/// through `RoomKeySharer` and sends room events through `RoomEventSender`
/// so both seams stay fakeable in tests.
///
/// Wire-up: `MatrixClient.configureEncryption()` constructs this actor
/// from its `olm` + `messages` clients and installs the sync hooks that
/// route `m.room_key` to-device events here and decrypt timelines.
public actor RoomCrypto {
    /// Algorithm string for Megolm room events.
    public static let megolmAlgorithm = "m.megolm.v1.aes-sha2"
    /// Room timeline event type carrying Megolm ciphertext.
    public static let roomEncryptedType = "m.room.encrypted"
    /// To-device event type carrying a shared Megolm session.
    public static let roomKeyType = "m.room_key"
    /// To-device event type requesting a Megolm session (`m.room_key_request`).
    /// Peers send these when they hold ciphertext for an unknown session;
    /// see `keyRequestContent`, `onUnknownSession`, and `shareCurrentSession`.
    public static let keyRequestType = "m.room_key_request"

    /// An undecryptable session sighting: room, session, and sender to
    /// request the key from.
    public struct UnknownSession: Sendable {
        public var roomId: RoomId
        public var sessionId: String
        public var sender: UserId
    }

    private static let storeService = "MatrixKit.RoomCrypto"

    private let sharer: any RoomKeySharer
    private let sender: any RoomEventSender
    private let keystore: (any KeyStore)?
    private let logger: Logger?

    /// Outbound sessions by room ID value. Fresh per launch; inbound
    /// sessions persist via the keystore (see `restore()`).
    private var outbound: [String: MegolmSession] = [:]
    /// Inbound sessions by `"roomId|sessionId"`.
    private var inbound: [String: MegolmSession] = [:]
    /// Room IDs whose current outbound session has been shared.
    /// Cleared by `rotateOutbound(_:)`; empty after launch (fresh
    /// outbound), so the first `ensureShared` re-shares post-restart.
    private var shared: Set<String> = []
    /// `"roomId|sessionId"` keys already surfaced via `onUnknownSession`.
    /// Cleared for a session when its key arrives, so a later re-loss
    /// re-requests. Capped to bound memory on pathological timelines.
    private var requestedSessions: Set<String> = []
    /// `request_id`s already served, so duplicate key requests share once.
    private var servedRequestIds: Set<String> = []
    /// Local user: own sends never trigger key requests (self-decrypt is
    /// registered at send time). Nil until `setLocalUserId` runs.
    private var localUserId: UserId?
    /// Fired once per unknown inbound session (see `decryptRoomEvent`).
    /// The owner builds an `m.room_key_request` via `keyRequestContent`
    /// and sends it to `UnknownSession.sender`.
    private var onUnknownSession: (@Sendable (UnknownSession) -> Void)?

    public init(
        sharer: any RoomKeySharer, sender: any RoomEventSender,
        keystore: (any KeyStore)? = nil, logger: Logger? = nil
    ) {
        self.sharer = sharer
        self.sender = sender
        self.keystore = keystore
        self.logger = logger
    }

    // MARK: - Key requests

    /// Set the local user (own sends never trigger key requests).
    public func setLocalUserId(_ userId: UserId?) {
        localUserId = userId
    }

    /// Install the unknown-session handler (see `onUnknownSession`).
    public func setUnknownSessionHandler(
        _ handler: (@Sendable (UnknownSession) -> Void)?
    ) {
        onUnknownSession = handler
    }

    /// `m.room_key_request` content for `sessionId` in `roomId`,
    /// from `deviceId` under `requestId`.
    public static func keyRequestContent(
        requestId: String, deviceId: DeviceId,
        roomId: RoomId, sessionId: String
    ) -> [String: AnyCodable] {
        [
            "algorithm": .string(Self.megolmAlgorithm),
            "requesting_device_id": .string(deviceId.value),
            "request_id": .string(requestId),
            "room_id": .string(roomId.value),
            "session_id": .string(sessionId),
        ]
    }

    /// Record an unknown session, returning true when newly seen (the
    /// caller should send one key request). Re-armed by `receiveRoomKey`.
    func claimUnknownSession(roomId: RoomId, sessionId: String) -> Bool {
        let key = "\(roomId.value)|\(sessionId)"
        guard !requestedSessions.contains(key) else { return false }
        requestedSessions.insert(key)
        if requestedSessions.count > 1000 { requestedSessions.removeAll() }
        return true
    }

    /// Record a served key `request_id`, returning true when newly seen
    /// (the caller should share). Duplicates share nothing.
    func claimServedRequest(_ requestId: String) -> Bool {
        guard !servedRequestIds.contains(requestId) else { return false }
        servedRequestIds.insert(requestId)
        if servedRequestIds.count > 1000 { servedRequestIds.removeAll() }
        return true
    }

    // MARK: - Persistence

    /// Reload persisted inbound sessions. Outbound sessions are never
    /// persisted (their export blob drops the signing key), so the first
    /// send after launch creates a fresh session and `ensureShared`
    /// re-shares it.
    public func restore() async {
        guard let keystore else { return }
        guard
            let data = try? await keystore.load(KeyStoreKey(
                service: Self.storeService, account: "megolm")),
            let stored = try? JSONDecoder().decode(
                [String: String].self, from: data)
        else { return }
        for (key, b64) in stored {
            guard
                let blob = Primitives.base64UnpaddedDecode(b64),
                let session = try? MegolmSession.importSessionKey(blob)
            else { continue }
            inbound[key] = session
        }
    }

    private func persist() async {
        guard let keystore else { return }
        var stored: [String: String] = [:]
        for (key, session) in inbound {
            stored[key] = Primitives.base64UnpaddedEncode(session.export())
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try await keystore.save(
                data,
                for: KeyStoreKey(
                    service: Self.storeService, account: "megolm"))
        } catch {
            logger?.warning("RoomCrypto persist failed: \(error)")
        }
    }

    /// Delete persisted megolm sessions (e.g. on logout). Note the
    /// entry is shared across accounts — see `restore()`. Absent
    /// entries are not an error; failures are logged, not thrown.
    public func deletePersistedSessions() async {
        guard let keystore else { return }
        do {
            try await keystore.delete(KeyStoreKey(
                service: Self.storeService, account: "megolm"))
        } catch {
            logger?.warning("RoomCrypto delete failed: \(error)")
        }
    }

    // MARK: - Send

    /// Encrypt `content` as `m.room.message` under the room's outbound
    /// session (created on first use) and send it as
    /// `m.room.encrypted`. Call `ensureShared(roomId:users:)` first so
    /// recipients hold the session. The outbound session is also
    /// registered for self-decryption: the sender never receives its own
    /// `m.room_key`, so without this the sync echo of sent events would
    /// stay undecryptable. Pass the staged local-echo transaction ID so
    /// sync confirms the echo instead of duplicating it.
    @discardableResult
    public func sendEncryptedContent(
        _ roomId: RoomId, _ content: any Encodable & Sendable,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        var session = outbound[roomId.value] ?? MegolmSession.create()
        let inboundKey = "\(roomId.value)|\(session.id)"
        if inbound[inboundKey] == nil {
            // Capture the pre-encrypt session state for self-decryption:
            // the sender never receives its own `m.room_key`, so without
            // this the sync echo of sent events stays undecryptable.
            // Registered once per session (counter 0) so earlier messages
            // stay decryptable as the ratchet advances.
            if let keyBlob = try? session.sessionKey(),
                let inboundSession = try? MegolmSession.importSessionKey(keyBlob)
            {
                inbound[inboundKey] = inboundSession
            } else {
                logger?.debug(
                    "RoomCrypto could not register outbound session for self-decrypt",
                    metadata: ["roomId": "\(roomId.value)"])
            }
        }
        let plaintext: Data
        do {
            // Encode the caller's content as-is so the encrypted payload
            // matches plaintext wire shape (msgtype/body plus formatted
            // body, m.relates_to, m.mentions as carried by the content).
            let encoded = try JSONEncoder().encode(content)
            guard
                let content = try JSONSerialization.jsonObject(with: encoded)
                    as? [String: Any]
            else {
                throw MatrixError.encodingError(
                    "Cannot encode encrypted payload")
            }
            plaintext = try JSONSerialization.data(
                withJSONObject: [
                    "room_id": roomId.value,
                    "type": EventType.roomMessage.rawValue,
                    "content": content,
                ])
        } catch let error as MatrixError {
            throw error
        } catch {
            throw .encodingError(
                "Cannot encode encrypted payload: \(error.localizedDescription)")
        }
        let wire: Data
        do {
            wire = try session.encrypt(plaintext)
        } catch {
            throw .encodingError(
                "Megolm encrypt failed: \(error.localizedDescription)")
        }
        outbound[roomId.value] = session
        var content: [String: AnyCodable] = [
            "algorithm": .string(Self.megolmAlgorithm),
            "session_id": .string(session.id),
            "ciphertext": .string(Primitives.base64UnpaddedEncode(wire)),
        ]
        if let senderKey = try? await sharer.identityKey() {
            content["sender_key"] = .string(senderKey)
        }
        let eventId = try await sender.sendEvent(
            roomId, eventType: Self.roomEncryptedType, content: content,
            transactionId: transactionId)
        await persist()
        return eventId
    }

    /// Share the room's current outbound session (created if needed) with
    /// each user's devices via `m.room_key` to-device messages. Include
    /// the local user: their other devices need the session to read what
    /// this device sends. `excludingDevice` skips one device (normally
    /// our own — to-device to self is pointless).
    public func shareRoomKey(
        roomId: RoomId, users: [UserId], excludingDevice: DeviceId? = nil
    ) async throws(MatrixError) {
        for user in users {
            let ids: [String]
            do {
                ids = try await sharer.deviceIds(for: user)
            } catch {
                logger?.warning(
                    "RoomCrypto skipping key share: device query failed",
                    metadata: [
                        "user": "\(user.value)",
                        "error": "\(error)",
                    ])
                continue
            }
            let devices = ids
                .filter { $0 != excludingDevice?.value }
                .map { DeviceId($0) }
            guard !devices.isEmpty else {
                logger?.warning(
                    "RoomCrypto skipping key share: no devices",
                    metadata: ["user": "\(user.value)"])
                continue
            }
            try await shareCurrentSession(
                roomId: roomId, to: user, devices: devices)
        }
        shared.insert(roomId.value)
    }

    /// Share the room's current outbound session (created if needed) with
    /// one user's explicit devices. Backs `shareRoomKey` and key-request
    /// serving (the request carries its own `requesting_device_id`).
    public func shareCurrentSession(
        roomId: RoomId, to user: UserId, devices: [DeviceId]
    ) async throws(MatrixError) {
        let session = outbound[roomId.value] ?? MegolmSession.create()
        outbound[roomId.value] = session
        let keyBlob: Data
        do {
            keyBlob = try session.sessionKey()
        } catch {
            throw .encodingError(
                "Megolm sessionKey failed: \(error.localizedDescription)")
        }
        let content: [String: AnyCodable] = [
            "algorithm": .string(Self.megolmAlgorithm),
            "room_id": .string(roomId.value),
            "session_id": .string(session.id),
            "session_key": .string(
                Primitives.base64UnpaddedEncode(keyBlob)),
        ]
        try await sharer.sendEncrypted(
            eventType: Self.roomKeyType, content: content,
            to: user, devices: devices)
    }

    /// Share only when the current outbound session hasn't been shared
    /// yet (first send per room/session). Backs the
    /// `MatrixClient.sendEncryptedContent` convenience.
    public func ensureShared(
        roomId: RoomId, users: [UserId], excludingDevice: DeviceId? = nil
    ) async throws(MatrixError) {
        guard !shared.contains(roomId.value) else { return }
        try await shareRoomKey(
            roomId: roomId, users: users, excludingDevice: excludingDevice)
    }

    /// Drop the outbound session so the next send starts a fresh one
    /// (forward secrecy on membership change). The fresh session is
    /// unshared: the next `ensureShared` re-shares it.
    public func rotateOutbound(roomId: RoomId) {
        outbound[roomId.value] = nil
        shared.remove(roomId.value)
    }

    // MARK: - Backup

    /// Inbound sessions as backup payloads: room, session ID, and the
    /// session export blob. Keys are `"roomId|sessionId"` (neither ID
    /// may contain a pipe per the Matrix ID grammar).
    public func backupExports() -> [(roomId: RoomId, sessionId: String, export: Data)] {
        var out: [(RoomId, String, Data)] = []
        for (key, session) in inbound {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out.append((RoomId(unchecked: parts[0]), parts[1], session.export()))
        }
        return out
    }

    /// Import a session export (e.g. decrypted from a key backup) into
    /// the inbound map, persisting it like a received room key.
    public func importSession(
        roomId: RoomId, sessionId: String, export: Data
    ) async throws(MatrixError) {
        guard let session = try? MegolmSession.importSessionKey(export) else {
            throw .encodingError("Cannot import session export for \(roomId.value)")
        }
        inbound["\(roomId.value)|\(sessionId)"] = session
        await persist()
    }

    // MARK: - Receive

    /// Import an `m.room_key` to-device event's session. Unknown event
    /// types and malformed blobs are ignored (logged at debug).
    /// Returns the room ID when a session was stored, so the caller can
    /// re-run timeline decryption for that room.
    @discardableResult
    public func receiveRoomKey(_ event: BasicEvent) async -> RoomId? {
        guard event.type == Self.roomKeyType else { return nil }
        guard
            let algorithm = event.content["algorithm"]?.stringValue,
            algorithm == Self.megolmAlgorithm,
            let roomId = event.content["room_id"]?.stringValue,
            let sessionId = event.content["session_id"]?.stringValue,
            let keyB64 = event.content["session_key"]?.stringValue,
            let blob = Primitives.base64UnpaddedDecode(keyB64),
            let session = try? MegolmSession.importSessionKey(blob)
        else {
            logger?.debug(
                "RoomCrypto ignoring malformed m.room_key",
                metadata: ["sender": "\(event.sender?.value ?? "?")"])
            return nil
        }
        inbound["\(roomId)|\(sessionId)"] = session
        requestedSessions.remove("\(roomId)|\(sessionId)")
        await persist()
        return RoomId(unchecked: roomId)
    }

    /// Decrypt an `m.room.encrypted` timeline event, returning the inner
    /// event (same envelope, decrypted type + content). Clear events pass
    /// through unchanged; undecryptable events (no session, bad crypto,
    /// non-JSON plaintext) return nil — callers keep the ciphertext.
    /// Unknown sessions from other users fire `onUnknownSession` once per
    /// session so the owner can send `m.room_key_request`.
    public func decryptRoomEvent(
        _ event: MessageEvent, in roomId: RoomId
    ) async -> MessageEvent? {
        guard event.type == Self.roomEncryptedType else { return event }
        guard
            let sessionId = event.content["session_id"]?.stringValue,
            let cipherB64 = event.content["ciphertext"]?.stringValue,
            let wire = Primitives.base64UnpaddedDecode(cipherB64)
        else {
            logger?.debug(
                "RoomCrypto cannot decrypt: malformed envelope",
                metadata: ["sender": "\(event.sender.value)"])
            return nil
        }
        guard var session = inbound["\(roomId.value)|\(sessionId)"] else {
            logger?.debug(
                "RoomCrypto cannot decrypt: unknown inbound session",
                metadata: [
                    "sender": "\(event.sender.value)",
                    "sessionId": "\(sessionId.prefix(8))…",
                ])
            if event.sender != localUserId,
                claimUnknownSession(roomId: roomId, sessionId: sessionId)
            {
                onUnknownSession?(UnknownSession(
                    roomId: roomId, sessionId: sessionId,
                    sender: event.sender))
            }
            return nil
        }
        guard
            let plaintext = try? session.decrypt(wire),
            let json = try? JSONSerialization.jsonObject(with: plaintext),
            let dict = json as? [String: Any],
            let type = dict["type"] as? String,
            let contentJSON = dict["content"],
            let contentData = try? JSONSerialization.data(
                withJSONObject: contentJSON),
            let content = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: contentData)
        else {
            logger?.debug(
                "RoomCrypto cannot decrypt: Megolm payload failed",
                metadata: [
                    "sender": "\(event.sender.value)",
                    "sessionId": "\(sessionId.prefix(8))…",
                ])
            return nil
        }
        inbound["\(roomId.value)|\(sessionId)"] = session
        await persist()
        return MessageEvent(
            type: type, eventId: event.eventId, sender: event.sender,
            roomId: event.roomId ?? roomId, stateKey: event.stateKey,
            originServerTs: event.originServerTs, content: content,
            unsigned: event.unsigned)
    }
}

/// Narrow seam `RoomCrypto` needs from the Olm layer: device enumeration
/// plus the encrypted to-device transport. `OlmConnector` conforms.
public protocol RoomKeySharer: Actor {
    /// Device IDs with published keys for a user (cached; see
    /// `OlmConnector.deviceIds(for:)`).
    func deviceIds(for user: UserId) async throws(MatrixError) -> [String]
    /// Encrypt `content` for each device and send as `m.room.encrypted`.
    func sendEncrypted(
        eventType: String, content: [String: AnyCodable],
        to user: UserId, devices: [DeviceId]
    ) async throws(MatrixError)
    /// Unpadded-base64 Ed25519 fingerprint of the local device, sent as
    /// `sender_key` on room events.
    func identityKey() async throws(MatrixError) -> String
}

extension OlmConnector: RoomKeySharer {}

/// Narrow seam `RoomCrypto` needs to send room events.
/// `MessageClient` conforms.
public protocol RoomEventSender: Actor {
    @discardableResult
    func sendEvent(
        _ roomId: RoomId,
        eventType: String,
        content: any Encodable & Sendable,
        transactionId: TransactionId
    ) async throws(MatrixError) -> EventId
}

extension MessageClient: RoomEventSender {}
