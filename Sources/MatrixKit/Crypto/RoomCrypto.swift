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

    /// When a room's outbound session is retired, from `m.room.encryption`
    /// (`rotation_period_ms`, `rotation_period_msgs`).
    public struct RotationPolicy: Hashable, Sendable {
        /// Maximum session age in milliseconds.
        public var periodMs: Int
        /// Maximum messages sent under one session.
        public var messages: Int

        /// The spec defaults: one week, 100 messages.
        public static let `default` = RotationPolicy(
            periodMs: 604_800_000, messages: 100)

        public init(periodMs: Int, messages: Int) {
            self.periodMs = periodMs
            self.messages = messages
        }

        /// Read `m.room.encryption` content; absent or non-positive
        /// values fall back to the defaults.
        public init(content: [String: AnyCodable]) {
            let period = content["rotation_period_ms"]?.intValue
            let messages = content["rotation_period_msgs"]?.intValue
            self.init(
                periodMs: period.flatMap { $0 > 0 ? $0 : nil }
                    ?? Self.default.periodMs,
                messages: messages.flatMap { $0 > 0 ? $0 : nil }
                    ?? Self.default.messages)
        }
    }

    /// An undecryptable session sighting: room, session, and sender to
    /// request the key from.
    public struct UnknownSession: Sendable {
        public var roomId: RoomId
        public var sessionId: String
        public var sender: UserId
    }

    /// Why one encrypted timeline event could not be decrypted.
    public enum DecryptionFailureReason: String, Hashable, Sendable {
        case unknownSession
        case sessionTooOld
        case replay
        case cryptoFailure
        case malformedEnvelope
        case nonJSONPlaintext
    }

    /// Diagnostic details for an undecryptable encrypted event.
    public struct DecryptionFailure: Hashable, Sendable {
        public var reason: DecryptionFailureReason
        public var sessionId: String?

        public init(reason: DecryptionFailureReason, sessionId: String? = nil) {
            self.reason = reason
            self.sessionId = sessionId
        }
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
    private static let decryptionFailureLimit = 10_000
    private static let decryptedMessageLimit = 50_000
    private static let maxAttributionAttempts = 3
    private static let keyRequestCooldown: TimeInterval = 120
    private static let maxKeyRequestAttempts = 3

    private let sharer: any RoomKeySharer
    private let sender: any RoomEventSender
    private let keystore: (any KeyStore)?
    private let now: @Sendable () -> Date

    /// Debounced megolm persistence (see `PersistCoalescer`), created
    /// on first mutation so `init` never captures `self`.
    private var persister: PersistCoalescer?

    /// Outbound sessions by room ID value. Fresh per launch; inbound
    /// sessions persist via the keystore (see `restore()`).
    private var outbound: [String: MegolmSession] = [:]
    /// Earliest signed state per outbound session, by room ID value:
    /// `(sessionId, blob)` captured at first-send position (see
    /// `sendEncryptedContent`). In-memory only like `outbound`.
    private var initialShares: [String: (sessionId: String, blob: Data)] = [:]
    /// Inbound sessions by `"roomId|sessionId"`.
    private var inbound: [String: MegolmSession] = [:]
    /// Origin of each inbound session, by `"roomId|sessionId"`. Absent
    /// for sessions persisted before origins were recorded.
    private var origins: [String: SessionOrigin] = [:]
    /// Key backup version each inbound session (at its held state) is
    /// stored in, by `"roomId|sessionId"`.
    private var backedUpVersions: [String: String] = [:]
    /// Original `session_key` blobs as received, by `"roomId|sessionId"`.
    /// Served byte-identical on key requests (see
    /// `shareRequestedSession`). In-memory only: after a restart the
    /// export fallback applies.
    private var receivedBlobs: [String: ReceivedShare] = [:]
    /// Device IDs each room's current outbound session has been shared
    /// with, by room ID then user ID (a user with no devices maps to an
    /// empty set). Cleared by `rotateOutbound(_:)`; empty after launch
    /// (fresh outbound), so the first `ensureShared` re-shares
    /// post-restart.
    private var sharedWith: [String: [String: Set<String>]] = [:]
    /// When each room's current outbound session was created.
    private var outboundCreated: [String: Date] = [:]
    /// Rotation limits per room ID, loaded on first use.
    private var rotationPolicies: [String: RotationPolicy] = [:]
    /// Fetches a room's rotation limits (nil when unavailable, which
    /// applies the defaults and retries on the next send).
    private var rotationPolicyProvider:
        (@Sendable (RoomId) async -> RotationPolicy?)?
    private struct KeyRequestState {
        var attempts: Int
        var lastRequestedAt: Date?
    }

    /// `"roomId|sessionId"` key-request cooldowns and attempts. Arrival
    /// of a key clears the cooldown but preserves the per-launch cap.
    private var requestedSessions: [String: KeyRequestState] = [:]
    /// Decryption diagnostics keyed by `"roomId|eventId"`; a successful
    /// retry removes its prior failure. Capped for long-running syncs.
    private var decryptionFailures: [String: DecryptionFailure] = [:]
    /// The event each Megolm message index was decrypted for, by
    /// `"roomId|sessionId|index"`. A later event claiming an index
    /// that decrypted for another event (or at another timestamp) is a
    /// replay. In-memory and capped: replays of messages decrypted in an
    /// earlier launch, or evicted since, go undetected.
    private var decryptedMessages: [String: DecryptedMessage] = [:]
    private struct DecryptedMessage {
        var eventId: EventId
        var originServerTs: Int
    }
    /// Sessions whose origin is being looked up, by `"roomId|sessionId"`.
    private var attributionInFlight: Set<String> = []
    /// Origin lookups made per session. A failed lookup is retried on a
    /// later event, up to `maxAttributionAttempts`; a device that does
    /// not exist ends the attempts at once.
    private var attributionAttempts: [String: Int] = [:]
    /// `"roomId|sessionId"` keys already tried against the key backup.
    /// Never re-armed within a launch: backup content is static per
    /// version, so a miss stays a miss. Capped like `requestedSessions`.
    private var backupFetchAttempted: Set<String> = []
    /// `request_id`s already served, so duplicate key requests share once.
    private var servedRequestIds: Set<String> = []
    /// Local user: own sends never trigger key requests (self-decrypt is
    /// registered at send time). Nil until `setLocalUserId` runs.
    private var localUserId: UserId?
    /// Fired for unknown inbound sessions and held-but-too-old sessions
    /// (see `decryptRoomEvent`), with retries governed by the per-session
    /// cooldown. The owner builds an `m.room_key_request` via
    /// `keyRequestContent` and sends it to `UnknownSession.sender`.
    private var onUnknownSession: (@Sendable (UnknownSession) -> Void)?
    /// Fired when a session that may need backing up was stored (see
    /// `sessionsPendingBackup`).
    private var onSessionsChanged: (@Sendable () -> Void)?

    /// Persisted form of one inbound session.
    private struct StoredSession: Codable {
        var export: String
        var origin: SessionOrigin?
        var backedUpVersion: String?
    }

    public init(
        sharer: any RoomKeySharer, sender: any RoomEventSender,
        keystore: (any KeyStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sharer = sharer
        self.sender = sender
        self.keystore = keystore
        self.now = now
    }

    /// Record a megolm-state mutation for debounced persistence.
    private func markPersistDirty() async {
        if persister == nil {
            persister = PersistCoalescer { [weak self] in
                await self?.persist()
            }
        }
        await persister?.markDirty()
    }

    /// Write any coalesced megolm state immediately. Call on paths
    /// where the debounce loss window is unacceptable (e.g. app
    /// termination) and in tests that re-read the store right away.
    public func flushCryptoState() async {
        await persister?.flush()
    }

    // MARK: - Key requests

    /// Set the local user (own sends never trigger key requests).
    public func setLocalUserId(_ userId: UserId?) {
        localUserId = userId
    }

    /// Install the handler fired when a stored session may need backing
    /// up (see `sessionsPendingBackup`).
    public func setSessionsChangedHandler(
        _ handler: (@Sendable () -> Void)?
    ) {
        onSessionsChanged = handler
    }

    /// Install the source of per-room rotation limits (see
    /// `RotationPolicy`).
    public func setRotationPolicyProvider(
        _ provider: (@Sendable (RoomId) async -> RotationPolicy?)?
    ) {
        rotationPolicyProvider = provider
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

    /// Record an unknown session, returning true when a key request is
    /// due. Requests are limited to three per session per launch, at
    /// least two minutes apart. Re-armed immediately by `receiveRoomKey`.
    func claimUnknownSession(roomId: RoomId, sessionId: String) -> Bool {
        let key = "\(roomId.value)|\(sessionId)"
        let currentTime = now()
        if var state = requestedSessions[key] {
            guard state.attempts < Self.maxKeyRequestAttempts else { return false }
            if let lastRequestedAt = state.lastRequestedAt,
                currentTime.timeIntervalSince(lastRequestedAt) < Self.keyRequestCooldown
            {
                return false
            }
            state.attempts += 1
            state.lastRequestedAt = currentTime
            requestedSessions[key] = state
        } else {
            requestedSessions[key] = KeyRequestState(
                attempts: 1, lastRequestedAt: currentTime)
        }
        if requestedSessions.count > 1000,
            let oldestKey = requestedSessions.min(by: {
                ($0.value.lastRequestedAt ?? .distantPast)
                    < ($1.value.lastRequestedAt ?? .distantPast)
            })?.key
        {
            requestedSessions[oldestKey] = nil
        }
        return true
    }

    /// Details for one event that most recently failed decryption.
    public func decryptionFailure(
        roomId: RoomId, eventId: EventId
    ) -> DecryptionFailure? {
        decryptionFailures["\(roomId.value)|\(eventId.value)"]
    }

    private func recordDecryptionFailure(
        _ failure: DecryptionFailure, for key: String
    ) {
        decryptionFailures[key] = failure
        if decryptionFailures.count > Self.decryptionFailureLimit,
            let keyToEvict = decryptionFailures.keys.first(where: { $0 != key })
        {
            decryptionFailures[keyToEvict] = nil
        }
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
                service: Self.storeService, account: "megolm"))
        else { return }
        let stored: [String: StoredSession]
        if let current = try? JSONDecoder().decode(
            [String: StoredSession].self, from: data)
        {
            stored = current
        } else if let legacy = try? JSONDecoder().decode(
            [String: String].self, from: data)
        {
            // Earlier builds stored bare exports.
            stored = legacy.mapValues { StoredSession(export: $0) }
        } else {
            return
        }
        for (key, entry) in stored {
            guard
                let blob = Primitives.base64UnpaddedDecode(entry.export),
                let session = try? MegolmSession.importSessionKey(blob)
            else { continue }
            inbound[key] = session
            origins[key] = entry.origin
            backedUpVersions[key] = entry.backedUpVersion
        }
    }

    /// The coalesced write body — call sites record mutations with
    /// `markPersistDirty()` instead of calling this directly.
    private func persist() async {
        guard let keystore else { return }
        var stored: [String: StoredSession] = [:]
        for (key, session) in inbound {
            stored[key] = StoredSession(
                export: Primitives.base64UnpaddedEncode(session.export()),
                origin: origins[key], backedUpVersion: backedUpVersions[key])
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
        await persister?.cancel()
        guard let keystore else { return }
        do {
            try await keystore.delete(KeyStoreKey(
                service: Self.storeService, account: "megolm"))
        } catch {
            MatrixKitLog.crypto.warning("RoomCrypto delete failed error=\(error, privacy: .public)")
        }
    }

    // MARK: - Send

    /// Encrypt `content` as an event of `eventType` (a message unless
    /// told otherwise) under the room's outbound session (created on
    /// first use) and send it as `m.room.encrypted`. The inner type is
    /// what recipients decrypt, so events that are not messages — polls,
    /// reactions — must name theirs. Call `ensureShared(roomId:users:)` first so
    /// recipients hold the session. The outbound session is also
    /// registered for self-decryption: the sender never receives its own
    /// `m.room_key`, so without this the sync echo of sent events would
    /// stay undecryptable. Pass the staged local-echo transaction ID so
    /// sync confirms the echo instead of duplicating it.
    @discardableResult
    public func sendEncryptedContent(
        _ roomId: RoomId, _ content: any Encodable & Sendable,
        eventType: String = EventType.roomMessage.rawValue,
        deviceId: DeviceId? = nil,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        var session = outboundSession(for: roomId)
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
                if let senderKey = try? await sharer.identityKey(),
                    let claimed = try? await sharer.signingKey()
                {
                    origins[inboundKey] = SessionOrigin(
                        senderKey: senderKey, claimedEd25519: claimed)
                    onSessionsChanged?()
                }
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
        var relation: AnyCodable?
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
            if let value = content["m.relates_to"] {
                relation = try? JSONDecoder().decode(
                    AnyCodable.self,
                    from: JSONSerialization.data(withJSONObject: value))
            }
            plaintext = try JSONSerialization.data(
                withJSONObject: [
                    "room_id": roomId.value,
                    "type": eventType,
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
        // The server cannot read the payload, but it aggregates edits and
        // threads, and counts thread notifications, from the relation, so
        // it is repeated in the clear as other clients do. Recipients
        // read the relation inside the payload.
        if let relation {
            content["m.relates_to"] = relation
        }
        // `device_id` is required on `m.room.encrypted` Megolm events:
        // without it recipients cannot parse the envelope.
        if let deviceId {
            content["device_id"] = .string(deviceId.value)
        }
        let eventId = try await sender.sendEvent(
            roomId, eventType: Self.roomEncryptedType, content: content,
            transactionId: transactionId)
        await markPersistDirty()
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
            guard let ids = await deviceIds(of: user, excluding: excludingDevice) else {
                continue
            }
            try await share(roomId: roomId, to: user, devices: ids)
        }
    }

    /// Device IDs for `user` except `excluded`, or nil (logged) when the
    /// lookup fails.
    private func deviceIds(
        of user: UserId, excluding excluded: DeviceId?
    ) async -> Set<String>? {
        do {
            return Set(try await sharer.deviceIds(for: user))
                .subtracting([excluded?.value].compactMap { $0 })
        } catch {
            MatrixKitLog.crypto.warning(
                "RoomCrypto skipping key share: device query failed user=\(user.value, privacy: .private(mask: .hash)) error=\(error, privacy: .public)"
            )
            return nil
        }
    }

    /// Share the current session with `devices` of `user` and record
    /// them as reached. A user without devices is recorded too, so the
    /// lookup is not repeated on every send.
    private func share(
        roomId: RoomId, to user: UserId, devices: Set<String>
    ) async throws(MatrixError) {
        guard !devices.isEmpty else {
            MatrixKitLog.crypto.warning(
                "RoomCrypto skipping key share: no devices user=\(user.value, privacy: .private(mask: .hash))"
            )
            sharedWith[roomId.value, default: [:]][user.value, default: []] = []
            return
        }
        try await shareCurrentSession(
            roomId: roomId, to: user, devices: devices.sorted().map { DeviceId($0) })
        sharedWith[roomId.value, default: [:]][user.value, default: []]
            .formUnion(devices)
    }

    /// Share the room's current outbound session (created if needed) with
    /// one user's explicit devices. Backs `shareRoomKey` (key-request
    /// serving goes through `shareRequestedSession` so it answers with
    /// the requested session, not the current one).
    public func shareCurrentSession(
        roomId: RoomId, to user: UserId, devices: [DeviceId]
    ) async throws(MatrixError) {
        let session = outboundSession(for: roomId)
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

    /// Prepare the room's outbound session for the next send: retire it
    /// when a user or device it was shared with is gone or it has reached
    /// the room's rotation limits, then share the (possibly new) session
    /// with every device of `users` it has not reached. Call before
    /// every send: a session that rotates mid-send is unshared. Backs the
    /// `MatrixClient.sendEncryptedContent` convenience.
    ///
    /// A user or device that appeared since the last send gets the
    /// session from its current position, so earlier messages stay
    /// unreadable to them. A user whose device lookup fails is left
    /// alone until the next send.
    public func ensureShared(
        roomId: RoomId, users: [UserId], excludingDevice: DeviceId? = nil
    ) async throws(MatrixError) {
        let key = roomId.value
        var current: [String: Set<String>] = [:]
        for user in users {
            if let ids = await deviceIds(of: user, excluding: excludingDevice) {
                current[user.value] = ids
            }
        }
        if await shouldRotate(
            roomId: roomId, members: Set(users.map(\.value)), devices: current)
        {
            rotateOutbound(roomId: roomId)
        }
        for user in users {
            guard let ids = current[user.value] else { continue }
            let reached = sharedWith[key]?[user.value]
            let pending = ids.subtracting(reached ?? [])
            guard reached == nil || !pending.isEmpty else { continue }
            try await share(roomId: roomId, to: user, devices: pending)
        }
    }

    /// Drop the outbound session so the next send starts a fresh one
    /// (forward secrecy on membership change). The fresh session is
    /// unshared: the next `ensureShared` re-shares it.
    public func rotateOutbound(roomId: RoomId) {
        outbound[roomId.value] = nil
        sharedWith[roomId.value] = nil
        outboundCreated[roomId.value] = nil
    }

    /// The room's outbound session, created and timestamped on first use.
    private func outboundSession(for roomId: RoomId) -> MegolmSession {
        if let existing = outbound[roomId.value] { return existing }
        let session = MegolmSession.create()
        outbound[roomId.value] = session
        outboundCreated[roomId.value] = now()
        return session
    }

    /// Whether the room's outbound session must be retired before the
    /// next send: a user or device it reached is gone (`devices` holds
    /// the current devices of users whose lookup succeeded), or it is
    /// past the room's age or message limit.
    private func shouldRotate(
        roomId: RoomId, members: Set<String>, devices: [String: Set<String>]
    ) async -> Bool {
        let key = roomId.value
        guard let session = outbound[key] else { return false }
        if let reached = sharedWith[key] {
            if !Set(reached.keys).isSubset(of: members) { return true }
            for (user, reachedDevices) in reached {
                if let present = devices[user], !reachedDevices.isSubset(of: present) {
                    return true
                }
            }
        }
        let policy = await rotationPolicy(for: roomId)
        let age = now().timeIntervalSince(outboundCreated[key] ?? now())
        return Int(session.counter) >= policy.messages
            || age * 1000 >= Double(policy.periodMs)
    }

    private func rotationPolicy(for roomId: RoomId) async -> RotationPolicy {
        if let known = rotationPolicies[roomId.value] { return known }
        guard let fetched = await rotationPolicyProvider?(roomId) else {
            return .default
        }
        rotationPolicies[roomId.value] = fetched
        return fetched
    }

    // MARK: - Backup

    /// Inbound sessions as backup payloads: room, session ID, the
    /// session export blob, and its origin when known. Keys are
    /// `"roomId|sessionId"` (neither ID may contain a pipe per the
    /// Matrix ID grammar).
    public func backupExports() -> [BackedUpSession] {
        var out: [BackedUpSession] = []
        for (key, session) in inbound {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out.append(BackedUpSession(
                roomId: RoomId(unchecked: parts[0]), sessionId: parts[1],
                export: session.export(), origin: origins[key]))
        }
        return out
    }

    /// Import a session export (e.g. decrypted from a key backup) into
    /// the inbound map, persisting it like a received room key. Keeps
    /// the earliest-held state: arrivals at or beyond the held ratchet
    /// position are ignored so a late share never regresses history.
    /// Returns true when stored.
    ///
    /// `origin` is what the source recorded for the session;
    /// `backedUpVersion` is the backup version the export came from,
    /// so it is not uploaded straight back.
    @discardableResult
    public func importSession(
        roomId: RoomId, sessionId: String, export: Data,
        origin: SessionOrigin? = nil, backedUpVersion: String? = nil
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
        store(session, for: key, origin: origin, backedUpVersion: backedUpVersion)
        await markPersistDirty()
        if backedUpVersion == nil { onSessionsChanged?() }
        return true
    }

    /// Record an inbound session that improves on any held state. A
    /// missing origin keeps the one already known for the session.
    private func store(
        _ session: MegolmSession, for key: String,
        origin: SessionOrigin?, backedUpVersion: String?
    ) {
        inbound[key] = session
        if let origin { origins[key] = origin }
        backedUpVersions[key] = backedUpVersion
    }

    /// Held sessions with a known origin that are not stored in
    /// backup `version`, oldest-first order unspecified. Sessions
    /// without an origin never qualify (see `BackedUpSession`).
    public func sessionsPendingBackup(
        version: String, limit: Int
    ) -> [BackedUpSession] {
        var out: [BackedUpSession] = []
        for (key, session) in inbound {
            guard
                out.count < limit, let origin = origins[key],
                backedUpVersions[key] != version
            else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out.append(BackedUpSession(
                roomId: RoomId(unchecked: parts[0]), sessionId: parts[1],
                export: session.export(), origin: origin))
        }
        return out
    }

    /// How the held sessions stand against backup `version`: stored in
    /// it, waiting to upload, or lacking the origin an upload needs.
    public func backupProgress(
        version: String
    ) -> (backedUp: Int, pending: Int, unattributed: Int) {
        var counts = (backedUp: 0, pending: 0, unattributed: 0)
        for key in inbound.keys {
            if origins[key] == nil {
                counts.unattributed += 1
            } else if backedUpVersions[key] == version {
                counts.backedUp += 1
            } else {
                counts.pending += 1
            }
        }
        return counts
    }

    /// Record that `sessions` are stored in backup `version`. A session
    /// replaced by an earlier state since it was exported is left
    /// pending.
    public func markBackedUp(_ sessions: [BackedUpSession], version: String) async {
        for uploaded in sessions {
            let key = "\(uploaded.roomId.value)|\(uploaded.sessionId)"
            guard inbound[key]?.export() == uploaded.export else { continue }
            backedUpVersions[key] = version
        }
        await markPersistDirty()
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
        // The key must be the session it is filed under: a blob for a
        // different session would shadow the real one and break its
        // messages.
        guard session.id == sessionId.replacing("=", with: "") else {
            logRejectedRoomKey("session ID does not match key", event: event)
            return nil
        }
        if event.type == Self.roomKeyType {
            // Direct shares use the signed sharing format; the signature
            // proves the sender holds the session's signing key.
            guard blob.first == MegolmSession.sharingVersion else {
                logRejectedRoomKey("unsigned session key", event: event)
                return nil
            }
        } else {
            // Forwards carry unsigned exports, so only a device we asked
            // may supply one — anyone else could replace a held session
            // with a corrupt earlier state.
            guard requestedSessions[mapKey] != nil else {
                logRejectedRoomKey("forward was not requested", event: event)
                return nil
            }
        }
        // Re-arm key requests: a well-formed share answers the
        // outstanding ask whether or not it improves our position, so
        // the next undecryptable sighting asks again instead of
        // staying silent when only late state has arrived so far.
        if var request = requestedSessions[mapKey] {
            request.lastRequestedAt = nil
            requestedSessions[mapKey] = request
        }
        let origin = Self.origin(of: event)
        if let held = inbound[mapKey], !isEarlier(arrival: session, than: held) {
            if origins[mapKey] == nil, let origin {
                origins[mapKey] = origin
                await markPersistDirty()
                onSessionsChanged?()
            }
            MatrixKitLog.crypto.debug(
                "RoomCrypto ignoring superseded room key sender=\(event.sender?.value ?? "?", privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash)) type=\(event.type, privacy: .public)"
            )
            return nil
        }
        store(session, for: mapKey, origin: origin, backedUpVersion: nil)
        receivedBlobs[mapKey] = ReceivedShare(
            blob: blob,
            chain: event.content["forwarding_curve25519_key_chain"]?
                .arrayValue?.compactMap(\.stringValue) ?? [],
            claimedEd25519: event.content["sender_claimed_ed25519_key"]?
                .stringValue,
            senderKey: event.content["sender_key"]?.stringValue)
        await markPersistDirty()
        onSessionsChanged?()
        return RoomId(unchecked: roomId)
    }

    private func logRejectedRoomKey(_ reason: StaticString, event: BasicEvent) {
        MatrixKitLog.crypto.debug(
            "RoomCrypto rejecting room key: \(reason, privacy: .public) sender=\(event.sender?.value ?? "?", privacy: .private(mask: .hash)) type=\(event.type, privacy: .public)"
        )
    }

    /// Learn the origin of a session persisted before origins were
    /// recorded from the event it just decrypted. The event's cleartext
    /// `sender_key` is only a claim, so it is checked against the
    /// sender's published devices in the background; decryption never
    /// waits for it.
    private func scheduleAttribution(for key: String, from event: MessageEvent) {
        guard
            origins[key] == nil, !attributionInFlight.contains(key),
            attributionAttempts[key, default: 0] < Self.maxAttributionAttempts,
            let identityKey = event.content["sender_key"]?.stringValue
        else { return }
        attributionInFlight.insert(key)
        let sender = event.sender
        Task { await attribute(key, to: sender, owning: identityKey) }
    }

    private func attribute(
        _ key: String, to sender: UserId, owning identityKey: String
    ) async {
        defer { attributionInFlight.remove(key) }
        if attributionAttempts.count > 10_000 { attributionAttempts.removeAll() }
        attributionAttempts[key, default: 0] += 1
        do {
            guard let device = try await sharer.deviceKeys(
                of: sender, owning: identityKey)
            else {
                attributionAttempts[key] = Self.maxAttributionAttempts
                return
            }
            guard inbound[key] != nil, origins[key] == nil else { return }
            origins[key] = SessionOrigin(
                senderKey: device.curve25519, claimedEd25519: device.ed25519)
            await markPersistDirty()
            onSessionsChanged?()
        } catch {
            MatrixKitLog.crypto.debug(
                "RoomCrypto session attribution failed error=\(error, privacy: .public)"
            )
        }
    }

    /// Origin of the session in a received room-key event, from the
    /// Olm-validated sending device. A direct `m.room_key` was created
    /// by that device; a forward names its creator in the content and
    /// appends the forwarder to the chain. Nil when the event carries no
    /// validated origin or a forward omits attribution.
    private static func origin(of event: BasicEvent) -> SessionOrigin? {
        guard let sender = event.olmOrigin else { return nil }
        if event.type == roomKeyType {
            return SessionOrigin(
                senderKey: sender.curve25519, claimedEd25519: sender.ed25519)
        }
        guard
            let senderKey = event.content["sender_key"]?.stringValue,
            let claimed = event.content["sender_claimed_ed25519_key"]?.stringValue
        else { return nil }
        let chain = event.content["forwarding_curve25519_key_chain"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        return SessionOrigin(
            senderKey: senderKey, claimedEd25519: claimed,
            forwardingChain: chain + [sender.curve25519])
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
        let failureKey = "\(roomId.value)|\(event.eventId.value)"
        guard
            let sessionId = event.content["session_id"]?.stringValue,
            let cipherB64 = event.content["ciphertext"]?.stringValue,
            let wire = Primitives.base64UnpaddedDecode(cipherB64)
        else {
            recordDecryptionFailure(DecryptionFailure(
                reason: .malformedEnvelope,
                sessionId: event.content["session_id"]?.stringValue),
                for: failureKey)
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: malformed envelope sender=\(event.sender.value, privacy: .private(mask: .hash))"
            )
            return nil
        }
        guard var session = inbound["\(roomId.value)|\(sessionId)"] else {
            recordDecryptionFailure(
                DecryptionFailure(reason: .unknownSession, sessionId: sessionId),
                for: failureKey)
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
        let index: UInt32
        do {
            (plaintext, index) = try session.decryptMessage(wire)
        } catch {
            let reason: DecryptionFailureReason
            switch error {
            case .indexTooOld: reason = .sessionTooOld
            default: reason = .cryptoFailure
            }
            recordDecryptionFailure(
                DecryptionFailure(reason: reason, sessionId: sessionId),
                for: failureKey)
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: Megolm payload failed sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            MatrixKitLog.crypto.debug(
                "RoomCrypto decrypt failure sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(sessionId, privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash)) error=\(error, privacy: .public)"
            )
            // A held-but-too-old session may still be recoverable: a
            // peer holding an earlier state (or the key backup) can
            // fill the gap, so surface one key request like an unknown
            // session. Bad crypto is a local-only failure that no peer
            // can fix — no request.
            if event.sender != localUserId,
                error == .indexTooOld,
                claimUnknownSession(roomId: roomId, sessionId: sessionId)
            {
                onUnknownSession?(UnknownSession(
                    roomId: roomId, sessionId: sessionId,
                    sender: event.sender))
            }
            return nil
        }
        // The event must name the device that created the session, when
        // we know it: otherwise a message could be passed off as coming
        // from another device. Events sent before the Curve25519 fix
        // carry the creator's Ed25519 key, and some clients omit the
        // field, so both are accepted.
        if let origin = origins["\(roomId.value)|\(sessionId)"],
            let claimed = event.content["sender_key"]?.stringValue,
            claimed != origin.senderKey, claimed != origin.claimedEd25519
        {
            recordDecryptionFailure(
                DecryptionFailure(reason: .cryptoFailure, sessionId: sessionId),
                for: failureKey)
            MatrixKitLog.crypto.warning(
                "RoomCrypto rejecting event: sender key does not match session sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash))"
            )
            return nil
        }
        // The message authenticated, so its index is trustworthy: the
        // same index arriving in another event (or at another time) is a
        // replay. Return before storing the advanced session copy.
        let messageKey = "\(roomId.value)|\(sessionId)|\(index)"
        if let seen = decryptedMessages[messageKey],
            seen.eventId != event.eventId
                || seen.originServerTs != event.originServerTs
        {
            recordDecryptionFailure(
                DecryptionFailure(reason: .replay, sessionId: sessionId),
                for: failureKey)
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: replayed message index sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash)) index=\(index, privacy: .public)"
            )
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
            recordDecryptionFailure(
                DecryptionFailure(reason: .nonJSONPlaintext, sessionId: sessionId),
                for: failureKey)
            MatrixKitLog.crypto.debug(
                "RoomCrypto cannot decrypt: Megolm payload failed sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(String(sessionId.prefix(8)), privacy: .private(mask: .hash))"
            )
            MatrixKitLog.crypto.debug(
                "RoomCrypto decrypt failure: plaintext is not JSON sender=\(event.sender.value, privacy: .private(mask: .hash)) session=\(sessionId, privacy: .private(mask: .hash)) event=\(event.eventId.value, privacy: .private(mask: .hash))"
            )
            return nil
        }
        decryptionFailures[failureKey] = nil
        decryptedMessages[messageKey] = DecryptedMessage(
            eventId: event.eventId, originServerTs: event.originServerTs)
        if decryptedMessages.count > Self.decryptedMessageLimit,
            let keyToEvict = decryptedMessages.keys.first(where: { $0 != messageKey })
        {
            decryptedMessages[keyToEvict] = nil
        }
        inbound["\(roomId.value)|\(sessionId)"] = session
        await markPersistDirty()
        scheduleAttribution(for: "\(roomId.value)|\(sessionId)", from: event)
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
    /// Unpadded-base64 Curve25519 identity key of the local device, sent
    /// as `sender_key` on room events.
    func identityKey() async throws(MatrixError) -> String
    /// Unpadded-base64 Ed25519 fingerprint key of the local device,
    /// claimed for sessions this device originates.
    func signingKey() async throws(MatrixError) -> String
    /// The Curve25519 and Ed25519 keys of the device of `user` owning
    /// `identityKey` (either of its keys), checked against the device's
    /// own signature; nil when no such device is published. Attributes
    /// sessions whose origin was never recorded.
    func deviceKeys(
        of user: UserId, owning identityKey: String
    ) async throws(MatrixError) -> (curve25519: String, ed25519: String)?
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
