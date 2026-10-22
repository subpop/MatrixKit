import Foundation
import Testing

@testable import MatrixKit
import MatrixKitCrypto

/// Exercise the 4S `SecretStorage` actor against in-memory account data.
/// Fixtures are built with `SecretStorageCrypto` itself (its math is
/// cross-validated against Python/OpenSSL vectors in MatrixKitCryptoTests),
/// so these tests pin the actor's account-data I/O, key checks, and
/// passphrase derivation rather than the cipher.
@Suite("SecretStorage")
struct SecretStorageTests {
    private static let keyId = "testkey"
    private static let storageKey = Data((0..<32).map { UInt8($0) })
    private static let checkIv = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
    private static let secretIv = Data([9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9])
    private static let masterSecret = "c3VwZXItc2VjcmV0LW1hc3Rlcg"

    /// Account-data map with a default key, its description, and one
    /// encrypted `m.cross_signing.master` secret. Pass `passphrase` to
    /// attach `m.pbkdf2` derivation parameters (salt "testsalt").
    private static func fixtures(
        passphraseIterations: Int? = nil
    ) throws -> [String: String] {
        let checkMac = try SecretStorageCrypto.keyCheckMac(
            storageKey: storageKey, iv: checkIv)
        var keyDesc =
            """
            {"algorithm": "m.secret_storage.v1.aes-hmac-sha2",
             "iv": "\(Primitives.base64UnpaddedEncode(checkIv))",
             "mac": "\(Primitives.base64UnpaddedEncode(checkMac))"
            """
        if let iterations = passphraseIterations {
            keyDesc += ", \"passphrase\": {\"algorithm\": \"m.pbkdf2\","
            keyDesc += " \"salt\": \"testsalt\", \"iterations\": \(iterations)}"
        }
        keyDesc += "}"
        let plaintext = Data(masterSecret.utf8)
        let (ciphertext, mac) = try SecretStorageCrypto.encrypt(
            plaintext, name: SecretName.master,
            storageKey: storageKey, iv: secretIv)
        let secret =
            """
            {"encrypted": {"\(keyId)":
             {"iv": "\(Primitives.base64UnpaddedEncode(secretIv))",
              "ciphertext": "\(Primitives.base64UnpaddedEncode(ciphertext))",
              "mac": "\(Primitives.base64UnpaddedEncode(mac))"}}}
            """
        return [
            "m.secret_storage.default_key": #"{"key": "testkey"}"#,
            "m.secret_storage.key.\(keyId)": keyDesc,
            SecretName.master: secret,
        ]
    }

    private static func storage(
        _ json: [String: String]
    ) -> SecretStorage {
        SecretStorage { type in
            guard let raw = json[type] else { return nil }
            return try JSONDecoder().decode(
                [String: AnyCodable].self, from: Data(raw.utf8))
        }
    }

    /// Run `operation`, expecting `MatrixError.recoveryFailed` whose
    /// message contains `text`. Collapses the five failure-mode tests'
    /// shared do/catch shape into one assertion.
    private func requireRecoveryFailed(
        _ text: String,
        operation: () async throws -> Void,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) async {
        do {
            try await operation()
            Issue.record("expected recoveryFailed", sourceLocation: sourceLocation)
        } catch MatrixError.recoveryFailed(let message) {
            #expect(message.contains(text), sourceLocation: sourceLocation)
        } catch {
            Issue.record("wrong error: \(error)", sourceLocation: sourceLocation)
        }
    }

    /// Account data held in memory, read and written through one
    /// `SecretStorage` the way the homeserver would.
    private actor AccountDataStore {
        var data: [String: [String: AnyCodable]] = [:]
        func read(_ type: String) -> [String: AnyCodable]? { data[type] }
        func write(_ type: String, _ content: [String: AnyCodable]) { data[type] = content }
    }

    private static func writableStorage() -> (SecretStorage, AccountDataStore) {
        let store = AccountDataStore()
        let storage = SecretStorage(
            reader: { await store.read($0) },
            writer: { await store.write($0, $1) })
        return (storage, store)
    }

    @Test("a created key unlocks, and what is stored under it reads back")
    func createsAndStores() async throws {
        let (s, store) = Self.writableStorage()
        let (key, keyId) = try await s.createKey(name: "Relay")

        // Described but not the default until made so.
        #expect(try await s.defaultKeyId() == nil)
        let description = try #require(try await s.keyDescription(keyId: keyId))
        #expect(description.algorithm == "m.secret_storage.v1.aes-hmac-sha2")
        #expect(description.name == "Relay")
        let iv = try #require(Primitives.base64UnpaddedDecode(description.iv))
        #expect(iv.count == 16 && iv[7] & 0x80 == 0)

        try await s.store("backup-secret", as: SecretName.backup, keyId: keyId, storageKey: key)
        try await s.store("master-secret", as: SecretName.master, keyId: keyId, storageKey: key)
        try await s.makeDefault(keyId: keyId)
        #expect(try await s.defaultKeyId() == keyId)

        // Another session unlocks with the recovery key and reads the secrets.
        let recovery = BackupCrypto.recoveryKey(privateKey: key)
        let unlocked = try await s.unlock(recoveryKey: recovery)
        #expect(unlocked.keyId == keyId)
        #expect(try await s.secret(SecretName.backup, keyId: keyId, storageKey: key) == "backup-secret")
        #expect(try await s.secret(SecretName.master, keyId: keyId, storageKey: key) == "master-secret")
        // A different key cannot.
        await requireRecoveryFailed("Incorrect recovery key") {
            _ = try await s.unlock(
                recoveryKey: BackupCrypto.recoveryKey(
                    privateKey: BackupCrypto.generatePrivateKey()))
        }
        #expect(await store.data.keys.contains("m.secret_storage.default_key"))
    }

    @Test("storing a secret keeps entries for other keys")
    func storeKeepsOtherEntries() async throws {
        let (s, store) = Self.writableStorage()
        await store.write(SecretName.master, [
            "encrypted": .object(["otherkey": .object(["iv": .string("x")])])
        ])
        let (key, keyId) = try await s.createKey()
        try await s.store("value", as: SecretName.master, keyId: keyId, storageKey: key)
        let entries = try #require(await store.data[SecretName.master]?["encrypted"]?.objectValue)
        #expect(Set(entries.keys) == ["otherkey", keyId])
    }

    @Test("existing secret storage is never replaced")
    func createKeyRefusesWhenSetUp() async throws {
        let (s, store) = Self.writableStorage()
        for (type, raw) in try Self.fixtures() {
            await store.write(type, try JSONDecoder().decode(
                [String: AnyCodable].self, from: Data(raw.utf8)))
        }
        await requireRecoveryFailed("already has secret storage") {
            _ = try await s.createKey()
        }
    }

    @Test("default key ID and description read")
    func readsKey() async throws {
        let s = Self.storage(try Self.fixtures())
        #expect(try await s.defaultKeyId() == Self.keyId)
        let desc = try await s.keyDescription(keyId: Self.keyId)
        #expect(desc?.algorithm == "m.secret_storage.v1.aes-hmac-sha2")
        #expect(desc?.passphrase == nil)
    }

    @Test("missing 4S setup reads as nil")
    func missingReadsNil() async throws {
        let s = Self.storage([:])
        #expect(try await s.defaultKeyId() == nil)
        #expect(try await s.keyDescription(keyId: "nope") == nil)
    }

    @Test("recovery-key unlock returns the storage key")
    func unlockRecoveryKey() async throws {
        let s = Self.storage(try Self.fixtures())
        let keyString = BackupCrypto.recoveryKey(privateKey: Self.storageKey)
        let (key, resolved) = try await s.unlock(recoveryKey: keyString)
        #expect(key == Self.storageKey)
        #expect(resolved == Self.keyId)
    }

    @Test("wrong recovery key fails the key check")
    func wrongRecoveryKey() async throws {
        let s = Self.storage(try Self.fixtures())
        let wrong = BackupCrypto.recoveryKey(
            privateKey: Data(repeating: 7, count: 32))
        await requireRecoveryFailed("Incorrect recovery key") {
            _ = try await s.unlock(recoveryKey: wrong)
        }
    }

    @Test("unlock without 4S setup fails")
    func unlockWithoutSetup() async throws {
        let s = Self.storage([:])
        await #expect(throws: MatrixError.self) {
            try await s.unlock(recoveryKey: "EsX")
        }
    }

    @Test("unsupported storage algorithm fails")
    func unsupportedAlgorithm() async throws {
        var json = try Self.fixtures()
        json["m.secret_storage.key.\(Self.keyId)"] =
            #"{"algorithm": "m.future.v9", "iv": "AA", "mac": "AA"}"#
        let s = Self.storage(json)
        await requireRecoveryFailed("Unsupported secret-storage algorithm") {
            _ = try await s.unlock(
                recoveryKey: BackupCrypto.recoveryKey(privateKey: Self.storageKey))
        }
    }

    @Test("passphrase unlock derives the storage key")
    func unlockPassphrase() async throws {
        let expected = Primitives.pbkdf2SHA512(
            password: Data("correct horse".utf8),
            salt: Data("testsalt".utf8),
            iterations: 1000, outputByteCount: 32)
        // Re-encrypt fixtures under the passphrase-derived key instead.
        let checkMac = try SecretStorageCrypto.keyCheckMac(
            storageKey: expected, iv: Self.checkIv)
        let keyDesc =
            """
            {"algorithm": "m.secret_storage.v1.aes-hmac-sha2",
             "passphrase": {"algorithm": "m.pbkdf2", "salt": "testsalt",
                            "iterations": 1000},
             "iv": "\(Primitives.base64UnpaddedEncode(Self.checkIv))",
             "mac": "\(Primitives.base64UnpaddedEncode(checkMac))"}
            """
        let plaintext = Data(Self.masterSecret.utf8)
        let (ciphertext, mac) = try SecretStorageCrypto.encrypt(
            plaintext, name: SecretName.master,
            storageKey: expected, iv: Self.secretIv)
        let secret =
            """
            {"encrypted": {"\(Self.keyId)":
             {"iv": "\(Primitives.base64UnpaddedEncode(Self.secretIv))",
              "ciphertext": "\(Primitives.base64UnpaddedEncode(ciphertext))",
              "mac": "\(Primitives.base64UnpaddedEncode(mac))"}}}
            """
        let derived = Self.storage([
            "m.secret_storage.default_key": #"{"key": "testkey"}"#,
            "m.secret_storage.key.\(Self.keyId)": keyDesc,
            SecretName.master: secret,
        ])
        let (key, _) = try await derived.unlock(passphrase: "correct horse")
        #expect(key == expected)
    }

    @Test("wrong passphrase fails the key check")
    func wrongPassphrase() async throws {
        let s = Self.storage(try Self.fixtures(passphraseIterations: 1000))
        await requireRecoveryFailed("Incorrect passphrase") {
            _ = try await s.unlock(passphrase: "wrong horse")
        }
    }

    @Test("passphrase unlock without derivation params fails")
    func passphraseWithoutParams() async throws {
        let s = Self.storage(try Self.fixtures())
        await requireRecoveryFailed("no passphrase") {
            _ = try await s.unlock(passphrase: "anything")
        }
    }

    @Test("secret decrypts under the unlocked key")
    func readsSecret() async throws {
        let s = Self.storage(try Self.fixtures())
        let (key, keyId) = try await s.unlock(
            recoveryKey: BackupCrypto.recoveryKey(privateKey: Self.storageKey))
        #expect(
            try await s.secret(SecretName.master, keyId: keyId, storageKey: key)
                == Self.masterSecret)
    }

    @Test("missing secrets and key entries read as nil")
    func missingSecretsNil() async throws {
        let s = Self.storage(try Self.fixtures())
        #expect(
            try await s.secret(
                SecretName.selfSigning, keyId: Self.keyId,
                storageKey: Self.storageKey) == nil)
        #expect(
            try await s.secret(
                SecretName.master, keyId: "other",
                storageKey: Self.storageKey) == nil)
    }

    @Test("tampered ciphertext fails decryption")
    func tamperedSecret() async throws {
        var json = try Self.fixtures()
        json[SecretName.master] =
            """
            {"encrypted": {"\(Self.keyId)":
             {"iv": "\(Primitives.base64UnpaddedEncode(Self.secretIv))",
              "ciphertext": "AAAAAAAAAAAAAAAAAAAAAA",
              "mac": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}}
            """
        let s = Self.storage(json)
        await requireRecoveryFailed("Could not decrypt") {
            _ = try await s.secret(
                SecretName.master, keyId: Self.keyId,
                storageKey: Self.storageKey)
        }
    }

    @Test("key fetch progress is indeterminate until the total is known", arguments: [
        (KeyFetchProgress(phase: .fetching), nil as Double?),
        (KeyFetchProgress(phase: .importing, total: 0), nil),
        (KeyFetchProgress(phase: .importing, completed: 1, total: 4), 0.25),
        (KeyFetchProgress(phase: .finishing, completed: 4, total: 4), 1),
    ])
    func keyFetchProgressFraction(_ progress: KeyFetchProgress, expected: Double?) {
        #expect(progress.fraction == expected)
    }

    @Test("Non-UTF8 secrets fail decoding")
    func nonUTF8Secret() async throws {
        var json = try Self.fixtures()
        let binary = Data([0xFF, 0xFE, 0x00])
        let (ciphertext, mac) = try SecretStorageCrypto.encrypt(
            binary, name: SecretName.master,
            storageKey: Self.storageKey, iv: Self.secretIv)
        json[SecretName.master] =
            """
            {"encrypted": {"\(Self.keyId)":
             {"iv": "\(Primitives.base64UnpaddedEncode(Self.secretIv))",
              "ciphertext": "\(Primitives.base64UnpaddedEncode(ciphertext))",
              "mac": "\(Primitives.base64UnpaddedEncode(mac))"}}}
            """
        let s = Self.storage(json)
        do {
            _ = try await s.secret(
                SecretName.master, keyId: Self.keyId,
                storageKey: Self.storageKey)
            Issue.record("expected decodingError")
        } catch MatrixError.decodingError(let message) {
            #expect(message.contains("not valid UTF-8"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Malformed key checks and entries fail")
    func malformedStores() async throws {
        var badCheck = try Self.fixtures()
        badCheck["m.secret_storage.key.\(Self.keyId)"] =
            #"{"algorithm": "m.secret_storage.v1.aes-hmac-sha2", "iv": "!!!", "mac": "!!!"}"#
        await requireRecoveryFailed("Malformed secret-storage key check") {
            let s = Self.storage(badCheck)
            let keyString = BackupCrypto.recoveryKey(privateKey: Self.storageKey)
            _ = try await s.unlock(recoveryKey: keyString)
        }
        var badEntry = try Self.fixtures()
        badEntry[SecretName.master] =
            #"{"encrypted": {"testkey": {"iv": "!!!", "ciphertext": "!!!", "mac": "!!!"}}}"#
        await requireRecoveryFailed("Malformed stored secret") {
            let s = Self.storage(badEntry)
            _ = try await s.secret(
                SecretName.master, keyId: Self.keyId,
                storageKey: Self.storageKey)
        }
    }

    @Test("Unsupported passphrase parameters fail")
    func badPassphraseParams() async throws {
        // The stock fixtures' key check binds the recovery key, not a
        // passphrase derivation — so only the algorithm guard is
        // reachable here; derivation paths live in unlockPassphrase.
        var argon = try Self.fixtures(passphraseIterations: 1000)
        argon["m.secret_storage.key.\(Self.keyId)"] =
            (argon["m.secret_storage.key.\(Self.keyId)"] ?? "").replacing(
                "m.pbkdf2", with: "argon2id")
        await requireRecoveryFailed("Unsupported passphrase algorithm") {
            let s = Self.storage(argon)
            _ = try await s.unlock(passphrase: "correct horse")
        }
    }
}
