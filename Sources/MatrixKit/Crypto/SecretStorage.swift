import Foundation
import MatrixKitCrypto

/// 4S secret storage (`m.secret_storage.*` account data): unlock the
/// account's storage key with a recovery key or passphrase, then decrypt
/// named secrets (cross-signing private keys, the megolm backup key).
///
/// Wire format follows MSC1946 / `m.secret_storage.v1.aes-hmac-sha2`:
/// the default key ID lives in `m.secret_storage.default_key`
/// (`{"key": "<id>"}`), each `m.secret_storage.key.<id>` holds the
/// algorithm, an optional `m.pbkdf2` passphrase derivation, and the
/// `(iv, mac)` zero-block key check, and each secret event carries
/// `{"encrypted": {"<keyId>": {"iv", "ciphertext", "mac"}}}` with
/// standard-base64 fields. The actual AES/HMAC math lives in
/// `SecretStorageCrypto`; this actor is the account-data I/O around it.
///
/// Recovery-key strings use the `Es...` base58 codec from
/// `BackupCrypto` (shared with key-backup recovery keys).
public actor SecretStorage {
    /// Untyped throws: closures can't preserve typed throws across the
    /// inference boundary; `get(_:)` re-narrows to `MatrixError`.
    private let read: @Sendable (String) async throws -> [String: AnyCodable]?

    public init(accountData: AccountDataClient) {
        let accountData = accountData
        self.read = { try await accountData.get($0) }
    }

    /// Test seam: drive the actor from in-memory account data.
    init(
        reader: @escaping @Sendable (String) async throws -> [String: AnyCodable]?
    ) {
        self.read = reader
    }

    // MARK: - Reads

    /// The default 4S key ID, or nil when the account has no 4S setup.
    public func defaultKeyId() async throws(MatrixError) -> String? {
        guard let dict = try await get("m.secret_storage.default_key")
        else { return nil }
        let record = try decode(DefaultKeyRecord.self, from: dict)
        return record.key
    }

    /// The key description for a 4S key ID, or nil when absent.
    public func keyDescription(
        keyId: String
    ) async throws(MatrixError) -> SecretStorageKeyDescription? {
        guard let dict = try await get("m.secret_storage.key.\(keyId)")
        else { return nil }
        return try decode(SecretStorageKeyDescription.self, from: dict)
    }

    /// Decrypt a named secret under an unlocked storage key. Returns nil
    /// when the secret (or its entry for this key ID) is not stored.
    /// Throws on MAC failure or non-UTF-8 content.
    ///
    /// Secrets are stored as raw UTF-8 (e.g. the base64-encoded private
    /// key for cross-signing secrets, or the base64 backup key) — not
    /// as JSON values — matching what Element and other clients write.
    public func secret(
        _ name: String, keyId: String, storageKey: Data
    ) async throws(MatrixError) -> String? {
        guard
            let data = try await secretData(name, keyId: keyId, storageKey: storageKey)
        else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw MatrixError.decodingError(
                "Secret \(name) is not valid UTF-8 text")
        }
        return value
    }

    // MARK: - Unlock

    /// Unlock a 4S key with an `Es...` recovery key, verifying it against
    /// the stored key check. Uses the default key when `keyId` is nil.
    /// Transport/auth errors propagate; wrong keys and malformed account
    /// data surface as `recoveryFailed`.
    public func unlock(
        recoveryKey: String, keyId: String? = nil
    ) async throws(MatrixError) -> (key: Data, keyId: String) {
        let (description, resolvedId) = try await resolveKey(keyId: keyId)
        let candidate: Data
        do {
            candidate = try BackupCrypto.parseRecoveryKey(recoveryKey)
        } catch {
            throw MatrixError.recoveryFailed(
                "That recovery key could not be read: \(error)")
        }
        try check(candidate, against: description, wrongMessage: "Incorrect recovery key")
        return (candidate, resolvedId)
    }

    /// Unlock a 4S key by deriving it from a passphrase via the key's
    /// `m.pbkdf2` parameters, verifying it against the stored key check.
    /// This is CPU-heavy by design (the spec default is 500k SHA-512
    /// iterations); callers should run it off the main actor.
    public func unlock(
        passphrase: String, keyId: String? = nil
    ) async throws(MatrixError) -> (key: Data, keyId: String) {
        let (description, resolvedId) = try await resolveKey(keyId: keyId)
        guard let params = description.passphrase else {
            throw MatrixError.recoveryFailed(
                "This 4S key has no passphrase set — use the recovery key")
        }
        guard params.algorithm == "m.pbkdf2" else {
            throw MatrixError.recoveryFailed(
                "Unsupported passphrase algorithm: \(params.algorithm)")
        }
        guard params.bits ?? 256 == 256 else {
            throw MatrixError.recoveryFailed(
                "Unsupported passphrase key length: \(params.bits ?? 256) bits")
        }
        guard
            let salt = params.salt.data(using: .utf8),
            let password = passphrase.data(using: .utf8)
        else {
            throw MatrixError.recoveryFailed("Unusable passphrase parameters")
        }
        let candidate = Primitives.pbkdf2SHA512(
            password: password, salt: salt,
            iterations: params.iterations, outputByteCount: 32)
        try check(candidate, against: description, wrongMessage: "Incorrect passphrase")
        return (candidate, resolvedId)
    }

    // MARK: - Internals

    /// Single narrowing point for reads: the client only throws
    /// `MatrixError`; anything else is a bug surfaced as a network error.
    private func get(_ type: String) async throws(MatrixError) -> [String: AnyCodable]? {
        do {
            return try await read(type)
        } catch let matrix as MatrixError {
            throw matrix
        } catch {
            throw .networkError(String(describing: error))
        }
    }
    private func resolveKey(
        keyId: String?
    ) async throws(MatrixError)
        -> (description: SecretStorageKeyDescription, keyId: String)
    {
        let resolved: String
        if let keyId { resolved = keyId } else if let id = try await defaultKeyId() {
            resolved = id
        } else {
            throw MatrixError.recoveryFailed(
                "This account has no 4S secret storage set up")
        }
        guard let description = try await keyDescription(keyId: resolved) else {
            throw MatrixError.recoveryFailed(
                "No secret-storage key \(resolved) on this account")
        }
        guard description.algorithm == "m.secret_storage.v1.aes-hmac-sha2" else {
            throw MatrixError.recoveryFailed(
                "Unsupported secret-storage algorithm: \(description.algorithm)")
        }
        return (description, resolved)
    }

    private func check(
        _ candidate: Data,
        against description: SecretStorageKeyDescription,
        wrongMessage: String
    ) throws(MatrixError) {
        guard
            let iv = Primitives.base64UnpaddedDecode(description.iv),
            let mac = Primitives.base64UnpaddedDecode(description.mac)
        else {
            throw MatrixError.recoveryFailed(
                "Malformed secret-storage key check")
        }
        guard SecretStorageCrypto.verifyKey(storageKey: candidate, iv: iv, mac: mac) else {
            throw MatrixError.recoveryFailed(wrongMessage)
        }
    }

    private func secretData(
        _ name: String, keyId: String, storageKey: Data
    ) async throws(MatrixError) -> Data? {
        guard let dict = try await get(name) else { return nil }
        let payload = try decode(SecretStoragePayload.self, from: dict)
        guard let entry = payload.encrypted[keyId] else { return nil }
        guard
            let iv = Primitives.base64UnpaddedDecode(entry.iv),
            let ciphertext = Primitives.base64UnpaddedDecode(entry.ciphertext),
            let mac = Primitives.base64UnpaddedDecode(entry.mac)
        else {
            throw MatrixError.recoveryFailed("Malformed stored secret \(name)")
        }
        do {
            return try SecretStorageCrypto.decrypt(
                ciphertext: ciphertext, mac: mac, iv: iv,
                name: name, storageKey: storageKey)
        } catch {
            throw MatrixError.recoveryFailed(
                "Could not decrypt secret \(name): \(error)")
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type, from dict: [String: AnyCodable]
    ) throws(MatrixError) -> T {
        do {
            let data = try JSONEncoder().encode(AnyCodableDictionary(dict))
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MatrixError.decodingError(
                "Malformed 4S account data: \(error)")
        }
    }
}

/// `m.secret_storage.default_key` content: `{"key": "<key id>"}`.
private struct DefaultKeyRecord: Decodable {
    var key: String?
}

/// `m.secret_storage.key.<id>` content: algorithm, optional passphrase
/// derivation, and the `(iv, mac)` zero-block key check (base64).
public struct SecretStorageKeyDescription: Hashable, Sendable, Codable {
    public var algorithm: String
    public var passphrase: SecretStoragePassphrase?
    public var iv: String
    public var mac: String
    /// Friendly key name, if the creating client set one.
    public var name: String?

    public init(
        algorithm: String,
        passphrase: SecretStoragePassphrase? = nil,
        iv: String,
        mac: String,
        name: String? = nil
    ) {
        self.algorithm = algorithm
        self.passphrase = passphrase
        self.iv = iv
        self.mac = mac
        self.name = name
    }
}

/// `m.pbkdf2` passphrase derivation parameters. `bits` defaults to 256.
public struct SecretStoragePassphrase: Hashable, Sendable, Codable {
    public var algorithm: String
    public var salt: String
    public var iterations: Int
    public var bits: Int?

    public init(algorithm: String, salt: String, iterations: Int, bits: Int? = nil) {
        self.algorithm = algorithm
        self.salt = salt
        self.iterations = iterations
        self.bits = bits
    }
}

/// A named secret event: `{"encrypted": {"<keyId>": {...}}}`.
private struct SecretStoragePayload: Decodable {
    var encrypted: [String: SecretStorageEntry]
}

/// One key-ID entry of a stored secret (base64 fields).
private struct SecretStorageEntry: Decodable {
    var iv: String
    var ciphertext: String
    var mac: String
}

/// What a 4S recovery produced. Cross-signing keys are imported
/// immediately; the backup private key is returned for the separate
/// `restoreKeyBackup` step (megolm restores are large and belong behind
/// their own progress UI).
public struct RecoveryOutcome: Hashable, Sendable {
    /// Whether all three cross-signing private keys were recovered and
    /// imported. False when the account stores no cross-signing secrets.
    public var crossSigningImported: Bool
    /// The `m.megolm_backup.v1` private key, if stored. Nil when the
    /// account keeps no backup key in 4S.
    public var backupPrivateKey: Data?

    public init(crossSigningImported: Bool, backupPrivateKey: Data? = nil) {
        self.crossSigningImported = crossSigningImported
        self.backupPrivateKey = backupPrivateKey
    }
}

/// A progress snapshot emitted while `MatrixClient.restoreKeyBackup`
/// or `MatrixClient.recover` fetch and import keys. Totals are known
/// only once the work is enumerated (importing backed-up sessions),
/// so `total` is nil — and the snapshot indeterminate — until then.
public struct KeyFetchProgress: Sendable {
    /// Which stage the operation is in.
    public enum Phase: String, Sendable, Hashable {
        /// Unlocking 4S secret storage (recovery key or passphrase).
        case unlocking
        /// Fetching secrets or downloading backed-up sessions.
        case fetching
        /// Importing sessions or keys into the local store.
        case importing
        /// Re-running timeline decryption with the new keys.
        case finishing
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int?

    public init(phase: Phase, completed: Int = 0, total: Int? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    /// Determinate fraction in 0...1, or nil while the total is unknown.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}
