import Foundation
import MatrixKit
import MatrixKitCrypto
import Testing

/// Logout wipes every local crypto remnant so a fresh sign-in starts
/// unverified: the cross-signing keychain entry, device identity
/// entries, persisted Olm sessions + one-time keys, and megolm
/// sessions.
@Suite("Crypto wipe on logout")
struct CryptoWipeTests {
    @Test("cross-signing backup saves and deletes")
    func crossSigningDelete() async throws {
        let keystore = InMemoryKeyStore()
        let store = CrossSigningStore(keystore: keystore)
        let user = UserId(unchecked: "@alice:x")
        // Missing entry is not an error.
        try await store.delete(userId: user)
        try await store.save(
            CrossSigningBackup(
                masterPrivateKey: "m", selfSigningPrivateKey: "s",
                userSigningPrivateKey: "u"),
            userId: user)
        #expect(await store.load(userId: user) != nil)
        try await store.delete(userId: user)
        #expect(await store.load(userId: user) == nil)
    }

    @Test("stores namespace under their relative service names")
    func serviceNames() async throws {
        let keystore = InMemoryKeyStore()
        let user = UserId(unchecked: "@alice:x")
        try await CrossSigningStore(keystore: keystore).save(
            CrossSigningBackup(
                masterPrivateKey: "m", selfSigningPrivateKey: "s",
                userSigningPrivateKey: "u"),
            userId: user)
        try await DeviceIdentityStore(keystore: keystore).save(
            DeviceIdentityKeys.generate().backup(),
            userId: user, deviceId: DeviceId("A1"))
        // Bare relative names: apps isolate items via their own
        // KeyStore naming, so two MatrixKit apps never collide.
        let keys = await keystore.keys
        #expect(
            keys.contains(
                KeyStoreKey(service: "cross_signing", account: "@alice:x")))
        #expect(
            keys.contains(
                KeyStoreKey(service: "device_identity", account: "@alice:x")))
    }

    @Test("device identities delete per user, across devices")
    func deviceIdentityDeleteAll() async throws {
        let store = DeviceIdentityStore(keystore: InMemoryKeyStore())
        let alice = UserId(unchecked: "@alice:x")
        let bob = UserId(unchecked: "@bob:x")
        let backup = DeviceIdentityKeys.generate().backup()
        try await store.save(backup, userId: alice, deviceId: DeviceId("A1"))
        try await store.save(backup, userId: alice, deviceId: DeviceId("A2"))
        try await store.save(backup, userId: bob, deviceId: DeviceId("B1"))
        #expect(await store.load(userId: alice, deviceId: DeviceId("A1")) != nil)
        try await store.deleteAll(userId: alice)
        #expect(await store.load(userId: alice, deviceId: DeviceId("A1")) == nil)
        #expect(await store.load(userId: alice, deviceId: DeviceId("A2")) == nil)
        #expect(await store.load(userId: bob, deviceId: DeviceId("B1")) != nil)
    }

    @Test("olm sessions and one-time keys delete")
    func olmDelete() async throws {
        let keystore = InMemoryKeyStore()
        let bob = OlmConnector(
            keys: FakeKeys(), sender: FakeSender(), keystore: keystore)
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: UserId(unchecked: "@bob:x"), deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        #expect(await !keystore.keys.isEmpty)
        await bob.deletePersistedState()
        #expect(await keystore.keys.isEmpty)
    }

    @Test("megolm sessions delete")
    func megolmDelete() async throws {
        let room = RoomId(unchecked: "!room:x")
        let aliceUser = UserId(unchecked: "@alice:x")
        let bobUser = UserId(unchecked: "@bob:x")
        let sharer = FakeSharer()
        let alice = RoomCrypto(sharer: sharer, sender: FakeRoomSender())
        let keystore = InMemoryKeyStore()
        let bob = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender(),
            keystore: keystore)
        await sharer.setDevices([bobUser.value: ["BOB"]])
        try await alice.shareRoomKey(roomId: room, users: [bobUser])
        let shares = await sharer.shares
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: shares[0].content))
        #expect(await !keystore.keys.isEmpty)
        await bob.deletePersistedSessions()
        #expect(await keystore.keys.isEmpty)
    }
}
