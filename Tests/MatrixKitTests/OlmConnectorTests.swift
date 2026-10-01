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
        // Coalesced writes land on flush, not per send (see
        // `PersistCoalescer`): settle before simulating restart.
        await bob.flushCryptoState()
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

    @Test("bursty sends collapse into one keystore write")
    func sendsCoalescePersists() async throws {
        let (aliceUser, bobUser) = try users()
        let keys = FakeKeys()
        let store = CountingKeyStore()
        let alice = OlmConnector(
            keys: keys, sender: FakeSender(), keystore: store)
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        // Settle configure/ensureKeys writes so only the sends count.
        await alice.flushCryptoState()
        let settled = await store.saves
        for i in 0..<5 {
            try await alice.sendEncrypted(
                eventType: "m.secret.send",
                content: ["n": .int(i)],
                to: bobUser, devices: [DeviceId("BOB")])
        }
        await alice.flushCryptoState()
        // Five sends collapse into one debounced flush, which writes
        // at most the sessions + OTK entries (uncoalesced: ten writes).
        let burstWrites = await store.saves - settled
        #expect(burstWrites > 0)
        #expect(burstWrites <= 2)
    }

    @Test("legacy OTK pool migrates instead of regenerating")
    func legacyPoolMigrates() async throws {
        let (aliceUser, _) = try users()
        let keystore = InMemoryKeyStore()
        // Seed the pre-per-device user-scoped pool directly.
        let legacy = KeyStoreKey(
            service: "MatrixKit.Olm", account: "otks-" + aliceUser.value)
        let pool = Data([9, 9, 9])
        try await keystore.save(pool, for: legacy)
        try await keystore.save(
            Data([7]), for: KeyStoreKey(
                service: "MatrixKit.Olm",
                account: "sessions-" + aliceUser.value))
        let alice = OlmConnector(
            keys: FakeKeys(), sender: FakeSender(), keystore: keystore)
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        // Adopted into the per-device slot (so already-uploaded
        // server-side keys stay matchable); legacy entries gone, and
        // legacy sessions never adopted.
        let migrated = KeyStoreKey(
            service: "MatrixKit.Olm",
            account: "otks-" + aliceUser.value + "-ALICE")
        #expect(try await keystore.load(migrated) == pool)
        let keys = await keystore.keys
        #expect(!keys.contains(legacy))
        #expect(!keys.contains(KeyStoreKey(
            service: "MatrixKit.Olm",
            account: "sessions-" + aliceUser.value)))
        #expect(!keys.contains(where: {
            $0.service == "MatrixKit.Olm"
                && $0.account.contains("sessions-")
        }))
    }

    @Test("duplicate delivery never drops the session")
    func replayKeepsSessions() async throws {
        let (alice, bob, _, aliceSender, bobSender, aliceUser, bobUser) =
            try await makePair()
        try await alice.ensureKeys()
        try await bob.ensureKeys()
        // Establish both halves with a full exchange.
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        let inner1 = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        #expect(inner1.count == 1)
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let back = await bobSender.sent
        let inner2 = await alice.decrypt([BasicEvent(
            type: back[0].type, sender: bobUser,
            content: back[0].content)])
        #expect(inner2.count == 1)
        // Redeliver bob's message (retry, dual consume): replay failure
        // must not discard the live session.
        #expect(await alice.decrypt([BasicEvent(
            type: back[0].type, sender: bobUser,
            content: back[0].content)]).isEmpty)
        // Alice's next send still uses the kept session (type 1) and
        // decrypts on bob's side.
        let sentBefore = await aliceSender.sent.count
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(3)],
            to: bobUser, devices: [DeviceId("BOB")])
        let second = await aliceSender.sent
        let fresh = second[sentBefore]
        let freshCipher = fresh.content["ciphertext"]?.objectValue
        let freshType = freshCipher?.values.first?.objectValue?["type"]?.intValue
        #expect(freshType == 1)
        let inner3 = await bob.decrypt([BasicEvent(
            type: fresh.type, sender: aliceUser, content: fresh.content)])
        #expect(inner3.count == 1)
        #expect(inner3[0].content["n"] == .int(3))
    }

    @Test("explicit drop forces a fresh claim")
    func explicitDropForcesFreshClaim() async throws {
        let (alice, bob, _, aliceSender, bobSender, aliceUser, bobUser) =
            try await makePair()
        try await alice.ensureKeys()
        try await bob.ensureKeys()
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        let inner1 = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        #expect(inner1.count == 1)
        await bob.dropSessions(user: aliceUser, device: "ALICE")
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let reply = await bobSender.sent
        let replyCipher = reply[0].content["ciphertext"]?.objectValue
        let replyType = replyCipher?.values.first?.objectValue?["type"]?.intValue
        #expect(replyType == 0)
    }

    @Test("undecryptable type-1 discards the sessions")
    func undecryptableDropsSessions() async throws {
        let (alice, bob, _, aliceSender, bobSender, aliceUser, bobUser) =
            try await makePair()
        try await alice.ensureKeys()
        try await bob.ensureKeys()
        // Establish both halves with a full exchange (reply received
        // on both sides, so later sends are type-1 normal messages).
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender.sent
        let inner1 = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        #expect(inner1.count == 1)
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let back = await bobSender.sent
        let backCipher = back[0].content["ciphertext"]?.objectValue
        let backType = backCipher?.values.first?.objectValue?["type"]?.intValue
        #expect(backType == 1)
        let inner2 = await alice.decrypt([BasicEvent(
            type: back[0].type, sender: bobUser,
            content: back[0].content)])
        #expect(inner2.count == 1)
        // Tamper alice's next (type-1) message: flip a mid-body
        // base64 char (significant bits, so the MAC must fail).
        try await alice.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(3)],
            to: bobUser, devices: [DeviceId("BOB")])
        let second = await aliceSender.sent
        let wire = second[1]
        let wireCipher = wire.content["ciphertext"]?.objectValue
        let wireType = wireCipher?.values.first?.objectValue?["type"]?.intValue
        #expect(wireType == 1)
        var content = wire.content
        var cipher = try #require(content["ciphertext"]?.objectValue)
        let slot = try #require(cipher.keys.first)
        var entry = try #require(cipher[slot]?.objectValue)
        let body = try #require(entry["body"]?.stringValue)
        let flipIndex = body.index(body.startIndex, offsetBy: 10)
        let flipped = body[flipIndex] == "A" ? "B" : "A"
        entry["body"] = .string(
            String(body[..<flipIndex]) + String(flipped)
                + String(body[body.index(after: flipIndex)...]))
        cipher[slot] = .object(entry)
        content["ciphertext"] = .object(cipher)
        #expect(await bob.decrypt([BasicEvent(
            type: wire.type, sender: aliceUser, content: content)]).isEmpty)
        // Bob's poisoned half is gone: his next send re-claims (type 0)
        // and decrypts on alice's side.
        let sentBefore = await bobSender.sent.count
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(4)],
            to: aliceUser, devices: [DeviceId("ALICE")])
        let reply = await bobSender.sent
        let fresh = reply[sentBefore]
        let replyCipher = fresh.content["ciphertext"]?.objectValue
        let replyEntry = replyCipher?.values.first?.objectValue
        #expect(replyEntry?["type"]?.intValue == 0)
        let inner = await alice.decrypt([BasicEvent(
            type: fresh.type, sender: bobUser,
            content: fresh.content)])
        #expect(inner.count == 1)
        #expect(inner[0].content["n"] == .int(4))
    }

    @Test("sessions never cross between local devices of one user")
    func sessionsScopedPerDevice() async throws {
        let (aliceUser, bobUser) = try users()
        let keys = FakeKeys()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyStore(directory: dir)
        // First local device establishes a two-way session with bob
        // (reply received, so the session is established, not fresh).
        let aliceSender1 = FakeSender()
        let alice1 = OlmConnector(
            keys: keys, sender: aliceSender1, keystore: store)
        try await alice1.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE1"))
        try await alice1.ensureKeys()
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        try await alice1.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(1)],
            to: bobUser, devices: [DeviceId("BOB")])
        let first = await aliceSender1.sent
        _ = await bob.decrypt([BasicEvent(
            type: first[0].type, sender: aliceUser,
            content: first[0].content)])
        try await bob.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(2)],
            to: aliceUser, devices: [DeviceId("ALICE1")])
        // Second local device, same user and store: first contact
        // with bob must be a pre-key message, never a reuse of the
        // first device's established session (which the peer would
        // silently drop as an unknown type-1).
        let aliceSender2 = FakeSender()
        let alice2 = OlmConnector(
            keys: keys, sender: aliceSender2, keystore: store)
        try await alice2.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE2"))
        try await alice2.sendEncrypted(
            eventType: "m.secret.send",
            content: ["n": .int(3)],
            to: bobUser, devices: [DeviceId("BOB")])
        let second = await aliceSender2.sent
        #expect(second.count == 1)
        let cipher = second[0].content["ciphertext"]?.objectValue
        let entry = cipher?.values.first?.objectValue
        #expect(entry?["type"]?.intValue == 0)
        let inner = await bob.decrypt([BasicEvent(
            type: second[0].type, sender: aliceUser,
            content: second[0].content)])
        #expect(inner.count == 1)
        #expect(inner[0].content["n"] == .int(3))
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
