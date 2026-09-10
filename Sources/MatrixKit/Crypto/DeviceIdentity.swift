import Crypto
import Foundation
import MatrixKitCrypto

/// Our device's long-term E2EE identity: Ed25519 signing key + Curve25519
/// identity key, persisted per user+device and published via
/// `POST /keys/upload`.
///
/// Without this, the device is a phantom to the server: `/keys/query`
/// shows nothing for it and other clients won't surface our verification
/// requests. Key material is pure (`DeviceIdentityKeys`, fully testable);
/// the `DeviceIdentity` actor adds upload; `DeviceIdentityStore` persists
/// the private halves in the app-provided `KeyStore`.
public struct DeviceIdentityKeys: Sendable {
    public var signing: SigningKey
    public var curve25519Private: Data

    public init(signing: SigningKey, curve25519Private: Data) {
        self.signing = signing
        self.curve25519Private = curve25519Private
    }

    /// Generate fresh random identity material.
    public static func generate() -> DeviceIdentityKeys {
        DeviceIdentityKeys(
            signing: .generate(),
            curve25519Private: Data(
                Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        )
    }

    /// Restore from a persisted backup.
    public static func restore(_ backup: DeviceIdentityBackup) throws(MatrixError) -> DeviceIdentityKeys {
        guard
            let signingBytes = Primitives.base64UnpaddedDecode(
                backup.ed25519PrivateKey),
            let curveBytes = Primitives.base64UnpaddedDecode(
                backup.curve25519PrivateKey)
        else {
            throw .encodingError("Malformed device identity backup")
        }
        // Validate the Curve25519 half now so corrupt backups fail fast.
        guard (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: curveBytes)) != nil else {
            throw .encodingError("Invalid Curve25519 private key in backup")
        }
        let signing: SigningKey
        do {
            signing = try SigningKey.restore(privateKeyBytes: signingBytes)
        } catch {
            throw .encodingError("Invalid Ed25519 private key in backup")
        }
        return DeviceIdentityKeys(
            signing: signing, curve25519Private: curveBytes)
    }

    /// Export private halves for backup. Handle as secrets.
    public func backup() -> DeviceIdentityBackup {
        DeviceIdentityBackup(
            ed25519PrivateKey: signing.privateKeyBase64,
            curve25519PrivateKey: Primitives.base64UnpaddedEncode(
                curve25519Private)
        )
    }

    /// Curve25519 identity public key (32 bytes).
    public func curve25519Public() throws(MatrixError) -> Data {
        do {
            let key = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: curve25519Private)
            return Data(key.publicKey.rawRepresentation)
        } catch {
            throw .encodingError(
                "Invalid Curve25519 private key: \(error.localizedDescription)")
        }
    }

    /// Build our self-signed `DeviceKeys` for `POST /keys/upload`.
    public func deviceKeys(userId: String, deviceId: String) throws(MatrixError) -> DeviceKeys {
        let edKeyId = "ed25519:\(deviceId)"
        let curveKeyId = "curve25519:\(deviceId)"
        let curvePublic = Primitives.base64UnpaddedEncode(
            try curve25519Public())
        let payload: [String: Any] = [
            "user_id": userId,
            "device_id": deviceId,
            "algorithms": [
                "m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2",
            ],
            "keys": [
                curveKeyId: curvePublic,
                edKeyId: signing.publicKeyBase64,
            ],
        ]
        let canonical = try CryptoPrimitives.canonicalJSON(payload)
        let signature: Data
        do {
            signature = try signing.sign(canonical)
        } catch {
            throw .encodingError(
                "Failed to sign device keys: \(error.localizedDescription)")
        }
        let signatureB64 = Primitives.base64UnpaddedEncode(signature)
        return DeviceKeys(
            userId: userId, deviceId: deviceId,
            keys: [
                curveKeyId: curvePublic,
                edKeyId: signing.publicKeyBase64,
            ],
            signatures: [userId: [edKeyId: signatureB64]]
        )
    }
}

/// Persisted device identity: unpadded-base64 private halves. Secret.
public struct DeviceIdentityBackup: Hashable, Sendable, Codable {
    public var ed25519PrivateKey: String
    public var curve25519PrivateKey: String

    public init(ed25519PrivateKey: String, curve25519PrivateKey: String) {
        self.ed25519PrivateKey = ed25519PrivateKey
        self.curve25519PrivateKey = curve25519PrivateKey
    }
}

/// Device-identity persistence over the app-provided `KeyStore`: one
/// entry per user holding every device identity backup (`device ID`
/// to backup). This keeps the per-user wipe on logout to a single
/// delete with no directory scan.
///
/// The service name is intentionally relative: apps namespace their
/// items (e.g. with an app-ID service prefix and access group) in
/// their own `KeyStore`, so two MatrixKit apps can never step on each
/// other's keys. With no injected store, `KeychainSecretStore` backs
/// reads and writes.
public struct DeviceIdentityStore: Sendable {
    /// Relative service for the per-user identity entry. Apps isolate
    /// their items via their own `KeyStore` naming.
    public static let service = "device_identity"

    private let keystore: any KeyStore

    public init(keystore: (any KeyStore)? = nil) {
        self.keystore = keystore ?? KeychainBackedKeyStore()
    }

    private func key(for userId: UserId) -> KeyStoreKey {
        KeyStoreKey(service: Self.service, account: userId.value)
    }

    /// Write one device's backup into the user's entry
    /// (insert or replace; other devices' entries are preserved).
    public func save(
        _ backup: DeviceIdentityBackup, userId: UserId, deviceId: DeviceId
    ) async throws {
        var all = await loadAll(userId: userId)
        all[deviceId.value] = backup
        let data = try JSONEncoder().encode(all)
        try await keystore.save(data, for: key(for: userId))
    }

    /// Read one device's backup, or nil when absent or unreadable.
    public func load(userId: UserId, deviceId: DeviceId) async -> DeviceIdentityBackup? {
        await loadAll(userId: userId)[deviceId.value]
    }

    /// Delete every identity backup for a user (e.g. on logout) with a
    /// single entry delete. Absent entries are not an error.
    public func deleteAll(userId: UserId) async throws {
        try await keystore.delete(key(for: userId))
    }

    // MARK: - Internals

    private func loadAll(userId: UserId) async -> [String: DeviceIdentityBackup] {
        guard let data = try? await keystore.load(key(for: userId)),
            let all = try? JSONDecoder().decode(
                [String: DeviceIdentityBackup].self, from: data)
        else { return [:] }
        return all
    }
}

/// Device identity lifecycle: load-or-generate key material and publish it.
public actor DeviceIdentity {
    private let keys: KeyClient
    private let session: Session
    private var material: DeviceIdentityKeys?

    public init(transport: MatrixTransport, session: Session) {
        self.keys = KeyClient(transport: transport, session: session)
        self.session = session
    }

    /// Whether key material is held in memory.
    public var hasKeys: Bool { material != nil }

    /// Generate fresh identity material in memory.
    public func generate() {
        material = .generate()
    }

    /// Restore identity material from a persisted backup.
    public func restore(_ backup: DeviceIdentityBackup) throws(MatrixError) {
        material = try .restore(backup)
    }

    /// Export the current material for backup. Nil when empty.
    public func backup() -> DeviceIdentityBackup? {
        material?.backup()
    }

    /// Our self-signed device keys for the current session.
    public func deviceKeys() async throws(MatrixError) -> DeviceKeys {
        guard let material else { throw .notAuthenticated }
        return try material.deviceKeys(
            userId: await session.userId.value,
            deviceId: await session.deviceId.value)
    }

    /// Publish our device keys (`POST /keys/upload`, device keys only —
    /// no one-time keys yet). Idempotent: re-uploading the same keys is
    /// a no-op server-side, so this is safe to call on every login.
    @discardableResult
    public func upload() async throws(MatrixError) -> UploadDeviceKeysResponse {
        try await keys.uploadDeviceKeys(
            UploadDeviceKeysRequest(deviceKeys: try await deviceKeys()))
    }
}
