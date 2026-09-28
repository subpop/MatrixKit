import Foundation
import Testing

import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixKit

/// Recovery compliance suite: full 4S recovery through the facade —
/// fixtures encrypted with `SecretStorageCrypto`, stored via account
/// data, unlocked with a recovery key, cross-signing imported, device
/// self-signed, and the backup key returned.
///
/// Exercised: `GET|PUT /user/{userId}/account_data/{type}` (4S reads),
/// `POST /keys/query` + `POST /keys/signatures/upload` (self-sign).
@Suite("RecoveryCompliance")
struct RecoveryComplianceTests {
    struct Fixtures {
        var storageKey: Data
        var keyId: String
        var recoveryKey: String
        var entries: [String: String]
        var backupPrivateKey: Data

        static func make() throws -> Fixtures {
        let storageKey = Data((0..<32).map { UInt8($0) })
        let keyId = "testkey"
        let checkIv = Data(repeating: 1, count: 16)
        let checkMac = try SecretStorageCrypto.keyCheckMac(
            storageKey: storageKey, iv: checkIv)
        let keyDesc =
            """
            {"algorithm": "m.secret_storage.v1.aes-hmac-sha2",
             "iv": "\(Primitives.base64UnpaddedEncode(checkIv))",
             "mac": "\(Primitives.base64UnpaddedEncode(checkMac))"}
            """
        // Real cross-signing halves (imported + used to self-sign below).
        let master = SigningKey.generate()
        let selfSigning = SigningKey.generate()
        let userSigning = SigningKey.generate()
        let backupPrivateKey = Data((100..<132).map { UInt8($0) })
        let secrets: [(name: String, plaintext: String)] = [
            (SecretName.master, master.privateKeyBase64),
            (SecretName.selfSigning, selfSigning.privateKeyBase64),
            (SecretName.userSigning, userSigning.privateKeyBase64),
            (SecretName.backup, Primitives.base64UnpaddedEncode(backupPrivateKey)),
        ]
        var entries = [
            "m.secret_storage.default_key": #"{"key": "testkey"}"#,
            "m.secret_storage.key.\(keyId)": keyDesc,
        ]
        let secretIv = Data(repeating: 9, count: 16)
        for secret in secrets {
            let (ciphertext, mac) = try SecretStorageCrypto.encrypt(
                Data(secret.plaintext.utf8), name: secret.name,
                storageKey: storageKey, iv: secretIv)
            entries[secret.name] =
                """
                {"encrypted": {"\(keyId)":
                 {"iv": "\(Primitives.base64UnpaddedEncode(secretIv))",
                  "ciphertext": "\(Primitives.base64UnpaddedEncode(ciphertext))",
                  "mac": "\(Primitives.base64UnpaddedEncode(mac))"}}}
                """
        }
        return Fixtures(
            storageKey: storageKey, keyId: keyId,
            recoveryKey: BackupCrypto.recoveryKey(privateKey: storageKey),
            entries: entries, backupPrivateKey: backupPrivateKey)
        }
    }

    @MainActor
    private func client(_ harness: Harness) async -> MatrixClient {
        await MatrixClient.restore(
            homeserver: await harness.baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: "harness-token-alice",
            keystore: InMemoryKeyStore())
    }

    @Test("Recovery imports keys, self-signs, and returns the backup key")
    @MainActor
    func recover() async throws {
        actor PhaseLog {
            var phases: [KeyFetchProgress.Phase] = []
            func record(_ phase: KeyFetchProgress.Phase) { phases.append(phase) }
        }
        try await withHarness { harness in
            let fixtures = try Fixtures.make()
            let client = await client(harness)
            for (type, json) in fixtures.entries {
                let data = try JSONDecoder().decode(
                    [String: AnyCodable].self, from: Data(json.utf8))
                try await client.accountData.put(type, content: data)
            }
            // A real device record so the self-sign step has a target.
            let (keys, _, _) = await harness.keyClient()
            let material = DeviceIdentityKeys.generate()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: material.deviceKeys(
                    userId: "@alice:test", deviceId: "ALICEDEVICE")))
            let log = PhaseLog()
            let outcome = try await client.recover(
                withRecoveryKey: fixtures.recoveryKey,
                progress: { await log.record($0.phase) })
            let phases = await log.phases
            #expect(outcome.crossSigningImported)
            #expect(outcome.backupPrivateKey == fixtures.backupPrivateKey)
            #expect(phases.contains(.unlocking))
            #expect(phases.contains(.fetching))
            #expect(phases.contains(.finishing))
            #expect(await client.crossSigning.hasKeys)
            #expect(await client.session.isValid)
            try? await client.transport.shutdown()
        }
    }

    @Test("Wrong recovery key fails cleanly")
    @MainActor
    func wrongKey() async throws {
        try await withHarness { harness in
            let fixtures = try Fixtures.make()
            let client = await client(harness)
            for (type, json) in fixtures.entries {
                let data = try JSONDecoder().decode(
                    [String: AnyCodable].self, from: Data(json.utf8))
                try await client.accountData.put(type, content: data)
            }
            let wrong = BackupCrypto.recoveryKey(
                privateKey: Data(repeating: 7, count: 32))
            await #expect(throws: MatrixError.self) {
                try await client.recover(withRecoveryKey: wrong)
            }
            try? await client.transport.shutdown()
        }
    }

    @Test("Tampered secrets fail cleanly")
    @MainActor
    func tamperedSecrets() async throws {
        try await withHarness { harness in
            let fixtures = try Fixtures.make()
            let client = await client(harness)
            for (type, json) in fixtures.entries {
                let data = try JSONDecoder().decode(
                    [String: AnyCodable].self, from: Data(json.utf8))
                try await client.accountData.put(type, content: data)
            }
            // Malformed 4S records surface as decoding errors.
            try await client.accountData.put(
                "m.secret_storage.default_key", content: ["key": .int(42)])
            await #expect(throws: MatrixError.self) {
                try await client.secretStorage.defaultKeyId()
            }
            // Valid shape with a zeroed MAC fails the integrity check.
            let badMac = Primitives.base64UnpaddedEncode(Data(repeating: 0, count: 32))
            let tampered = try JSONDecoder().decode(
                [String: AnyCodable].self,
                from: Data(
                    """
                    {"encrypted": {"testkey":
                     {"iv": "AAAAAAAAAAAAAAAAAAAAAA",
                      "ciphertext": "AQ",
                      "mac": "\(badMac)"}}}
                    """.utf8))
            try await client.accountData.put(SecretName.master, content: tampered)
            await #expect(throws: MatrixError.self) {
                try await client.secretStorage.secret(
                    SecretName.master, keyId: "testkey",
                    storageKey: fixtures.storageKey)
            }
            try? await client.transport.shutdown()
        }
    }
}
