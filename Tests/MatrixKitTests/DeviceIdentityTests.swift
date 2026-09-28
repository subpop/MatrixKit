import Foundation
import MatrixKitCrypto
import Testing

@testable import MatrixKit

@Suite("DeviceIdentity")
struct DeviceIdentityTests {
    @Test("Generated device keys carry a valid self-signature")
    func selfSigned() throws {
        let material = DeviceIdentityKeys.generate()
        let keys = try material.deviceKeys(
            userId: "@alice:example.com", deviceId: "TESTDEV")
        #expect(keys.keys["curve25519:TESTDEV"] != nil)
        #expect(keys.keys["ed25519:TESTDEV"] == material.signing.publicKeyBase64)

        let signature = try #require(
            keys.signatures["@alice:example.com"]?["ed25519:TESTDEV"])
        let payload: [String: Any] = [
            "user_id": keys.userId,
            "device_id": keys.deviceId,
            "algorithms": keys.algorithms,
            "keys": keys.keys,
        ]
        let canonical = try CryptoPrimitives.canonicalJSON(payload)
        #expect(
            SigningKey.verify(
                signature: try #require(
                    Primitives.base64UnpaddedDecode(signature)),
                for: canonical,
                publicKey: material.signing.publicKeyBytes))
    }

    @Test("Backup round-trips through JSON and restores identical keys")
    func backupRoundTrip() throws {
        let material = DeviceIdentityKeys.generate()
        let data = try JSONEncoder().encode(material.backup())
        let backup = try JSONDecoder().decode(
            DeviceIdentityBackup.self, from: data)
        let restored = try DeviceIdentityKeys.restore(backup)
        #expect(
            restored.signing.publicKeyBytes == material.signing.publicKeyBytes)
        #expect(
            try restored.curve25519Public() == material.curve25519Public())
    }

    @Test("Corrupt backups are rejected")
    func corruptBackup() {
        #expect(throws: (any Error).self) {
            try DeviceIdentityKeys.restore(
                DeviceIdentityBackup(
                    ed25519PrivateKey: "!!!", curve25519PrivateKey: "!!!"))
        }
    }

    @Test("Store round-trips the backup")
    func storeRoundTrip() async throws {
        let store = DeviceIdentityStore(keystore: InMemoryKeyStore())
        let user = UserId(unchecked: "@alice:example.com")
        let device = DeviceId("TESTDEV")
        #expect(await store.load(userId: user, deviceId: device) == nil)
        try await store.save(
            DeviceIdentityKeys.generate().backup(),
            userId: user, deviceId: device)
        let loaded = try #require(
            await store.load(userId: user, deviceId: device))
        // Restorable ⇒ structurally valid.
        _ = try DeviceIdentityKeys.restore(loaded)
    }

    @Test("Pre-split per-user dict migrates forward on load")
    func legacyDictMigrates() async throws {
        let keystore = InMemoryKeyStore()
        let user = UserId(unchecked: "@alice:example.com")
        let backup = DeviceIdentityKeys.generate().backup()
        // Seed the old layout directly: one dict entry per user.
        try await keystore.save(
            JSONEncoder().encode(["TESTDEV": backup]),
            for: KeyStoreKey(
                service: "device_identity", account: user.value))
        let store = DeviceIdentityStore(keystore: keystore)
        let loaded = try #require(
            await store.load(userId: user, deviceId: DeviceId("TESTDEV")))
        #expect(loaded == backup)
        // Migrated entry is readable under the new per-device key.
        let stored = try #require(try await keystore.load(KeyStoreKey(
            service: "device_identity",
            account: user.value + "-TESTDEV")))
        #expect(try JSONDecoder().decode(
            DeviceIdentityBackup.self, from: stored) == backup)
    }

    @Test("Delete prunes the legacy dict slot, preserving siblings")
    func legacyDictPrunedOnDelete() async throws {
        let keystore = InMemoryKeyStore()
        let user = UserId(unchecked: "@alice:example.com")
        let backup = DeviceIdentityKeys.generate().backup()
        try await keystore.save(
            JSONEncoder().encode(
                ["GONE": backup, "STAYS": backup]),
            for: KeyStoreKey(
                service: "device_identity", account: user.value))
        let store = DeviceIdentityStore(keystore: keystore)
        try await store.delete(userId: user, deviceId: DeviceId("GONE"))
        let pruned = try #require(try await keystore.load(KeyStoreKey(
            service: "device_identity", account: user.value)))
        let dict = try JSONDecoder().decode(
            [String: DeviceIdentityBackup].self, from: pruned)
        #expect(dict["GONE"] == nil)
        #expect(dict["STAYS"] == backup)
    }
}
