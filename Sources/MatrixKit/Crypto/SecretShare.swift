import Foundation
import MatrixKitCrypto

/// Outcome of feeding one to-device event to `SecretShare.receive(_:)`.
public enum SecretReceiveOutcome: Hashable, Sendable {
    /// Not an `m.secret.send` (or undecodable — e.g. Olm-encrypted).
    case ignored
    /// A secret answer, but for no request we sent.
    case unknownRequest
    /// Secret banked under its name; still waiting for the other halves.
    case stored(name: String)
    /// All three halves arrived, imported, and persisted.
    case completed
}

/// Fires when incoming secret halves finish the set.
public enum SecretShareEvent: Sendable, Equatable {
    /// All three halves arrived, imported, and persisted.
    case secretsCompleted
    /// A requested `m.megolm_backup.v1` key arrived. Carries the
    /// decoded private key (never persisted here — the caller decides).
    case backupKeyReceived(Data)
}

/// Cross-signing secret sharing: ask verified peers for private halves,
/// and answer their requests when we hold the secrets.
///
/// After `verify` succeeds without local keys, this fires
/// `m.secret.request` at the peer and commits incoming `m.secret.send`
/// answers into `CrossSigning` (+ the `CrossSigningStore` file), so the
/// next launch autoloads them and `verify` can sign.
///
/// Mirrors what Rust SDK clients do automatically post-verify. Answers
/// arrive Olm-encrypted and are decrypted by `OlmConnector` before
/// reaching `receive(_:)`; our own answers go out encrypted via
/// `OlmConnector.sendEncrypted` when one is wired in (nil = requester
/// only, answers nothing).
public actor SecretShare {
    private let sender: any ToDeviceSender
    private let session: Session
    private let crossSigning: CrossSigning
    private let store: CrossSigningStore?
    private let backupKeyStore: BackupKeyStore?
    private let olm: OlmConnector?

    /// `requestId` → secret name for requests we sent.
    private var pending: [String: String] = [:]
    /// Secret name → private half banked from answers.
    private var received: [String: String] = [:]
    /// Backup private key from 4S recovery or a peer's share, for
    /// targeted backup fetches and for answering peers'
    /// `m.megolm_backup.v1` requests. Persisted through
    /// `backupKeyStore` and reloaded by `autoload()`.
    private var heldBackupKey: Data?

    public init(
        sender: any ToDeviceSender,
        session: Session,
        crossSigning: CrossSigning,
        store: CrossSigningStore?,
        backupKeyStore: BackupKeyStore? = nil,
        olm: OlmConnector? = nil
    ) {
        self.sender = sender
        self.session = session
        self.crossSigning = crossSigning
        self.store = store
        self.backupKeyStore = backupKeyStore
        self.olm = olm
    }

    /// Outstanding secret requests (for polling loops).
    public var pendingCount: Int { pending.count }

    private var continuations: [AsyncStream<SecretShareEvent>.Continuation] = []

    /// Subscribe to secret-sharing completion. Ends on cancellation.
    public func events() -> AsyncStream<SecretShareEvent> {
        let (stream, continuation) = AsyncStream<SecretShareEvent>.makeStream()
        continuations.append(continuation)
        return stream
    }

    private func notify(_ event: SecretShareEvent) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    // MARK: - Request

    /// Ask a peer device for all three cross-signing private halves.
    /// Pass a device ID to target one device, nil for all (`"*"`).
    /// Returns the request IDs (answers arrive as `m.secret.send`).
    ///
    /// Requests go out UNENCRYPTED per the spec (`m.secret.request`
    /// must be plaintext; only the `m.secret.send` answer is
    /// encrypted). Peers that demand the spec's `action` field are
    /// satisfied by `SecretRequest` (which always sends `"request"`).
    @discardableResult
    public func requestSecrets(
        from userId: UserId, deviceId: String?
    ) async throws(MatrixError) -> [String] {
        let ownDevice = await session.deviceId.value
        let devices = deviceId.map { [$0] } ?? ["*"]
        var ids: [String] = []
        for name in SecretName.all {
            let requestId = UUID().uuidString
            pending[requestId] = name
            try await sender.send(
                eventType: "m.secret.request",
                content: SecretRequest(
                    name: name,
                    requestingDeviceId: ownDevice,
                    requestId: requestId),
                to: userId,
                devices: devices)
            ids.append(requestId)
        }
        return ids
    }

    /// Ask a peer device for the `m.megolm_backup.v1` private key.
    /// Pass a device ID to target one device, nil for all (`"*"`).
    /// Returns the request ID (the answer arrives as `m.secret.send`
    /// and fires `SecretShareEvent.backupKeyReceived`).
    ///
    /// Like `requestSecrets`, the request goes out UNENCRYPTED per the
    /// spec; only the answer is encrypted. Only peers holding the key
    /// (e.g. after their own 4S unlock) can answer — an unanswered
    /// request stays pending until cancelled.
    @discardableResult
    public func requestBackupKey(
        from userId: UserId, deviceId: String?
    ) async throws(MatrixError) -> String {
        let ownDevice = await session.deviceId.value
        let devices = deviceId.map { [$0] } ?? ["*"]
        let requestId = UUID().uuidString
        pending[requestId] = SecretName.backup
        try await sender.send(
            eventType: "m.secret.request",
            content: SecretRequest(
                name: SecretName.backup,
                requestingDeviceId: ownDevice,
                requestId: requestId),
            to: userId,
            devices: devices)
        return requestId
    }

    /// Hold the backup private key and persist it, so targeted backup
    /// fetches and answers to peers' `m.megolm_backup.v1` requests keep
    /// working across launches. Call after 4S recovery or a peer's
    /// share. Nil clears the cache and the persisted copy. A failed
    /// write leaves the key held for this launch only.
    public func cacheBackupKey(_ key: Data?) async {
        heldBackupKey = key
        guard let backupKeyStore, let userId = await sessionUserId() else { return }
        if let key {
            try? await backupKeyStore.save(key, userId: userId)
        } else {
            try? await backupKeyStore.delete(userId: userId)
        }
    }

    /// The backup private key from 4S recovery or a peer share
    /// (this launch, or restored by `autoload()`). The client uses it
    /// for targeted backup fetches of undecryptable sessions.
    public func backupKey() -> Data? {
        heldBackupKey
    }

    // MARK: - Receive

    /// Feed one to-device event in. Commits answers, imports + persists
    /// once all three halves are banked. Also answers `m.secret.request`
    /// when we hold the secret (encrypted, via `OlmConnector`) — those
    /// report `.ignored` since no request of ours completed. Never
    /// throws — undecodable or foreign events report `.ignored` /
    /// `.unknownRequest`.
    public func receive(_ event: BasicEvent) async -> SecretReceiveOutcome {
        if event.type == "m.secret.request" {
            await answerRequest(event)
            return .ignored
        }
        guard event.type == "m.secret.send" else { return .ignored }
        guard
            let data = try? JSONEncoder().encode(
                AnyCodableDictionary(event.content)),
            let send = try? JSONDecoder().decode(SecretSend.self, from: data),
            let name = pending.removeValue(forKey: send.requestId)
        else { return .unknownRequest }
        received[name] = send.secret
        if name == SecretName.backup {
            // Backup answers carry the base64 private key, not a
            // cross-signing half: surface it and stop. Like the halves
            // path, the value is banked verbatim first.
            if let key = Primitives.base64UnpaddedDecode(send.secret) {
                await cacheBackupKey(key)
                notify(.backupKeyReceived(key))
            }
            return .stored(name: name)
        }
        guard
            let master = received[SecretName.master],
            let selfSigning = received[SecretName.selfSigning],
            let userSigning = received[SecretName.userSigning]
        else { return .stored(name: name) }
        do {
            try await crossSigning.importPrivateKeys(
                master: master, selfSigning: selfSigning,
                userSigning: userSigning)
        } catch {
            return .stored(name: name)
        }
        if let store, let userId = await sessionUserId() {
            try? await store.save(
                CrossSigningBackup(
                    masterPrivateKey: master,
                    selfSigningPrivateKey: selfSigning,
                    userSigningPrivateKey: userSigning),
                userId: userId)
        }
        received = [:]
        notify(.secretsCompleted)
        return .completed
    }

    // MARK: - Responder

    /// Answer a peer's `m.secret.request` with the held secret,
    /// Olm-encrypted to the requesting device. Cross-signing halves
    /// come from the held keys; `m.megolm_backup.v1` comes from the
    /// cached key (see `cacheBackupKey`). Silent no-op without a
    /// configured `OlmConnector`, for requests from other users, for
    /// unknown secret names, when we don't hold the secret, or for
    /// `request_cancellation` events.
    /// Requests stay plaintext per spec; only the secret-bearing
    /// answers are encrypted.
    private func answerRequest(_ event: BasicEvent) async {
        guard
            let olm, await olm.isConfigured,
            let from = event.sender,
            from == (await sessionUserId()),
            let data = try? JSONEncoder().encode(
                AnyCodableDictionary(event.content)),
            let request = try? JSONDecoder().decode(
                SecretRequest.self, from: data),
            request.action != "request_cancellation"
        else { return }
        let secret: String
        if request.name == SecretName.backup {
            guard let key = heldBackupKey else { return }
            secret = Primitives.base64UnpaddedEncode(key)
        } else {
            guard
                let keys = await crossSigning.exportPrivateKeys(),
                let half = Self.half(named: request.name, in: keys)
            else { return }
            secret = half
        }
        try? await olm.sendEncrypted(
            eventType: "m.secret.send",
            content: [
                "request_id": .string(request.requestId),
                "secret": .string(secret),
            ],
            to: from,
            devices: [DeviceId(request.requestingDeviceId)])
    }

    private static func half(
        named name: String,
        in keys: (master: String, selfSigning: String, userSigning: String)
    ) -> String? {
        switch name {
        case SecretName.master: keys.master
        case SecretName.selfSigning: keys.selfSigning
        case SecretName.userSigning: keys.userSigning
        default: nil
        }
    }

    // MARK: - Autoload

    /// Import persisted halves into `CrossSigning` when memory is empty,
    /// and restore the persisted backup key. Returns whether
    /// cross-signing keys are now held. Call on login.
    @discardableResult
    public func autoload() async -> Bool {
        if heldBackupKey == nil, let backupKeyStore,
            let userId = await sessionUserId()
        {
            heldBackupKey = await backupKeyStore.load(userId: userId)
        }
        if await crossSigning.hasKeys { return true }
        guard
            let store,
            let userId = await sessionUserId(),
            let backup = await store.load(userId: userId)
        else { return false }
        do {
            try await crossSigning.importPrivateKeys(
                master: backup.masterPrivateKey,
                selfSigning: backup.selfSigningPrivateKey,
                userSigning: backup.userSigningPrivateKey)
            return true
        } catch {
            return false
        }
    }

    /// Persist currently held keys (e.g. after manual import).
    public func persist() async -> Bool {
        guard
            let store,
            let userId = await sessionUserId(),
            let keys = await crossSigning.exportPrivateKeys()
        else { return false }
        do {
            try await store.save(
                CrossSigningBackup(
                    masterPrivateKey: keys.master,
                    selfSigningPrivateKey: keys.selfSigning,
                    userSigningPrivateKey: keys.userSigning),
                userId: userId)
            return true
        } catch {
            return false
        }
    }

    /// The session user, or nil while logged out / placeholder.
    private func sessionUserId() async -> UserId? {
        let userId = await session.userId
        return userId.value.isEmpty ? nil : userId
    }
}
