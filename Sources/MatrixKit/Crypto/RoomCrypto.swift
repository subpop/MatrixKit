import Foundation
import MatrixKitCrypto
import os

/// Megolm room encryption: outbound sessions, key sharing, inbound decrypt.
///
/// `RoomCrypto` owns the room half of E2EE. The Olm half (device lists,
/// to-device transport) stays in `OlmConnector`; `RoomCrypto` talks to it
/// through `RoomKeySharer` and sends room events through `RoomEventSender`
/// so both seams stay fakeable in tests.
///
/// Wire-up: `MatrixClient.configureEncryption()` constructs this actor
/// from its `olm` + `messages` clients and installs the sync hooks that
/// route `m.room_key`/`m.forwarded_room_key` to-device events here and
/// decrypt timelines.
public actor RoomCrypto {
    /// Algorithm string for Megolm room events.
    public static let megolmAlgorithm = "m.megolm.v1.aes-sha2"
    /// Room timeline event type carrying Megolm ciphertext.
    public static let roomEncryptedType = "m.room.encrypted"
    /// To-device event type carrying a shared Megolm session.
    public static let roomKeyType = "m.room_key"
    /// To-device event type carrying a forwarded Megolm session (spec
    /// `m.forwarded_room_key`). Non-originators answer key requests
    /// with this type; accepted on receipt like `m.room_key` (see
    /// `receiveRoomKey` and `shareRequestedSession`).
    public static let forwardedRoomKeyType = "m.forwarded_room_key"
    /// To-device event type requesting a Megolm session (`m.room_key_request`).
    /// Peers send these when they hold ciphertext for an unknown — or
    /// held-but-too-old — session; see `keyRequestContent`,
    /// `onUnknownSession`, and `shareCurrentSession`.
    public static let keyRequestType = "m.room_key_request"

    /// An undecryptable session sighting: room, session, and sender to
    /// request the key from.
    public struct UnknownSession: Sendable {
        public var roomId: RoomId
        public var sessionId: String
        public var sender: UserId
    }

    /// An inbound share as received, for byte-identical forwarding.
    /// Re-sending the originator's bytes keeps their signature valid;
    /// anything we re-encode ourselves (exports) is unsigned. Chain and
    /// claimed keys are best-effort: direct `m.room_key` shares carry
    /// no attribution, and to-device receipt drops the sender's device
    /// key, so first-forwards legitimately send an empty chain (spec:
    /// the chain is empty between the first two holders).
    private struct ReceivedShare: Sendable {
        var blob: Data
        var chain: [String]
        var claimedEd25519: String?
        var senderKey: String?
    }

    private static let storeService = "MatrixKit.RoomCrypto"

    private let sharer: any RoomKeySharer
    private let sender: any RoomEventSender
    private let keystore: (any KeyStore)?

    /// Outbound sessions by room ID value. Fresh per launch; inbound
    /// sessions persist via the keystore (see `restore()`).
    private var outbound: [String: MegolmSession] = [:]
    /// Earliest signed state per outbound session, by room ID value:
    /// `(sessionId, blob)` captured at first-send position (see
    /// `sendEncryptedContent`). In-memory only like `outbound`.
    private var initialShares: [String: (sessionId: String, blob: Data)] = [:]
    /// Inbound sessions by `"roomId|sessionId"`.
    private var inbound: [String: MegolmSession] = [:]
    /// Original `session_key` blobs as received, by `"roomId|sessionId"`.
    /// Served byte-identical on key requests (see
    /// `shareRequestedSession`). In-memory only: after a restart the
    /// export fallback applies.
    private var receivedBlobs: [String: ReceivedShare] = [:]
    /// Signed sharing blobs at each outbound session's first-send
    /// position, by room ID. Key requests for our own sessions are
    /// answered from here (see `shareRequestedSession`) so old history
    /// stays decryptable for requesters instead of failing with
    /// `indexTooOld` against the current ratchet position.
    /// Room IDs whose current outbound session has been shared.
    /// Cleared by `rotateOutbound(_:)`; empty after launch (fresh
    /// outbound), so the first `ensureShared` re-shares post-restart.
    private var shared: Set<String> = []
    /// `"roomId|sessionId"` keys already surfaced via `onUnknownSession`.
    /// Cleared for a session when its key arrives, so a later re-loss
    /// re-requests. Capped to bound memory on pathological timelines.
    private var requestedSessions: Set<String> = []
    /// `"roomId|sessionId"` keys already tried against the key backup.
    /// Never re-armed within a launch: backup content is static per
    /// version, so a miss stays a miss. Capped like `requestedSessions`.
    private var backupFetchAttempted: Set<String> = []
    /// `request_id`s already served, so duplicate key requests share once.
    private var servedRequestIds: Set<String> = []
    /// Local user: own sends never trigger key requests (self-decrypt is
    /// registered at send time). Nil until `setLocalUserId` runs.
    private var localUserId: UserId?
    /// Fired once per unknown inbound session — and once per held-but-
    /// too-old session (see `decryptRoomEvent`). The owner builds an
    /// `m.room_key_request` via `keyRequestContent` and sends it to
    /// `UnknownSession.sender`.
    private var onUnknownSession: (@Sendable (UnknownSession) -> Void)?

    public init(
        sharer: any RoomKeySharer, sender: any RoomEventSender,
        keystore: (any KeyStore)? = nil
    ) {
        self.sharer = sharer
        self.sender = sender
        self.keystore = keystore
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

    /// Record a backup-fetch attempt for a session, returning true when
    /// first seen (the caller should try the download once). Check the
    /// cached backup key first: without one the attempt is not
    /// consumed, so a later 4S unlock still gets its chance.
    func claimBackupFetch(roomId: RoomId, sessionId: String) -> Bool {
        let key = "\(roomId.value)|\(sessionId)"
        guard !backupFetchAttempted.contains(key) else { return false }
        backupFetchAttempted.insert(key)
        if backupFetchAttempted.count > 1000 { backupFetchAttempted.removeAll() }
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
            MatrixKitLog.crypto.warning("RoomCrypto persist failed error=\(error, privacy: .public)")
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
            MatrixKitLog.crypto.warning("RoomCrypto delete failed error=\(error, privacy: .public)")
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
        deviceId: DeviceId? = nil,
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
                // Stash the signed blob at its pre-encrypt position: the
                // earliest signed state of this outbound session, used to
                // answer key requests for old history (see
                // `shareRequestedSession`).
                initialShares[roomId.value] = (
                    sessionId: session.id, blob: keyBlob)
            } else {
                MatrixKitLog.crypto.debug(
                    "RoomCrypto could not register outbound session for self-decrypt room=\(roomId.value, privacy: .private(mask: .hash))"
                )
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
        // `device_id` is required on `m.room.encrypted` Megolm events:
        // without it recipients cannot parse the envelope.
        if let deviceId {
            content["device_id"] = .string(deviceId.value)
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
                MatrixKitLog.crypto.warning(
                    "RoomCrypto skipping key share: device query failed user=\(user.value, privacy: .private(mask: .hash)) error=\(error, privacy: .public)"
                )
                continue
            }
            let devices = ids
                .filter { $0 != excludingDevice?.value }
                .map { DeviceId($0) }
            guard !devices.isEmpty else {
                MatrixKitLog.crypto.warning(
                    "RoomCrypto skipping key share: no devices user=\(user.value, privacy: .private(mask: .hash))"
                )
                continue
            }
            try await shareCurrentSession(
                roomId: roomId, to: user, devices: devices)
        }
        shared.insert(roomId.value)
    }

    /// Share the room's current outbound session (created if needed) with
    /// one user's explicit devices. Backs `shareRoomKey` (key-request
    /// serving goes through `shareRequestedSession` so it answers with
    /// the requested session, not the current one).
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

    /// Current outbound session ID for a room, if one exists. Test seam
    /// for key-request flows (requests name the session they need).
    public func outboundSessionId(for roomId: RoomId) -> String? {
        outbound[roomId.value]?.id
    }

    /// `m.room_key` content for a signed sharing blob.
    private static func roomKeyContent(
        roomId: RoomId, sessionId: String, blob: Data
    ) -> [String: AnyCodable] {
        [
            "algorithm": .string(Self.megolmAlgorithm),
            "room_id": .string(roomId.value),
            "session_id": .string(sessionId),
            "session_key": .string(
                Primitives.base64UnpaddedEncode(blob)),
        ]
    }

    /// `m.forwarded_room_key` content for a held session. Chain and
    /// claimed keys are best-effort (see `ReceivedShare`): omitted
    /// when unknown rather than fabricated. Our own parser accepts
    /// the missing fields; strict third parties may require them.
    private static func forwardedKeyContent(
        roomId: RoomId, sessionId: String, blob: Data,
        chain: [String], claimedEd25519: String?, senderKey: String?
    ) -> [String: AnyCodable] {
        var content: [String: AnyCodable] = [
            "algorithm": .string(Self.megolmAlgorithm),
            "room_id": .string(roomId.value),
            "session_id": .string(sessionId),
            "session_key": .string(
                Primitives.base64UnpaddedEncode(blob)),
            "forwarding_curve25519_key_chain": .array(
                chain.map(AnyCodable.string)),
        ]
        if let claimedEd25519 {
            content["sender_claimed_ed25519_key"] = .string(claimedEd25519)
        }
        if let senderKey {
            content["sender_key"] = .string(senderKey)
        }
        return content
    }

    /// Share the requested session when held, and only then. Own
    /// sessions go out as `m.room_key` with the earliest SIGNED state
    /// (first-send stash, else current) so third-party clients accept
    /// them and old history stays decryptable. Other sessions go out
    /// as `m.forwarded_room_key`: byte-identical originals when the
    /// share arrived this launch (originator signature intact), else
    /// the export fallback. Returns false when the session is unknown
    /// — the caller must not fall back to a different session, or the
    /// requester stays undecryptable.
    public func shareRequestedSession(
        roomId: RoomId, sessionId: String, to user: UserId,
        devices: [DeviceId]
    ) async throws(MatrixError) -> Bool {
        let mapKey = "\(roomId.value)|\(sessionId)"
        if outbound[roomId.value]?.id == sessionId {
            if let initial = initialShares[roomId.value],
                initial.sessionId == sessionId
            {
                try await sharer.sendEncrypted(
                    eventType: Self.roomKeyType,
                    content: Self.roomKeyContent(
                        roomId: roomId, sessionId: sessionId,
                        blob: initial.blob),
                    to: user, devices: devices)
                return true
            }
            try await shareCurrentSession(
                roomId: roomId, to: user, devices: devices)
            return true
        }
        guard let held = inbound[mapKey] else { return false }
        let content: [String: AnyCodable]
        if let received = receivedBlobs[mapKey] {
            content = Self.forwardedKeyContent(
                roomId: roomId, sessionId: sessionId, blob: received.blob,
                chain: received.chain, claimedEd25519: received.claimedEd25519,
                senderKey: received.senderKey)
        } else {
            content = Self.forwardedKeyContent(
                roomId: roomId, sessionId: sessionId, blob: held.export(),
                chain: [], claimedEd25519: nil, senderKey: nil)
        }
        try await sharer.sendEncrypted(
            eventType: Self.forwardedRoomKeyType, content: content,
            to: user, devices: devices)
        return true
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
    /// the inbound map, persisting it like a received room key. Keeps
    /// the earliest-held state: arrivals at or beyond the held ratchet
    /// position are ignored so a late share never regresses history.
    /// Returns true when stored.
    @discardableResult
    public func importSession(
        roomId: RoomId, sessionId: String, export: Data
    ) async throws(MatrixError) -> Bool {
        guard let session = try? MegolmSession.importSessionKey(export) else {
            throw .encodingError("Cannot import session export for \(roomId.value)")
        }
        let key = "\(roomId.value)|\(sessionId)"
        if let held = inbound[key], !isEarlier(arrival: session, than: held) {
            MatrixKitLog.crypto.debug(
                "RoomCrypto ignoring superseded session import session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            return false
        }
        inbound[key] = session
        await persist()
        return true
    }

    /// Whether an arriving session state decrypts strictly more history
    /// than the held one (lower first message index). Missing counters
    /// fail open toward storing: a key that cannot be compared is
    /// safer kept than dropped.
    private func isEarlier(arrival: MegolmSession, than held: MegolmSession) -> Bool {
        guard
            let arrivalFirst = arrival.firstMessageIndex,
            let heldFirst = held.firstMessageIndex
        else { return true }
        return arrivalFirst < heldFirst
    }

    // MARK: - Receive

    /// Import an `m.room_key` or `m.forwarded_room_key` to-device
    /// event's session. Unknown event types and malformed blobs are
    /// ignored (logged at debug). Keeps the earliest-held state: a
    /// share at or beyond the held ratchet position never regresses
    /// history (see `isEarlier`). Returns the room ID when a session
    /// was stored, so the caller can re-run timeline decryption for
    /// that room; nil when ignored or superseded.
    @discardableResult
    public func receiveRoomKey(_ event: BasicEvent) async -> RoomId? {
        guard
            event.type == Self.roomKeyType
                || event.type == Self.forwardedRoomKeyType
        else { return nil }
        guard
            let algorithm = event.content["algorithm"]?.stringValue,
            algorithm == Self.megolmAlgorithm,
            let roomId = event.content["room_id"]?.stringValue,
            let sessionId = event.content["session_id"]?.stringValue,
            let keyB64 = event.content["session_key"]?.stringValue,
            let blob = Primitives.base64UnpaddedDecode(keyB64),
            let session = try? MegolmSession.importSessionKey(blob)
        else {
            MatrixKitLog.crypto.debug(
                "RoomCrypto ignoring malformed room key sender=\(event.sender?.value ?? "?", privacy: .private(mask: .hash)) type=\(event.type, privacy: .public)"
            )
            return nil
        }
        let mapKey = "\(roomId)|\(sessionId)"
        // Re-arm key requests: a well-formed share answers the
        // outstanding ask whether or not it improves our position, so
        // the next undecryptable sighting asks again instead of
        // staying silent when only late state has arrived so far.
        requestedSessions.remove(mapKey)
        if let held = inbound[mapKey], !isEarlier(arrival: session, than: held) {
            MatrixKitLog.crypto.debug(
                "RoomCrypto ignoring superseded room key sender=\(event.sender?.value ?? "?", privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash)) type=\(event.type, privacy: .public)"
            )
            return nil
        }
        inbound[mapKey] = session
        receivedBlobs[mapKey] = ReceivedShare(
            blob: blob,
            chain: event.content["forwarding_curve25519_key_chain"]?
                .arrayValue?.compactMap(\.stringValue) ?? [],
            claimedEd25519: event.content["sender_claimed_ed25519_key"]?
                .stringValue,
            senderKey: event.content["sender_key"]?.stringValue)
        await persist()
        return RoomId(unchecked: roomId)
    }

    /// Decrypt an `m.room.encrypted` timeline event, returning the inner
    /// event (same envelope, decrypted type + content). Clear events pass
    /// through unchanged; undecryptable events (no session, bad crypto,
    /// non-JSON plaintext) return nil — callers keep the ciphertext.
    /// Unknown sessions from other users fire `onUnknownSession` once per
    /// session so the owner can send `m.room_key_request`. Held-but-
    /// too-old sessions fire it too: a peer holding an earlier state (or
    /// the key backup) can still fill the gap.
    public func decryptRoomEvent(
        _ event: MessageEvent, in roomId: RoomId
    ) async -> MessageEvent? {
        guard event.type == Self.roomEncryptedType else { return event }
        guard
            let sessionId = event.content["session_id"]?.stringValue,
            let cipherB64 = event.content["ciphertext"]?.stringValue,
            let wire = Primitives.base64UnpaddedDecode(cipherB64)
        else {
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: malformed envelope sender=\(event.sender.value, privacy: .private(mask: .hash))"
            )
            return nil
        }
        guard var session = inbound["\(roomId.value)|\(sessionId)"] else {
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: unknown inbound session sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            MatrixKitLog.crypto.debug(
                "RoomCrypto decrypt failure: unknown inbound session sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(sessionId, privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash))"
            )
            if event.sender != localUserId,
                claimUnknownSession(roomId: roomId, sessionId: sessionId)
            {
                onUnknownSession?(UnknownSession(
                    roomId: roomId, sessionId: sessionId,
                    sender: event.sender))
            }
            return nil
        }
        let plaintext: Data
        do {
            plaintext = try session.decrypt(wire)
        } catch {
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: Megolm payload failed sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            MatrixKitLog.crypto.debug(
                "RoomCrypto decrypt failure sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(sessionId, privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash)) error=\(error, privacy: .public)"
            )
            // A held-but-too-old session may still be recoverable: a
            // peer holding an earlier state (or the key backup) can
            // fill the gap, so surface one key request like an unknown
            // session. Replays and bad crypto are local-only failures
            // that no peer can fix — no request.
            if event.sender != localUserId,
                let cryptoError = error as? CryptoError,
                cryptoError == .indexTooOld,
                claimUnknownSession(roomId: roomId, sessionId: sessionId)
            {
                onUnknownSession?(UnknownSession(
                    roomId: roomId, sessionId: sessionId,
                    sender: event.sender))
            }
            return nil
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: plaintext),
            let dict = json as? [String: Any],
            let type = dict["type"] as? String,
            let contentJSON = dict["content"],
            let contentData = try? JSONSerialization.data(
                withJSONObject: contentJSON),
            let content = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: contentData)
        else {
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: Megolm payload failed sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            MatrixKitLog.crypto.debug(
                "RoomCrypto decrypt failure: plaintext is not JSON sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(sessionId, privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash))"
            )
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
