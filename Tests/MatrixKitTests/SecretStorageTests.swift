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
        await #expect(throws: MatrixError.self) {
            try await s.unlock(recoveryKey: wrong)
        }
        do {
            _ = try await s.unlock(recoveryKey: wrong)
            Issue.record("expected recoveryFailed")
        } catch MatrixError.recoveryFailed(let msg) {
            #expect(msg.contains("Incorrect recovery key"))
        } catch {
            Issue.record("wrong error: \(error)")
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
        do {
            _ = try await s.unlock(
                recoveryKey: BackupCrypto.recoveryKey(privateKey: Self.storageKey))
            Issue.record("expected recoveryFailed")
        } catch MatrixError.recoveryFailed(let msg) {
            #expect(msg.contains("Unsupported secret-storage algorithm"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("passphrase unlock derives the storage key")
    func unlockPassphrase() async throws {
        let s = Self.storage(try Self.fixtures(passphraseIterations: 1000))
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
        do {
            _ = try await s.unlock(passphrase: "wrong horse")
            Issue.record("expected recoveryFailed")
        } catch MatrixError.recoveryFailed(let msg) {
            #expect(msg.contains("Incorrect passphrase"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("passphrase unlock without derivation params fails")
    func passphraseWithoutParams() async throws {
        let s = Self.storage(try Self.fixtures())
        do {
            _ = try await s.unlock(passphrase: "anything")
            Issue.record("expected recoveryFailed")
        } catch MatrixError.recoveryFailed(let msg) {
            #expect(msg.contains("no passphrase"))
        } catch {
            Issue.record("wrong error: \(error)")
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
        do {
            _ = try await s.secret(
                SecretName.master, keyId: Self.keyId,
                storageKey: Self.storageKey)
            Issue.record("expected recoveryFailed")
        } catch MatrixError.recoveryFailed(let msg) {
            #expect(msg.contains("Could not decrypt"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("key fetch progress is indeterminate until the total is known")
    func keyFetchProgressFraction() {
        #expect(KeyFetchProgress(phase: .fetching).fraction == nil)
        #expect(KeyFetchProgress(phase: .importing, total: 0).fraction == nil)
        #expect(KeyFetchProgress(phase: .importing, completed: 1, total: 4).fraction == 0.25)
        #expect(KeyFetchProgress(phase: .finishing, completed: 4, total: 4).fraction == 1)
    }
}
