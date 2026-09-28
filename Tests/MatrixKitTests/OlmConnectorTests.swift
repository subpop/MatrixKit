import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit
@testable import MatrixKitCrypto

@Suite("OlmConnector")
struct OlmConnectorTests {
    private func users() throws -> (UserId, UserId) {
        (UserId(unchecked: "@alice:x"), UserId(unchecked: "@bob:x"))
    }

    private func makePair() async throws -> (
        alice: OlmConnector, bob: OlmConnector,
        keys: FakeKeys, aliceSender: FakeSender, bobSender: FakeSender,
        aliceUser: UserId, bobUser: UserId
    ) {
        let (aliceUser, bobUser) = try users()
        let keys = FakeKeys()
        let aliceSender = FakeSender()
        let bobSender = FakeSender()
        let alice = OlmConnector(keys: keys, sender: aliceSender)
        let bob = OlmConnector(keys: keys, sender: bobSender)
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        return (alice, bob, keys, aliceSender, bobSender, aliceUser, bobUser)
    }

    @Test("ensureKeys uploads 50 signed OTKs + fallback")
    func ensureKeys() async throws {
        let (alice, _, keys, _, _, aliceUser, _) = try await makePair()
        try await alice.ensureKeys()
        #expect(
            await keys.otkCount(user: aliceUser.value, device: "ALICE") == 50)
        #expect(
            await keys.fallbackCount(user: aliceUser.value, device: "ALICE") == 1)
        // Query serves the uploaded device keys.
        let query = try await keys.queryKeys(users: [aliceUser])
        #expect(query.deviceKeys[aliceUser.value]?["ALICE"] != nil)
    }

    @Test("encrypted loopback decrypts and validates")
    func loopback() async throws {
        let (alice, bob, _, aliceSender, _, aliceUser, bobUser) =
            try await makePair()
        try await bob.ensureKeys()
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["secret": .string("s3cr3t")],
            to: bobUser, devices: [DeviceId("BOB")])
        let sent = await aliceSender.sent
        #expect(sent.count == 1)
        #expect(sent[0].type == "m.room.encrypted")
        let wire = BasicEvent(
            type: sent[0].type, sender: aliceUser, content: sent[0].content)
        let inner = await bob.decrypt([wire])
        #expect(inner.count == 1)
        #expect(inner[0].type == "m.secret.send")
        #expect(inner[0].sender == aliceUser)
        #expect(inner[0].content["secret"] == .string("s3cr3t"))
    }

    @Test("reply reuses the session as a normal message")
    func reply() async throws {
        let (alice, bob, _, aliceSender, bobSender, aliceUser, bobUser) =
            try await makePair()
        try await alice.ensureKeys()
        try await bob.ensureKeys()
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        let wire = BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)
        _ = await bob.decrypt([wire])
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let reply = await bobSender.sent
        #expect(reply.count == 1)
        // Type 1: Bob received on the session, so no pre-key.
        let cipher = reply[0].content["ciphertext"]?.objectValue
        let entry = cipher?.values.first?.objectValue
        #expect(entry?["type"]?.intValue == 1)
        let back = BasicEvent(
            type: reply[0].type, sender: bobUser,
            content: reply[0].content)
        let inner = await alice.decrypt([back])
        #expect(inner.count == 1)
        #expect(inner[0].content["n"] == .int(2))
    }

    @Test("tampered sender is dropped")
    func tamperedSenderDropped() async throws {
        let (alice, bob, _, aliceSender, _, _, bobUser) =
            try await makePair()
        try await bob.ensureKeys()
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["secret": .string("s3cr3t")],
            to: bobUser, devices: [DeviceId("BOB")])
        let sent = await aliceSender.sent
        let wire = BasicEvent(
            type: sent[0].type,
            sender: UserId(unchecked: "@mallory:x"),
            content: sent[0].content)
        #expect(await bob.decrypt([wire]).isEmpty)
    }

    @Test("maintainKeys refills when the server count is low")
    func refill() async throws {
        let (alice, _, keys, _, _, aliceUser, _) = try await makePair()
        try await alice.ensureKeys()
        #expect(
            await keys.otkCount(user: aliceUser.value, device: "ALICE") == 50)
        // Simulate heavy claiming: drain to 3, then refill.
        for _ in 0..<47 {
            _ = try await keys.claimKeys(
                user: aliceUser, device: "ALICE")
        }
        #expect(
            await keys.otkCount(user: aliceUser.value, device: "ALICE") == 3)
        try await alice.maintainKeys(serverCount: 3)
        #expect(
            await keys.otkCount(user: aliceUser.value, device: "ALICE") == 50)
    }

    @Test("sending to an unknown device throws")
    func unknownDevice() async throws {
        let (alice, _, keys, _, _, _, bobUser) = try await makePair()
        do {
            try await alice.sendEncrypted(
                eventType: "m.secret.send",
                content: [:],
                to: bobUser, devices: [DeviceId("GHOST")])
            Issue.record("expected noReachableDevices")
        } catch MatrixError.noReachableDevices {
            // Expected: stale-cache eviction retries once, then the
            // lone unclaimable peer surfaces as unreachable.
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // Exactly two queries: initial miss + one retry after eviction.
        #expect(await keys.queryCalls == 2)
    }

    @Test("peer with keys but no OTKs is skipped, live peer still receives")
    func skipsUnclaimablePeer() async throws {
        let (alice, bob, keys, aliceSender, _, _, bobUser) =
            try await makePair()
        try await bob.ensureKeys()
        // CAROL publishes device keys but never uploaded one-time
        // keys — the stale-device shape behind the SAS failure.
        let carolMaterial = DeviceIdentityKeys.generate()
        await keys.seedKeys(
            user: bobUser.value, device: "CAROL",
            keys: try carolMaterial.deviceKeys(
                userId: bobUser.value, deviceId: "CAROL"))
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB"), DeviceId("CAROL")])
        let sent = await aliceSender.sent
        #expect(sent.count == 1)
        #expect(sent[0].devices == ["BOB"])
    }

    @Test("all peers unclaimable throws noReachableDevices")
    func allPeersSkipped() async throws {
        let (alice, _, keys, _, _, _, bobUser) = try await makePair()
        let carolMaterial = DeviceIdentityKeys.generate()
        await keys.seedKeys(
            user: bobUser.value, device: "CAROL",
            keys: try carolMaterial.deviceKeys(
                userId: bobUser.value, deviceId: "CAROL"))
        do {
            try await alice.sendEncrypted(
                eventType: "m.secret.send",
                content: [:],
                to: bobUser, devices: [DeviceId("CAROL")])
            Issue.record("expected noReachableDevices")
        } catch MatrixError.noReachableDevices(let message) {
            #expect(message.contains("CAROL"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("resolved peers are queried once, then cached")
    func peerCache() async throws {
        let (alice, bob, keys, aliceSender, bobSender, aliceUser, bobUser) =
            try await makePair()
        try await alice.ensureKeys()
        try await bob.ensureKeys()
        #expect(await keys.queryCalls == 0)
        // Full exchange: one query per side for peer resolution.
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        _ = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let reply = await bobSender.sent
        _ = await alice.decrypt([BasicEvent(
            type: reply[0].type, sender: bobUser,
            content: reply[0].content)])
        #expect(await keys.queryCalls == 2)
        // Repeat exchange: no new queries (sessions + peers cached).
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(3)],
            to: bobUser, devices: [DeviceId("BOB")])
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(4)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        #expect(await keys.queryCalls == 2)
    }

    @Test("deviceIds backs '*' expansion from cache")
    func deviceListCache() async throws {
        let (alice, _, keys, _, _, _, bobUser) = try await makePair()
        try await alice.ensureKeys()
        // Bob has no keys yet: empty list, one query.
        #expect(try await alice.deviceIds(for: bobUser) == [])
        #expect(await keys.queryCalls == 1)
        #expect(try await alice.deviceIds(for: bobUser) == [])
        #expect(await keys.queryCalls == 1)
    }

    @Test("sessions + OTK pool survive connector restart via keystore")
    func restartRestoresSessions() async throws {
        let (aliceUser, bobUser) = try users()
        let keys = FakeKeys()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyStore(directory: dir)
        let bobMaterial = DeviceIdentityKeys.generate()
        let aliceSender = FakeSender()
        let alice = OlmConnector(keys: keys, sender: aliceSender)
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        try await alice.ensureKeys()
        let bob = OlmConnector(
            keys: keys, sender: FakeSender(), keystore: store)
        try await bob.configure(
            identity: bobMaterial,
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        // Establish a session with one exchange.
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        _ = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        // Simulate restart: fresh connector, same store + identity.
        let bob2 = OlmConnector(
            keys: keys, sender: FakeSender(), keystore: store)
        try await bob2.configure(
            identity: bobMaterial,
            userId: bobUser, deviceId: DeviceId("BOB"))
        // Alice's next message decrypts on the restored session.
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: bobUser, devices: [DeviceId("BOB")])
        let second = await aliceSender.sent
        let inner = await bob2.decrypt([BasicEvent(
            type: second[1].type, sender: aliceUser,
            content: second[1].content)])
        #expect(inner.count == 1)
        #expect(inner[0].content["n"] == .int(2))
        // A fresh pre-key from a third party proves the OTK pool restored.
        let carolUser = UserId(unchecked: "@carol:x")
        let carolSender = FakeSender()
        let carol = OlmConnector(keys: keys, sender: carolSender)
        try await carol.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: carolUser, deviceId: DeviceId("CAROL"))
        try await carol.ensureKeys()
        try await carol.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(3)],
            to: bobUser, devices: [DeviceId("BOB")])
        let third = await carolSender.sent
        let inner3 = await bob2.decrypt([BasicEvent(
            type: third[0].type, sender: carolUser,
            content: third[0].content)])
        #expect(inner3.count == 1)
        #expect(inner3[0].content["n"] == .int(3))
    }
}

@Suite("EncryptedToDeviceSender")
struct EncryptedToDeviceSenderTests {
    @Test("Star expands to peer devices, encrypts each")
    func starExpansion() async throws {
        let keys = FakeKeys()
        let sender = FakeSender()
        let alice = OlmConnector(keys: keys, sender: sender)
        let (aliceUser, bobUser) = (UserId(unchecked: "@alice:x"), UserId(unchecked: "@bob:x"))
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        let encrypted = EncryptedToDeviceSender(olm: alice)
        try await encrypted.send(
            eventType: "m.key.verification.request",
            content: ["flow": .string("m.sas.v1")],
            to: bobUser, devices: ["*"])
        let sent = await sender.sent
        #expect(sent.count == 1)
        #expect(sent[0].type == "m.room.encrypted")
        #expect(sent[0].devices == ["BOB"])
    }

    @Test("Star with no peers throws verificationFailed")
    func starNoPeers() async throws {
        let alice = OlmConnector(keys: FakeKeys(), sender: FakeSender())
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: UserId(unchecked: "@alice:x"), deviceId: DeviceId("ALICE"))
        let encrypted = EncryptedToDeviceSender(olm: alice)
        await #expect(throws: MatrixError.verificationFailed(
            "No other devices available for verification"))
        {
            try await encrypted.send(
                eventType: "m.key.verification.request",
                content: ["flow": .string("m.sas.v1")],
                to: UserId(unchecked: "@ghost:x"), devices: ["*"])
        }
    }

    @Test("Raw fans out per device with own ciphertexts")
    func rawFanout() async throws {
        let keys = FakeKeys()
        let sender = FakeSender()
        let alice = OlmConnector(keys: keys, sender: sender)
        let bobUser = UserId(unchecked: "@bob:test")
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: UserId(unchecked: "@alice:x"), deviceId: DeviceId("ALICE"))
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        let encrypted = EncryptedToDeviceSender(olm: alice)
        try await encrypted.sendRaw(
            eventType: "m.test",
            messages: ["@bob:test": ["BOB": ["k": .string("v")]]],
            transactionId: "txn")
        #expect(await sender.sent.count == 1)
    }
}
