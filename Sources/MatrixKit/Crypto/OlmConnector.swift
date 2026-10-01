import Crypto
import Foundation
import MatrixKitCrypto
import os

/// Minimal key-service surface Olm needs (query / claim / upload), so
/// `OlmConnector` stays testable with a fake. `KeyClient` conforms.
public protocol OlmKeyService: Sendable {
    func queryKeys(
        users: [UserId]
    ) async throws(MatrixError) -> KeyQueryResponse
    func claimKeys(
        user: UserId, device: String
    ) async throws(MatrixError) -> ClaimKeysResponse
    func uploadDeviceKeys(
        _ request: UploadDeviceKeysRequest
    ) async throws(MatrixError) -> UploadDeviceKeysResponse
}

extension KeyClient: OlmKeyService {}

/// Olm-encrypted to-device messaging: one-time-key pool, session cache,
/// `m.room.encrypted` send/receive with spec validation.
///
/// Owns no network types directly — key operations go through
/// `OlmKeyService`, sends through `ToDeviceSender` — so flows are
/// unit-testable with fakes. Configure with device identity before use;
/// state persists via an optional `KeyStore` (set `keystore` before
/// `configure`); without one, state is in-memory only.
public actor OlmConnector {
    public static let olmAlgorithm = "m.olm.v1.curve25519-aes-sha2"
    public static let encryptedType = "m.room.encrypted"
    /// Server-side pool target (matches matrix-rust-sdk's 50).
    public static let keyTarget = 50
    /// Refill when the known server count drops below this.
    public static let keyThreshold = 10
    /// Max sessions kept per peer device (spec: at least 4, LRU).
    static let maxSessions = 4

    private struct SessionEntry {
        var session: OlmSession
        var peerCurve: Data
    }

    private struct PeerRef {
        var userId: UserId
        var deviceId: String
        var ed25519: Data
    }

    /// Stored session entry: peer key + session pickle.
    private struct StoredSession: Codable {
        var peerCurve: Data
        var pickle: Data
    }

    /// Stored OTK pool: key ID → private raw bytes, plus fallback.
    private struct StoredOTKs: Codable {
        var keys: [String: Data]
        var fallbackId: String?
        var fallbackKey: Data?
    }

    private let keys: any OlmKeyService
    private let sender: any ToDeviceSender

    /// Optional persistent store for sessions + one-time keys. Pass at
    /// construction (before `configure`) to survive restarts; without
    /// one, state is in-memory only (sessions re-establish after restart).
    /// Entries are scoped per (user, device): Olm sessions bind a device
    /// identity, so two local devices of one user must never share a
    /// pool — a restored foreign session encrypts type-1 first-contact
    /// the peer cannot decrypt.
    private var keystore: (any KeyStore)?

    private var material: DeviceIdentityKeys?
    private var identity: Curve25519.KeyAgreement.PrivateKey?
    private var userId: UserId?
    private var deviceId: DeviceId?
    private var oneTimeKeys: [(id: String, key: Curve25519.KeyAgreement.PrivateKey)] = []
    private var fallbackKey: (id: String, key: Curve25519.KeyAgreement.PrivateKey)?
    /// Peer Curve25519 (unpadded base64) → sessions, most-recent last.
    private var sessions: [String: [SessionEntry]] = [:]
    /// Peer Curve25519 (unpadded base64) → verified device binding.
    private var peers: [String: PeerRef] = [:]

    /// Query results cached to avoid a `/keys/query` per send:
    /// resolved peers by `"user\0device"`, device lists by user.
    /// Entries are evicted on send failure (stale device data) and
    /// re-fetched once before surfacing the error.
    private var resolvedPeers: [String: ResolvedPeer] = [:]
    private var listedDevices: [String: [String]] = [:]

    /// Debounced crypto-state persistence (see `PersistCoalescer`),
    /// created on first mutation so `init` never captures `self`.
    private var persister: PersistCoalescer?

    public init(
        keys: any OlmKeyService, sender: any ToDeviceSender,
        keystore: (any KeyStore)? = nil
    ) {
        self.keys = keys
        self.sender = sender
        self.keystore = keystore
    }

    /// Record a crypto-state mutation for debounced persistence.
    private func markPersistDirty() async {
        if persister == nil {
            persister = PersistCoalescer { [weak self] in
                await self?.persistCryptoState()
            }
        }
        await persister?.markDirty()
    }

    /// Write any coalesced crypto state immediately. Call on paths
    /// where the debounce loss window is unacceptable (e.g. app
    /// termination) and in tests that re-read the store right away.
    public func flushCryptoState() async {
        await persister?.flush()
    }

    // MARK: - Configuration

    /// Load device identity material. Required before any other call.
    /// When `keystore` is set, restores persisted sessions + OTK pool.
    public func configure(
        identity: DeviceIdentityKeys, userId: UserId, deviceId: DeviceId
    ) async throws(MatrixError) {
        do {
            self.identity = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: identity.curve25519Private)
        } catch {
            throw .encodingError(
                "Invalid Curve25519 identity key: \(error.localizedDescription)")
        }
        self.material = identity
        self.userId = userId
        self.deviceId = deviceId
        await migrateLegacyCryptoState()
        await restoreCryptoState()
    }

    public var isConfigured: Bool { identity != nil }

    /// Our own device ID (for `"*"` recipient expansion elsewhere).
    /// Nil before `configure`.
    public var ownDeviceId: String? { deviceId?.value }

    private func requireConfigured() throws(MatrixError) -> (
        identity: Curve25519.KeyAgreement.PrivateKey,
        material: DeviceIdentityKeys, userId: UserId, deviceId: DeviceId
    ) {
        guard
            let identity, let material, let userId, let deviceId
        else {
            throw .notAuthenticated
        }
        return (identity, material, userId, deviceId)
    }

    private static let storeService = "MatrixKit.Olm"

    /// Per-device persistence accounts. Sessions and one-time keys
    /// belong to one device identity: scoping by user alone lets a
    /// second local device restore (and send on) the first device's
    /// established sessions, producing type-1 first-contact messages
    /// the peer has no session for and silently drops.
    private static func sessionsAccount(user: UserId, device: DeviceId) -> String {
        "sessions-" + user.value + "-" + device.value
    }

    private static func otksAccount(user: UserId, device: DeviceId) -> String {
        "otks-" + user.value + "-" + device.value
    }

    /// Save sessions + OTK pool to the keystore. No-op when unset.
    /// The coalesced write body — call sites record mutations with
    /// `markPersistDirty()` instead of calling this directly.
    private func persistCryptoState() async {
        guard let keystore, let userId, let deviceId else { return }
        let sessionsKey = KeyStoreKey(
            service: Self.storeService,
            account: Self.sessionsAccount(user: userId, device: deviceId))
        let otksKey = KeyStoreKey(
            service: Self.storeService,
            account: Self.otksAccount(user: userId, device: deviceId))
        var stored: [StoredSession] = []
        for (_, list) in sessions {
            for entry in list {
                guard let pickle = try? entry.session.pickle() else { continue }
                stored.append(StoredSession(
                    peerCurve: entry.peerCurve, pickle: pickle))
            }
        }
        let otks = StoredOTKs(
            keys: Dictionary(
                uniqueKeysWithValues: oneTimeKeys.map {
                    ($0.id, Data($0.key.rawRepresentation))
                }),
            fallbackId: fallbackKey?.id,
            fallbackKey: fallbackKey.map { Data($0.key.rawRepresentation) })
        guard
            let sessionsData = try? JSONEncoder().encode(stored),
            let otksData = try? JSONEncoder().encode(otks)
        else { return }
        do {
            try await keystore.save(sessionsData, for: sessionsKey)
            try await keystore.save(otksData, for: otksKey)
        } catch {
            MatrixKitLog.crypto.warning("Olm state persist failed error=\(error, privacy: .public)")
        }
    }

    /// Delete persisted sessions + OTK pool (e.g. on logout). Absent
    /// entries are not an error; failures are logged, not thrown.
    public func deletePersistedState() async {
        await persister?.cancel()
        guard let keystore, let userId, let deviceId else { return }
        do {
            try await keystore.delete(KeyStoreKey(
                service: Self.storeService,
                account: Self.sessionsAccount(
                    user: userId, device: deviceId)))
            try await keystore.delete(KeyStoreKey(
                service: Self.storeService,
                account: Self.otksAccount(user: userId, device: deviceId)))
        } catch {
            MatrixKitLog.crypto.warning("Olm state delete failed error=\(error, privacy: .public)")
        }
    }

    /// Migrate the pre-per-device user-scoped entries. The one-time-key
    /// pool is *adopted* when this device has none: regenerating would
    /// orphan already-uploaded server-side keys (uploads are additive),
    /// leaving senders claiming keys this device cannot match. Sessions
    /// always re-establish via fresh claims instead — never adopt
    /// another device's ratchet state. Best-effort.
    private func migrateLegacyCryptoState() async {
        guard let keystore, let userId, let deviceId else { return }
        let legacySessions = KeyStoreKey(
            service: Self.storeService,
            account: "sessions-" + userId.value)
        let legacyOtks = KeyStoreKey(
            service: Self.storeService, account: "otks-" + userId.value)
        let poolKey = KeyStoreKey(
            service: Self.storeService,
            account: Self.otksAccount(user: userId, device: deviceId))
        let hasPool =
            ((try? await keystore.load(poolKey)) ?? nil) != nil
        if !hasPool, let legacy = try? await keystore.load(legacyOtks) {
            try? await keystore.save(legacy, for: poolKey)
        }
        try? await keystore.delete(legacySessions)
        try? await keystore.delete(legacyOtks)
    }

    /// Reload sessions + OTK pool persisted by `persistCryptoState`.
    /// No-op when no keystore set; corrupt entries are skipped so fresh
    /// keys/sessions replace them.
    private func restoreCryptoState() async {
        guard let keystore, let userId, let deviceId else { return }
        if let data = try? await keystore.load(KeyStoreKey(
            service: Self.storeService,
            account: Self.sessionsAccount(user: userId, device: deviceId))),
            let stored = try? JSONDecoder().decode(
                [StoredSession].self, from: data)
        {
            for entry in stored {
                guard let session = try? OlmSession.restore(
                    from: entry.pickle)
                else { continue }
                sessions[Primitives.base64UnpaddedEncode(entry.peerCurve),
                    default: []].append(SessionEntry(
                        session: session, peerCurve: entry.peerCurve))
            }
        }
        if let data = try? await keystore.load(KeyStoreKey(
            service: Self.storeService,
            account: Self.otksAccount(user: userId, device: deviceId))),
            let stored = try? JSONDecoder().decode(
                StoredOTKs.self, from: data)
        {
            var restored: [(id: String, key: Curve25519.KeyAgreement.PrivateKey)] = []
            for (id, raw) in stored.keys {
                if let key = try? Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: raw)
                {
                    restored.append((id, key))
                }
            }
            oneTimeKeys = restored
            if let fbId = stored.fallbackId, let fbRaw = stored.fallbackKey,
                let fbKey = try? Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: fbRaw)
            {
                fallbackKey = (fbId, fbKey)
            }
        }
    }

    private var ourCurveB64: String {
        guard let identity else { return "" }
        return Primitives.base64UnpaddedEncode(
            Data(identity.publicKey.rawRepresentation))
    }

    private var ourEdB64: String {
        material?.signing.publicKeyBase64 ?? ""
    }

    // MARK: - One-time-key pool

    private static func newKeyId() -> String {
        Primitives.base64UnpaddedEncode(Data((0..<6).map { _ in UInt8.random(in: 0...255) }))
    }

    /// Upload a full pool (50 signed OTKs + fallback) when empty.
    public func ensureKeys() async throws(MatrixError) {
        let _ = try requireConfigured()
        if oneTimeKeys.isEmpty {
            try await maintainKeys(serverCount: 0)
        }
    }

    /// Refill the pool to the target when the known server count is low.
    public func maintainKeys(serverCount: Int?) async throws(MatrixError) {
        let (identity, material, userId, deviceId) = try requireConfigured()
        _ = identity
        let known = min(oneTimeKeys.count, serverCount ?? oneTimeKeys.count)
        guard known < Self.keyThreshold else { return }
        while oneTimeKeys.count < Self.keyTarget {
            oneTimeKeys.append(
                (Self.newKeyId(), Curve25519.KeyAgreement.PrivateKey()))
        }
        if fallbackKey == nil {
            fallbackKey = (
                Self.newKeyId(), Curve25519.KeyAgreement.PrivateKey())
        }
        var otks: [String: AnyCodable] = [:]
        for (id, key) in oneTimeKeys {
            otks["signed_curve25519:\(id)"] = .object(
                try signedKeyObject(
                    key: key, material: material,
                    userId: userId, deviceId: deviceId))
        }
        var fallback: [String: AnyCodable] = [:]
        if let fb = fallbackKey {
            fallback["signed_curve25519:\(fb.id)"] = .object(
                try signedKeyObject(
                    key: fb.key, material: material,
                    userId: userId, deviceId: deviceId))
        }
        _ = try await keys.uploadDeviceKeys(
            UploadDeviceKeysRequest(
                deviceKeys: try material.deviceKeys(
                    userId: userId.value, deviceId: deviceId.value),
                oneTimeKeys: otks, fallbackKeys: fallback))
        await markPersistDirty()
    }

    /// `signed_curve25519` upload object: `{key, signatures}` over
    /// canonical `{"key": …}`.
    private func signedKeyObject(
        key: Curve25519.KeyAgreement.PrivateKey,
        material: DeviceIdentityKeys, userId: UserId, deviceId: DeviceId
    ) throws(MatrixError) -> [String: AnyCodable] {
        let pubB64 = Primitives.base64UnpaddedEncode(
            Data(key.publicKey.rawRepresentation))
        let canonical = try CryptoPrimitives.canonicalJSON(["key": pubB64])
        let signature: Data
        do {
            signature = try material.signing.sign(canonical)
        } catch {
            throw .encodingError(
                "Failed to sign one-time key: \(error.localizedDescription)")
        }
        return [
            "key": .string(pubB64),
            "signatures": .object([
                userId.value: .object([
                    "ed25519:\(deviceId.value)": .string(
                        Primitives.base64UnpaddedEncode(signature))
                ])
            ]),
        ]
    }

    // MARK: - Send

    /// Encrypt `content` as `eventType` for each of the user's devices
    /// and send as `m.room.encrypted` (claiming a one-time key on first
    /// contact). Devices are `DeviceId`s, e.g. `["*"]` is NOT expanded —
    /// pass explicit IDs from a key query.
    ///
    /// Per-device failures for missing keys (`.invalidIdentifier`: a
    /// stale or signed-out device with no published keys or one-time
    /// key) skip that device instead of aborting the fan-out; other
    /// errors still fail the send. Throws `.noReachableDevices` when
    /// every target was skipped.
    public func sendEncrypted(
        eventType: String,
        content: [String: AnyCodable],
        to user: UserId,
        devices: [DeviceId]
    ) async throws(MatrixError) {
        let (_, _, ourUser, _) = try requireConfigured()
        _ = ourUser
        // Claims and session setups run concurrently: a request fan-out
        // to N devices costs one round-trip, not N sequential ones.
        let results = await withTaskGroup(
            of: (String, Result<[String: AnyCodable], MatrixError>).self
        ) { group in
            for device in devices {
                group.addTask {
                    do {
                        let content = try await self.encryptedContent(
                            eventType: eventType, content: content,
                            user: user, device: device)
                        return (device.value, .success(content))
                    } catch let error as MatrixError {
                        return (device.value, .failure(error))
                    } catch {
                        // Only task-group machinery (e.g.
                        // cancellation) throws outside
                        // `MatrixError`; surface it as fatal.
                        return (
                            device.value,
                            .failure(.networkError(
                                "Encrypted send fan-out failed: \(error.localizedDescription)")))
                    }
                }
            }
            var out: [(String, Result<[String: AnyCodable], MatrixError>)] = []
            for await item in group { out.append(item) }
            return out
        }
        var payloads: [(String, [String: AnyCodable])] = []
        var skipped: [String] = []
        for (deviceId, result) in results {
            switch result {
            case .success(let content):
                payloads.append((deviceId, content))
            case .failure(.invalidIdentifier(let message)):
                MatrixKitLog.crypto.warning(
                    "Olm send skipped device with no keys user=\(user.value, privacy: .private(mask: .hash)) device=\(deviceId, privacy: .private(mask: .hash)) error=\(message, privacy: .public)"
                )
                skipped.append(deviceId)
            case .failure(let error):
                throw error
            }
        }
        guard !payloads.isEmpty || devices.isEmpty else {
            throw .noReachableDevices(
                "no published keys or one-time key for \(skipped.joined(separator: ", "))")
        }
        var messages: [String: [String: [String: AnyCodable]]] = [:]
        for (deviceId, content) in payloads {
            messages[user.value, default: [:]][deviceId] = content
        }
        await markPersistDirty()
        try await sender.sendRaw(
            eventType: Self.encryptedType, messages: messages)
    }

    private func encryptedContent(
        eventType: String,
        content: [String: AnyCodable],
        user: UserId,
        device: DeviceId
    ) async throws(MatrixError) -> [String: AnyCodable] {
        do {
            return try await encryptedContentOnce(
                eventType: eventType, content: content,
                user: user, device: device)
        } catch MatrixError.invalidIdentifier {
            // Stale cache (device deleted/recreated or keys rotated):
            // evict this user's entries and retry once against a
            // fresh query before surfacing the error.
            evictUser(user)
            return try await encryptedContentOnce(
                eventType: eventType, content: content,
                user: user, device: device)
        }
    }

    private func encryptedContentOnce(
        eventType: String,
        content: [String: AnyCodable],
        user: UserId,
        device: DeviceId
    ) async throws(MatrixError) -> [String: AnyCodable] {
        let peer = try await resolvePeer(user: user, device: device)
        let plaintext = try payloadData(
            eventType: eventType, content: content, peer: peer)
        let (type, body) = try await encryptToPeer(
            peer: peer, plaintext: plaintext)
        return [
            "algorithm": .string(Self.olmAlgorithm),
            "sender_key": .string(ourCurveB64),
            "ciphertext": .object([
                peer.curveB64: .object([
                    "type": .int(type.rawValue),
                    "body": .string(
                        Primitives.base64UnpaddedEncode(body)),
                ])
            ]),
        ]
    }

    private func evictUser(_ user: UserId) {
        let prefix = user.value + "\0"
        resolvedPeers = resolvedPeers.filter {
            !$0.key.hasPrefix(prefix)
        }
        listedDevices[user.value] = nil
    }

    private struct ResolvedPeer {
        var userId: UserId
        var deviceId: String
        var curve: Data
        var curveB64: String
        var ed25519: Data
    }

    /// Peer device keys from `/keys/query`, cached by Curve25519.
    /// Send-path lookups hit `resolvedPeers` first (keyed
    /// `"user\0device"`); a miss queries and populates the cache.
    private func resolvePeer(
        user: UserId, device: DeviceId
    ) async throws(MatrixError) -> ResolvedPeer {
        let cacheKey = user.value + "\0" + device.value
        if let cached = resolvedPeers[cacheKey] {
            return cached
        }
        let response = try await keys.queryKeys(users: [user])
        guard
            let entry = response.deviceKeys[user.value]?[device.value],
            let curveB64 = entry.keys["curve25519:\(device.value)"],
            let edB64 = entry.keys["ed25519:\(device.value)"],
            let curve = Primitives.base64UnpaddedDecode(curveB64),
            let ed = Primitives.base64UnpaddedDecode(edB64)
        else {
            throw .invalidIdentifier(
                "No device keys for \(user.value):\(device.value)")
        }
        peers[curveB64] = PeerRef(
            userId: user, deviceId: device.value, ed25519: ed)
        let peer = ResolvedPeer(
            userId: user, deviceId: device.value,
            curve: curve, curveB64: curveB64, ed25519: ed)
        resolvedPeers[cacheKey] = peer
        return peer
    }

    /// Device IDs with published keys for a user, cached (see
    /// `resolvePeer`). Backs `"*"` expansion without a query per send.
    /// Part of the `RoomKeySharer` seam consumed by `RoomCrypto`.
    public func deviceIds(for user: UserId) async throws(MatrixError) -> [String] {
        if let cached = listedDevices[user.value] {
            return cached
        }
        let query = try await keys.queryKeys(users: [user])
        let ids = Array((query.deviceKeys[user.value] ?? [:]).keys)
        listedDevices[user.value] = ids
        return ids
    }

    /// Unpadded-base64 Ed25519 fingerprint of the local device, sent as
    /// `sender_key` on `m.room.encrypted` room events. Part of the
    /// `RoomKeySharer` seam consumed by `RoomCrypto`.
    public func identityKey() async throws(MatrixError) -> String {
        try requireConfigured().material.signing.publicKeyBase64
    }

    /// Drop cached device data for a user: the next send re-queries
    /// `/keys/query`. Call on `device_lists.changed` entries (stale
    /// cache) and `device_lists.left` entries (dropped keys).
    public func invalidateDevices(for user: UserId) {
        evictUser(user)
    }

    /// Drop cached Olm sessions for a peer device (all of the user's
    /// devices when `device` is nil), so the next send re-claims fresh
    /// instead of reusing a half the peer may have torn down (cancel,
    /// timeout, restart). Used at verification flow start and after
    /// undecryptable peer traffic. No-op when nothing is cached.
    ///
    /// With `keepingMostRecent`, the most-recently-used session
    /// survives: a responder answering a request it just decrypted
    /// keeps that handshake's live session while purging older,
    /// possibly forked halves.
    public func dropSessions(
        user: UserId, device: String? = nil, keepingMostRecent: Bool = false
    ) async {
        let devices: [String]
        if let device {
            devices = [device]
        } else {
            devices = (try? await deviceIds(for: user)) ?? []
        }
        var dropped = false
        for device in devices {
            guard let curve = await peerCurve(user: user, device: device),
                var list = sessions[curve], !list.isEmpty
            else { continue }
            if keepingMostRecent {
                list.removeFirst(list.count - 1)
            } else {
                list.removeAll()
            }
            if list.isEmpty {
                sessions.removeValue(forKey: curve)
            } else {
                sessions[curve] = list
            }
            dropped = true
        }
        if dropped {
            await markPersistDirty()
        }
    }

    /// This peer's session-cache key, resolving (and caching) device
    /// keys on a miss. Post-restart the peer map is empty while
    /// restored sessions may exist, so the query fallback is what lets
    /// a stale restored half still be found and dropped.
    private func peerCurve(user: UserId, device: String) async -> String? {
        let cacheKey = user.value + "\0" + device
        if let peer = resolvedPeers[cacheKey] {
            return peer.curveB64
        }
        return try? await resolvePeer(user: user, device: DeviceId(device)).curveB64
    }

    /// Encrypt with a cached session, else claim a key and start one.
    private func encryptToPeer(
        peer: ResolvedPeer, plaintext: Data
    ) async throws(MatrixError) -> (OlmWireType, Data) {
        let (identity, _, _, _) = try requireConfigured()
        if var list = sessions[peer.curveB64], !list.isEmpty {
            for i in list.indices {
                var entry = list[i]
                do {
                    let result = try entry.session.encrypt(plaintext)
                    list[i] = entry
                    // Most-recent last (spec session selection).
                    list.append(list.remove(at: i))
                    sessions[peer.curveB64] = list
                    return (result.0, result.1)
                } catch {
                    continue
                }
            }
        }
        let claimed = try await claimPeerKey(peer: peer)
        let session: OlmSession
        do {
            session = try OlmSession.createOutbound(
                ourIdentity: identity,
                theirIdentityKey: peer.curve,
                theirOneTimeKey: claimed)
        } catch {
            throw .encodingError(
                "Failed to start Olm session: \(error.localizedDescription)")
        }
        var fresh = session
        do {
            let result = try fresh.encrypt(plaintext)
            storeSession(
                SessionEntry(session: fresh, peerCurve: peer.curve),
                for: peer.curveB64)
            return (result.0, result.1)
        } catch {
            throw .encodingError(
                "Olm encryption failed: \(error.localizedDescription)")
        }
    }

    /// Claim a signed one-time key and verify its device signature.
    private func claimPeerKey(peer: ResolvedPeer) async throws(MatrixError) -> Data {
        let response = try await keys.claimKeys(
            user: peer.userId, device: peer.deviceId)
        guard
            let keyed = response.oneTimeKeys[peer.userId.value]?[peer.deviceId],
            let claimed = keyed.values.first,
            let pub = Primitives.base64UnpaddedDecode(claimed.key)
        else {
            throw .invalidIdentifier(
                "No one-time key for \(peer.userId.value):\(peer.deviceId)")
        }
        let edId = "ed25519:\(peer.deviceId)"
        guard
            let sigB64 = claimed.signatures[peer.userId.value]?[edId],
            let sig = Primitives.base64UnpaddedDecode(sigB64),
            let canonical = try? CryptoPrimitives.canonicalJSON(
                ["key": claimed.key]),
            SigningKey.verify(
                signature: sig, for: canonical, publicKey: peer.ed25519)
        else {
            throw .invalidIdentifier(
                "Invalid one-time-key signature for \(peer.userId.value):\(peer.deviceId)")
        }
        return pub
    }

    private func storeSession(_ entry: SessionEntry, for key: String) {
        var list = sessions[key, default: []]
        list.append(entry)
        while list.count > Self.maxSessions {
            list.removeFirst()
        }
        sessions[key] = list
    }

    /// Spec `OlmPayload`: sender/recipient binding + inner event.
    private func payloadData(
        eventType: String, content: [String: AnyCodable], peer: ResolvedPeer
    ) throws(MatrixError) -> Data {
        let (_, material, userId, deviceId) = try requireConfigured()
        guard
            let contentObject = Self.plainObject(content),
            let deviceObject = Self.plainObject(
                try deviceKeysDict(
                    material: material, userId: userId, deviceId: deviceId))
        else {
            throw .encodingError("Olm payload is not a JSON object")
        }
        let payload: [String: Any] = [
            "sender": userId.value,
            "recipient": peer.userId.value,
            "recipient_keys": [
                "ed25519": Primitives.base64UnpaddedEncode(peer.ed25519)
            ],
            "keys": ["ed25519": ourEdB64],
            "sender_device_keys": deviceObject,
            "type": eventType,
            "content": contentObject,
        ]
        do {
            return try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw .encodingError(
                "Olm payload encoding failed: \(error.localizedDescription)")
        }
    }

    private func deviceKeysDict(
        material: DeviceIdentityKeys, userId: UserId, deviceId: DeviceId
    ) throws(MatrixError) -> [String: AnyCodable] {
        let deviceKeys = try material.deviceKeys(
            userId: userId.value, deviceId: deviceId.value)
        let data: Data
        do {
            data = try JSONEncoder().encode(deviceKeys)
        } catch {
            throw .encodingError(
                "Device keys encoding failed: \(error.localizedDescription)")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = Self.anyCodableMap(object)
        else {
            throw .encodingError("Device keys encoding failed")
        }
        return dict
    }

    // MARK: - Receive

    /// Decrypt `m.room.encrypted` to-device events, returning the
    /// validated inner events. Anything failing parse, decrypt, or spec
    /// validation is silently dropped.
    public func decrypt(_ events: [BasicEvent]) async -> [BasicEvent] {
        var out: [BasicEvent] = []
        for event in events where event.type == Self.encryptedType {
            do {
                out.append(try await decryptOne(event))
            } catch {
                let senderKey =
                    event.content["sender_key"]?.stringValue ?? "?"
                let kind =
                    event.content["ciphertext"]?.objectValue?
                    .values.compactMap { $0.objectValue?["type"]?.intValue }
                    .first.map(String.init) ?? "?"
                MatrixKitLog.crypto.debug(
                    "Olm decrypt failed sender=\(event.sender?.value ?? "?", privacy: .private(mask: .hash)) senderKey=\(String(senderKey.prefix(8)), privacy: .private(mask: .hash)) msgType=\(kind, privacy: .public) error=\(error, privacy: .public)"
                )
                continue
            }
        }
        await markPersistDirty()
        return out
    }

    private func decryptOne(_ event: BasicEvent) async throws(MatrixError) -> BasicEvent {
        let (_, _, ourUser, _) = try requireConfigured()
        _ = ourUser
        guard
            let algorithm = event.content["algorithm"]?.stringValue,
            algorithm == Self.olmAlgorithm,
            let senderKeyB64 = event.content["sender_key"]?.stringValue,
            let senderKey = Primitives.base64UnpaddedDecode(senderKeyB64),
            let cipherValue = event.content["ciphertext"]?.objectValue,
            let entry = cipherValue[ourCurveB64]?.objectValue,
            let typeInt = entry["type"]?.intValue,
            let bodyB64 = entry["body"]?.stringValue,
            let body = Primitives.base64UnpaddedDecode(bodyB64)
        else {
            throw .encodingError("Malformed m.room.encrypted event")
        }
        let plaintext: Data
        let sessionCurve: Data
        if typeInt == OlmWireType.normal.rawValue {
            // `decryptWithSessions` drops desynced halves itself
            // (skipping replays); pre-key messages never drop.
            (plaintext, sessionCurve) = try decryptWithSessions(
                senderKeyB64: senderKeyB64, body: body,
                dropOnFailure: true)
        } else if typeInt == OlmWireType.preKey.rawValue {
            (plaintext, sessionCurve) = try await decryptPreKey(
                senderKeyB64: senderKeyB64, senderKey: senderKey,
                body: body)
        } else {
            throw .encodingError("Unknown Olm message type \(typeInt)")
        }
        return try await emitValidated(
            plaintext: plaintext, event: event,
            senderKeyB64: senderKeyB64, sessionCurve: sessionCurve)
    }

    /// Try cached sessions (most-recent first). Returns plaintext + the
    /// session's peer Curve25519 key.
    private func decryptWithSessions(
        senderKeyB64: String, body: Data, dropOnFailure: Bool
    ) throws(MatrixError) -> (Data, Data) {
        guard var list = sessions[senderKeyB64], !list.isEmpty else {
            throw .invalidIdentifier("No Olm session for sender key")
        }
        // Most-recent last → try from the end.
        var replaySeen = false
        for i in list.indices.reversed() {
            var entry = list[i]
            do {
                let plaintext = try entry.session.decrypt(body)
                list[i] = entry
                let used = list.remove(at: i)
                list.append(used)
                sessions[senderKeyB64] = list
                return (plaintext, used.peerCurve)
            } catch CryptoError.replayDetected {
                // Duplicate delivery (retry, dual consume): the peer
                // half that produced this index is alive, so this is
                // liveness evidence, never desync — keep everything.
                replaySeen = true
                continue
            } catch {
                continue
            }
        }
        // Spec recovery from undecryptable messages: sessions no cached
        // half can read are useless for receiving and suspect for
        // sending, so discard them — the next send re-claims fresh.
        // (`decrypt()` persists the removal afterwards.)
        if dropOnFailure, !replaySeen {
            sessions.removeValue(forKey: senderKeyB64)
        }
        throw .invalidIdentifier("No session decrypted the message")
    }

    /// New inbound session: match the pre-key's OTK against the pool
    /// (fallback last), decrypt, consume the OTK.
    private func decryptPreKey(
        senderKeyB64: String, senderKey: Data, body: Data
    ) async throws(MatrixError) -> (Data, Data) {
        let (identity, _, _, _) = try requireConfigured()
        // Cached sessions get first try (spec: existing session first).
        // Never drop here: a pre-key message is a new handshake no
        // existing session is expected to read.
        if let hit = try? decryptWithSessions(
            senderKeyB64: senderKeyB64, body: body, dropOnFailure: false)
        {
            return hit
        }
        let preKey: OlmPreKeyMessage
        do {
            preKey = try OlmMessageCoder.decodePreKeyBody(message: body)
        } catch {
            throw .encodingError(
                "Malformed Olm pre-key message: \(error.localizedDescription)")
        }
        let matched: Curve25519.KeyAgreement.PrivateKey
        let matchedId: String?
        if let hit = oneTimeKeys.first(where: {
            Data($0.key.publicKey.rawRepresentation) == preKey.oneTimeKey
        }) {
            (matched, matchedId) = (hit.key, hit.id)
        } else if
            let fb = fallbackKey,
            Data(fb.key.publicKey.rawRepresentation) == preKey.oneTimeKey
        {
            (matched, matchedId) = (fb.key, nil)
        } else {
            throw .invalidIdentifier("Pre-key matches no one-time key")
        }
        let session: OlmSession
        do {
            session = try OlmSession.createInbound(
                ourIdentity: identity, oneTimeKeys: [matched],
                message: body)
        } catch {
            throw .encodingError(
                "Failed to start inbound Olm session: \(error.localizedDescription)")
        }
        var inbound = session
        let plaintext: Data
        do {
            plaintext = try inbound.decrypt(body)
        } catch {
            // Do not consume the OTK or persist the session until a
            // message decrypts (spec).
            throw .invalidIdentifier("Pre-key message failed to decrypt")
        }
        if let id = matchedId {
            oneTimeKeys.removeAll { $0.id == id }
        }
        storeSession(
            SessionEntry(session: inbound, peerCurve: preKey.identityKey),
            for: senderKeyB64)
        _ = senderKey
        return (plaintext, preKey.identityKey)
    }

    /// Spec validation (`Validation of incoming decrypted events`) +
    /// sender-device binding (inline `sender_device_keys`, else query).
    /// Failures throw; the caller drops the event.
    private func emitValidated(
        plaintext: Data, event: BasicEvent,
        senderKeyB64: String, sessionCurve: Data
    ) async throws(MatrixError) -> BasicEvent {
        let (_, _, ourUser, _) = try requireConfigured()
        guard
            let payload = try? JSONSerialization.jsonObject(with: plaintext),
            let dict = payload as? [String: Any],
            let sender = dict["sender"] as? String,
            sender == event.sender?.value,
            let recipient = dict["recipient"] as? String,
            recipient == ourUser.value,
            let recipientKeys = dict["recipient_keys"] as? [String: Any],
            recipientKeys["ed25519"] as? String == ourEdB64,
            let keys = dict["keys"] as? [String: Any],
            let keysEd = keys["ed25519"] as? String,
            let innerType = dict["type"] as? String,
            let innerContent = dict["content"],
            let contentDict = Self.anyCodableMap(innerContent)
        else {
            throw .invalidIdentifier("Olm payload failed validation")
        }
        let bound = try await bindSenderDevice(
            sender: sender, senderKeyB64: senderKeyB64,
            sessionCurve: sessionCurve, keysEd: keysEd, dict: dict)
        guard bound else {
            throw .invalidIdentifier("Olm sender device unverified")
        }
        return BasicEvent(
            type: innerType, sender: event.sender, content: contentDict)
    }

    /// Establish that the session Curve25519 key belongs to the claimed
    /// sender: self-contained `sender_device_keys` first, `/keys/query`
    /// fallback. Records the binding in `peers` on success.
    private func bindSenderDevice(
        sender: String, senderKeyB64: String, sessionCurve: Data,
        keysEd: String, dict: [String: Any]
    ) async throws(MatrixError) -> Bool {
        if let known = peers[senderKeyB64] {
            return known.userId.value == sender
                && Primitives.base64UnpaddedEncode(known.ed25519) == keysEd
        }
        if let sdk = dict["sender_device_keys"] as? [String: Any],
           let deviceId = sdk["device_id"] as? String,
           sdk["user_id"] as? String == sender,
           let sdkKeys = sdk["keys"] as? [String: String],
           sdkKeys["ed25519:\(deviceId)"] == keysEd,
           sdkKeys["curve25519:\(deviceId)"] == senderKeyB64,
           sdkKeys["curve25519:\(deviceId)"]
            == Primitives.base64UnpaddedEncode(sessionCurve),
           let sigs = sdk["signatures"] as? [String: [String: String]],
           let sigB64 = sigs[sender]?["ed25519:\(deviceId)"],
           let sig = Primitives.base64UnpaddedDecode(sigB64),
           let ed = Primitives.base64UnpaddedDecode(keysEd),
           var unsigned = Optional(sdk)
        {
            unsigned.removeValue(forKey: "signatures")
            unsigned.removeValue(forKey: "unsigned")
            if let canonical = try? CryptoPrimitives.canonicalJSON(unsigned),
               SigningKey.verify(
                   signature: sig, for: canonical, publicKey: ed)
            {
                peers[senderKeyB64] = PeerRef(
                    userId: UserId(unchecked: sender),
                    deviceId: deviceId, ed25519: ed)
                return true
            }
            return false
        }
        // Fallback: match the session key against a fresh key query.
        let senderId = UserId(unchecked: sender)
        let response = try await keys.queryKeys(users: [senderId])
        for (device, entry) in response.deviceKeys[sender] ?? [:] {
            if entry.keys["curve25519:\(device)"] == senderKeyB64,
               entry.keys["ed25519:\(device)"] == keysEd,
               let ed = Primitives.base64UnpaddedDecode(keysEd)
            {
                peers[senderKeyB64] = PeerRef(
                    userId: senderId, deviceId: device, ed25519: ed)
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func plainObject(
        _ dict: [String: AnyCodable]
    ) -> [String: Any]? {
        guard
            let data = try? JSONEncoder().encode(dict),
            let object = try? JSONSerialization.jsonObject(with: data),
            let plain = object as? [String: Any]
        else {
            return nil
        }
        return plain
    }

    private static func anyCodableMap(_ value: Any) -> [String: AnyCodable]? {
        guard
            let data = try? JSONSerialization.data(withJSONObject: value),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: data)
        else {
            return nil
        }
        return dict
    }
}
