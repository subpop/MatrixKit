import Foundation
import Testing

import MatrixKitTesting

@testable import MatrixKit
@testable import MatrixKitCrypto

private func roomFixture() throws -> (RoomId, UserId, UserId) {
    (
        RoomId(unchecked: "!room:x"),
        UserId(unchecked: "@alice:x"),
        UserId(unchecked: "@bob:x"))
}

private func wirePair() throws -> (
    alice: RoomCrypto, bob: RoomCrypto,
    aliceSharer: FakeSharer, aliceSender: FakeRoomSender
) {
    let (_, _, bobUser) = try roomFixture()
    let aliceSharer = FakeSharer()
    let aliceSender = FakeRoomSender()
    let alice = RoomCrypto(sharer: aliceSharer, sender: aliceSender)
    let bob = RoomCrypto(
        sharer: FakeSharer(), sender: FakeRoomSender())
    return (alice, bob, aliceSharer, aliceSender)
}

@Suite("RoomCrypto")
struct RoomCryptoTests {
    @Test("send produces m.room.encrypted with Megolm fields")
    func sendShape() async throws {
        let (room, _, _) = try roomFixture()
        let (alice, _, _, sender) = try wirePair()
        let eventId = try await alice.sendEncryptedContent(room, MessageContent.markdown("hello"))
        #expect(eventId.value == "$fake1")
        let sent = await sender.sent
        #expect(sent.count == 1)
        #expect(sent[0].type == "m.room.encrypted")
        #expect(sent[0].content["algorithm"] == .string("m.megolm.v1.aes-sha2"))
        #expect(sent[0].content["sender_key"] == .string("SELFEDKEY"))
        #expect(sent[0].content["session_id"]?.stringValue != nil)
        #expect(sent[0].content["ciphertext"]?.stringValue != nil)
    }

    @Test("share, receive, decrypt round trip")
    func roundTrip() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let (alice, bob, aliceSharer, aliceSender) = try wirePair()
        await aliceSharer.setDevices([bobUser.value: ["BOB"]])
        try await alice.shareRoomKey(roomId: room, users: [bobUser])
        let shares = await aliceSharer.shares
        #expect(shares.count == 1)
        #expect(shares[0].user == bobUser.value)
        #expect(shares[0].devices == ["BOB"])
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: shares[0].content))
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("hello megolm"))
        let sent = await aliceSender.sent
        let wire = MessageEvent(
            type: sent[0].type, eventId: EventId(unchecked: "$e1"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: sent[0].content)
        let decrypted = await bob.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.type == "m.room.message")
        #expect(decrypted?.content["body"] == .string("hello megolm"))
        #expect(decrypted?.sender == aliceUser)
    }

    @Test("sender decrypts its own sent events, in order")
    func selfDecrypt() async throws {
        let (room, aliceUser, _) = try roomFixture()
        let (alice, _, _, sender) = try wirePair()
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("hello self"))
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("hello again"))
        let sent = await sender.sent
        #expect(sent.count == 2)
        for (index, body) in ["hello self", "hello again"].enumerated() {
            let wire = MessageEvent(
                type: sent[index].type,
                eventId: EventId(unchecked: "$e\(index)"),
                sender: aliceUser, roomId: room, originServerTs: 1,
                content: sent[index].content)
            let decrypted = await alice.decryptRoomEvent(wire, in: room)
            #expect(decrypted?.type == "m.room.message")
            #expect(decrypted?.content["body"] == .string(body))
            #expect(decrypted?.sender == aliceUser)
        }
    }

    @Test("decrypt without a session returns nil; clear events pass through")
    func noSession() async throws {
        let (room, aliceUser, _) = try roomFixture()
        let (_, bob, _, _) = try wirePair()
        let wire = MessageEvent(
            type: "m.room.encrypted", eventId: EventId(unchecked: "$e"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: [
                "algorithm": .string("m.megolm.v1.aes-sha2"),
                "session_id": .string("unknown"),
                "ciphertext": .string("AAAA"),
            ])
        #expect(await bob.decryptRoomEvent(wire, in: room) == nil)
        let clear = MessageEvent(
            type: "m.room.message", eventId: EventId(unchecked: "$e2"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: ["body": .string("plain")])
        #expect(await bob.decryptRoomEvent(clear, in: room) == clear)
    }

    @Test("malformed room_key is ignored")
    func malformedKey() async throws {
        let (_, aliceUser, _) = try roomFixture()
        let (_, bob, _, _) = try wirePair()
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: ["session_id": .string("x")]))
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room.member", sender: aliceUser, content: [:]))
    }

    @Test("ensureShared shares once; rotate re-arms")
    func ensureSharedOnce() async throws {
        let (room, _, bobUser) = try roomFixture()
        let (alice, _, aliceSharer, _) = try wirePair()
        await aliceSharer.setDevices([bobUser.value: ["BOB"]])
        try await alice.ensureShared(roomId: room, users: [bobUser])
        try await alice.ensureShared(roomId: room, users: [bobUser])
        #expect(await aliceSharer.shares.count == 1)
        await alice.rotateOutbound(roomId: room)
        try await alice.ensureShared(roomId: room, users: [bobUser])
        #expect(await aliceSharer.shares.count == 2)
    }

    @Test("inbound sessions persist across restore")
    func persistence() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let (alice, _, aliceSharer, aliceSender) = try wirePair()
        await aliceSharer.setDevices([bobUser.value: ["BOB"]])
        let keystore = InMemoryKeyStore()
        let bob = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender(),
            keystore: keystore)
        try await alice.shareRoomKey(roomId: room, users: [bobUser])
        let shares = await aliceSharer.shares
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: shares[0].content))
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("persistent"))
        // Fresh actor, same keystore: inbound session restored.
        let revived = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender(),
            keystore: keystore)
        await revived.restore()
        let sent = await aliceSender.sent
        let wire = MessageEvent(
            type: sent[0].type, eventId: EventId(unchecked: "$e9"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: sent[0].content)
        let decrypted = await revived.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.content["body"] == .string("persistent"))
    }

    @Test("megolm share over Olm-encrypted to-device round trips")
    func megolmOverOlm() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let keys = FakeKeys()
        let aliceOut = FakeSender()
        let bobOut = FakeSender()
        let aliceConn = OlmConnector(keys: keys, sender: aliceOut)
        try await aliceConn.configure(
            identity: .generate(), userId: aliceUser,
            deviceId: DeviceId("ALICE"))
        try await aliceConn.ensureKeys()
        let bobConn = OlmConnector(keys: keys, sender: bobOut)
        try await bobConn.configure(
            identity: .generate(), userId: bobUser,
            deviceId: DeviceId("BOB"))
        try await bobConn.ensureKeys()

        let aliceSender = FakeRoomSender()
        let alice = RoomCrypto(sharer: aliceConn, sender: aliceSender)
        let bob = RoomCrypto(
            sharer: bobConn, sender: FakeRoomSender())

        // Share Alice's outbound Megolm session with Bob over Olm,
        // pumping the wire peer-to-peer like the homeserver would.
        try await alice.shareRoomKey(roomId: room, users: [bobUser])
        let fresh = Array(await aliceOut.sent)
        #expect(!fresh.isEmpty)
        for entry in fresh {
            #expect(entry.type == "m.room.encrypted")
        }
        let inners = await bobConn.decrypt(fresh.map {
            BasicEvent(type: $0.type, sender: aliceUser, content: $0.content)
        })
        #expect(inners.count == 1)
        #expect(inners[0].type == "m.room_key")
        await bob.receiveRoomKey(inners[0])

        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("hello over olm-shared key"))
        let sent = await aliceSender.sent
        #expect(sent.count == 1)
        let wire = MessageEvent(
            type: sent[0].type, eventId: EventId(unchecked: "$e1"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: sent[0].content)
        let decrypted = await bob.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.type == "m.room.message")
        #expect(decrypted?.content["body"] == .string("hello over olm-shared key"))
    }

    @Test("unknown session fires one key request; key arrival re-arms")
    func keyRequestOnce() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let alice = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender())
        await alice.setLocalUserId(aliceUser)
        let box = SeenBox()
        await alice.setUnknownSessionHandler({ box.append($0) })
        let wire = MessageEvent(
            type: "m.room.encrypted", eventId: EventId(unchecked: "$e"),
            sender: bobUser, roomId: room, originServerTs: 1,
            content: [
                "session_id": .string("sess1"),
                "ciphertext": .string("AAAA"),
            ])
        #expect(await alice.decryptRoomEvent(wire, in: room) == nil)
        #expect(await alice.decryptRoomEvent(wire, in: room) == nil)
        #expect(box.count == 1)
        #expect(box.first?.sessionId == "sess1")
        #expect(box.first?.sender == bobUser)
        // Own sends never request (self-decrypt is registered at send).
        let ownWire = MessageEvent(
            type: "m.room.encrypted", eventId: EventId(unchecked: "$e2"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: [
                "session_id": .string("sessOwn"),
                "ciphertext": .string("AAAA"),
            ])
        #expect(await alice.decryptRoomEvent(ownWire, in: room) == nil)
        #expect(box.count == 1)
        // Key arrival re-arms: a later re-loss requests again.
        var outbound = MegolmSession.create()
        let blob = try outbound.sessionKey()
        await alice.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: bobUser,
            content: [
                "algorithm": .string("m.megolm.v1.aes-sha2"),
                "room_id": .string(room.value),
                "session_id": .string("sess1"),
                "session_key": .string(
                    Primitives.base64UnpaddedEncode(blob)),
            ]))
        #expect(await alice.claimUnknownSession(
            roomId: room, sessionId: "sess1"))
    }

    @Test("served request ids dedupe")
    func serveDedupe() async throws {
        let (room, _, _) = try roomFixture()
        let alice = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender())
        #expect(await alice.claimServedRequest("r1") == true)
        #expect(await alice.claimServedRequest("r1") == false)
        #expect(RoomCrypto.keyRequestContent(
            requestId: "r1", deviceId: DeviceId("ALICE"),
            roomId: room, sessionId: "s")["requesting_device_id"]
            == .string("ALICE"))
    }

    @Test("shareCurrentSession targets explicit devices")
    func targetedShare() async throws {
        let (room, _, bobUser) = try roomFixture()
        let (alice, _, aliceSharer, _) = try wirePair()
        await aliceSharer.setDevices([bobUser.value: ["BOB", "BOB2"]])
        try await alice.shareCurrentSession(
            roomId: room, to: bobUser, devices: [DeviceId("BOB2")])
        let shares = await aliceSharer.shares
        #expect(shares.count == 1)
        #expect(shares[0].devices == ["BOB2"])
        #expect(shares[0].content["session_id"]?.stringValue != nil)
    }

    @Test("shareRoomKey includes self devices minus the excluded one")
    func selfShare() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let (alice, _, aliceSharer, _) = try wirePair()
        await aliceSharer.setDevices([
            aliceUser.value: ["ALICE", "ALICE2"],
            bobUser.value: ["BOB"],
        ])
        // Own other devices must get the session or they show UTD for
        // our messages; only our current device is skipped.
        try await alice.shareRoomKey(
            roomId: room, users: [aliceUser, bobUser],
            excludingDevice: DeviceId("ALICE"))
        let shares = await aliceSharer.shares
        #expect(shares.count == 2)
        let ownShare = shares.first { $0.user == aliceUser.value }
        #expect(ownShare?.devices == ["ALICE2"])
        #expect(shares.first { $0.user == bobUser.value }?.devices == ["BOB"])
    }

    struct ReceiveOrderCase: Sendable {
        var id: String
        var heldIndex: UInt32?
        var arrivalIndex: UInt32
        var arrivalIsForwarded: Bool
        var badAlgorithm: Bool
        var expectStored: Bool
        var expectDecryptZero: Bool
    }

    static let receiveOrderCases: [ReceiveOrderCase] = [
        ReceiveOrderCase(
            id: "first share stores", heldIndex: nil, arrivalIndex: 5,
            arrivalIsForwarded: false, badAlgorithm: false,
            expectStored: true, expectDecryptZero: false),
        ReceiveOrderCase(
            id: "earlier arrival replaces", heldIndex: 5, arrivalIndex: 0,
            arrivalIsForwarded: false, badAlgorithm: false,
            expectStored: true, expectDecryptZero: true),
        ReceiveOrderCase(
            id: "later arrival kept", heldIndex: 0, arrivalIndex: 5,
            arrivalIsForwarded: false, badAlgorithm: false,
            expectStored: false, expectDecryptZero: true),
        ReceiveOrderCase(
            id: "equal arrival kept", heldIndex: 2, arrivalIndex: 2,
            arrivalIsForwarded: false, badAlgorithm: false,
            expectStored: false, expectDecryptZero: false),
        ReceiveOrderCase(
            id: "forwarded first share stores", heldIndex: nil, arrivalIndex: 2,
            arrivalIsForwarded: true, badAlgorithm: false,
            expectStored: true, expectDecryptZero: false),
        ReceiveOrderCase(
            id: "forwarded earlier replaces", heldIndex: 5, arrivalIndex: 2,
            arrivalIsForwarded: true, badAlgorithm: false,
            expectStored: true, expectDecryptZero: false),
        ReceiveOrderCase(
            id: "forwarded later kept", heldIndex: 0, arrivalIndex: 2,
            arrivalIsForwarded: true, badAlgorithm: false,
            expectStored: false, expectDecryptZero: true),
        ReceiveOrderCase(
            id: "bad algorithm ignored", heldIndex: nil, arrivalIndex: 0,
            arrivalIsForwarded: false, badAlgorithm: true,
            expectStored: false, expectDecryptZero: false),
    ]

    /// Receives keep the earliest session state: a share at or beyond
    /// the held ratchet position never regresses history, and both key
    /// event types follow the same rule.
    @Test("receiveRoomKey keeps the earliest session state", arguments: receiveOrderCases)
    func receiveKeepsEarliest(_ c: ReceiveOrderCase) async throws {
        let (room, aliceUser, _) = try roomFixture()
        // One originator lineage: exports at 0/2/5 plus the index-0
        // wire. Exports capture the pre-wire counter, so each decrypts
        // its own index and everything after it.
        func payload(_ body: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "room_id": room.value,
                "type": "m.room.message",
                "content": ["body": body, "msgtype": "m.text"],
            ])
        }
        var origin = MegolmSession.create()
        let sessionId = origin.id
        let export0 = origin.export()
        let wire0 = try origin.encrypt(payload("zero"))
        _ = try origin.encrypt(payload("one"))
        let export2 = origin.export()
        _ = try origin.encrypt(payload("two"))
        _ = try origin.encrypt(payload("three"))
        _ = try origin.encrypt(payload("four"))
        let export5 = origin.export()
        let blobFor: (UInt32) -> Data = {
            switch $0 {
            case 0: return export0
            case 2: return export2
            default: return export5
            }
        }
        func shareContent(_ blob: Data) -> [String: AnyCodable] {
            [
                "algorithm": .string(RoomCrypto.megolmAlgorithm),
                "room_id": .string(room.value),
                "session_id": .string(sessionId),
                "session_key": .string(
                    Primitives.base64UnpaddedEncode(blob)),
            ]
        }
        let receiver = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender())
        if let held = c.heldIndex {
            let first = await receiver.receiveRoomKey(BasicEvent(
                type: RoomCrypto.roomKeyType, sender: aliceUser,
                content: shareContent(blobFor(held))))
            #expect(first != nil)
        }
        var arrival = shareContent(blobFor(c.arrivalIndex))
        if c.badAlgorithm {
            arrival["algorithm"] = .string("m.olm.v1.curve25519-aes-sha2")
        }
        let arrivalType = c.arrivalIsForwarded
            ? RoomCrypto.forwardedRoomKeyType : RoomCrypto.roomKeyType
        let result = await receiver.receiveRoomKey(BasicEvent(
            type: arrivalType, sender: aliceUser, content: arrival))
        #expect((result != nil) == c.expectStored, "row \(c.id)")
        let wireEvent = MessageEvent(
            type: "m.room.encrypted", eventId: EventId(unchecked: "$e0"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: [
                "session_id": .string(sessionId),
                "ciphertext": .string(
                    Primitives.base64UnpaddedEncode(wire0)),
            ])
        #expect(
            (await receiver.decryptRoomEvent(wireEvent, in: room) != nil)
                == c.expectDecryptZero,
            "row \(c.id)")
    }

    @Test("shareRequestedSession answers the requested session only")
    func shareRequested() async throws {
        let (room, _, bobUser) = try roomFixture()
        let (alice, _, aliceSharer, _) = try wirePair()
        try await alice.shareCurrentSession(
            roomId: room, to: bobUser, devices: [DeviceId("BOB")])
        let sessionId = try #require(await alice.outboundSessionId(for: room))
        let before = await aliceSharer.shares.count
        let served = try await alice.shareRequestedSession(
            roomId: room, sessionId: sessionId, to: bobUser,
            devices: [DeviceId("BOB")])
        #expect(served)
        #expect(await aliceSharer.shares.count == before + 1)
        #expect(
            await aliceSharer.shares.last?.content["session_id"]?.stringValue
                == sessionId)
        // Unknown sessions are not mis-answered with the outbound one.
        let missed = try await alice.shareRequestedSession(
            roomId: room, sessionId: "unknown", to: bobUser,
            devices: [DeviceId("BOB")])
        #expect(!missed)
        #expect(await aliceSharer.shares.count == before + 1)
    }

    @Test("shareRequestedSession forwards inbound sessions via export")
    func forwardInbound() async throws {
        let (room, aliceUser, bobUser) = try roomFixture()
        let carolUser = UserId(unchecked: "@carol:x")
        let aliceSharer = FakeSharer()
        let aliceSender = FakeRoomSender()
        let bobSharer = FakeSharer()
        let alice = RoomCrypto(sharer: aliceSharer, sender: aliceSender)
        let bob = RoomCrypto(sharer: bobSharer, sender: FakeRoomSender())
        let carol = RoomCrypto(
            sharer: FakeSharer(), sender: FakeRoomSender())
        await aliceSharer.setDevices([bobUser.value: ["BOB"]])
        try await alice.shareRoomKey(roomId: room, users: [bobUser])
        let shares = await aliceSharer.shares
        let sessionId = try #require(shares.first?.content["session_id"]?.stringValue)
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: try #require(shares.first).content))
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("forwarded"))
        let sent = await aliceSender.sent
        let wire = MessageEvent(
            type: sent[0].type,
            eventId: EventId(unchecked: "$fwd"),
            sender: aliceUser, roomId: room, originServerTs: 1,
            content: sent[0].content)
        // Bob forwards the inbound session to Carol; Carol decrypts.
        let forwarded = try await bob.shareRequestedSession(
            roomId: room, sessionId: sessionId, to: carolUser,
            devices: [DeviceId("CAROL")])
        #expect(forwarded)
        let bobShares = await bobSharer.shares
        #expect(bobShares.count == 1)
        #expect(bobShares.first?.content["session_id"]?.stringValue == sessionId)
        await carol.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: bobUser,
            content: try #require(bobShares.first).content))
        let decrypted = await carol.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.type == "m.room.message")
        #expect(decrypted?.content["body"] == .string("forwarded"))
    }

    @Test("parser carries the signed OTK count")
    func parserKeyCount() async throws {
        let response = SyncResponse(
            nextBatch: "s1",
            deviceOneTimeKeysCount: ["signed_curve25519": 7])
        #expect(SyncResponseParser.parse(response).signedKeyCount == 7)
        let empty = SyncResponseParser.parse(SyncResponse(nextBatch: "s2"))
        #expect(empty.signedKeyCount == nil)
    }

    @Test("crypto hooks forward the signed OTK count")
    func keyCountHook() async throws {
        let box = CountBox()
        let hooks = SyncCryptoHooks(handleKeyCounts: { box.record($0) })
        let delta = SyncDelta(
            nextBatch: BatchToken("s"), signedKeyCount: 3)
        _ = await applySyncCryptoHooks(hooks, to: delta)
        #expect(box.values == [3])
        _ = await applySyncCryptoHooks(
            hooks, to: SyncDelta(nextBatch: BatchToken("s")))
        #expect(box.values == [3, nil])
    }

    @Test("parser fills device lists")
    func parserDeviceLists() async throws {
        let (_, aliceUser, bobUser) = try roomFixture()
        let response = SyncResponse(
            nextBatch: "s1",
            deviceLists: DeviceLists(
                changed: [aliceUser], left: [bobUser]))
        let delta = SyncResponseParser.parse(response)
        #expect(delta.deviceChanged == [aliceUser])
        #expect(delta.deviceLeft == [bobUser])
        let empty = SyncResponseParser.parse(SyncResponse(nextBatch: "s2"))
        #expect(empty.deviceChanged.isEmpty)
        #expect(empty.deviceLeft.isEmpty)
    }

    @Test("invalidateDevices drops the device cache")
    func invalidateDevices() async throws {
        let (_, aliceUser, bobUser) = try roomFixture()
        let keys = FakeKeys()
        let alice = OlmConnector(keys: keys, sender: FakeSender())
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: aliceUser, deviceId: DeviceId("ALICE"))
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()
        let before = await keys.queryCalls
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
        #expect(await keys.queryCalls == before + 1)
        // Cached: no new query.
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
        #expect(await keys.queryCalls == before + 1)
        await alice.invalidateDevices(for: bobUser)
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
        #expect(await keys.queryCalls == before + 2)
    }
}

extension FakeSharer {
    func setDevices(_ devices: [String: [String]]) {
        self.devices = devices
    }
}

/// Synchronous `@Sendable` box for `@Sendable` handler assertions.
final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RoomCrypto.UnknownSession] = []

    func append(_ item: RoomCrypto.UnknownSession) {
        lock.withLock { items.append(item) }
    }

    var count: Int { lock.withLock { items.count } }
    var first: RoomCrypto.UnknownSession? { lock.withLock { items.first } }
}

/// Synchronous `@Sendable` box for key-count hook assertions.
final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int?] = []

    func record(_ value: Int?) {
        lock.withLock { items.append(value) }
    }

    var values: [Int?] { lock.withLock { items } }
}

@Suite("TimelinePaging")
struct TimelinePagingTests {
    private func message(_ body: String) -> MessageEvent {
        MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$\(body)"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: ["body": .string(body)])
    }

    @Test("paginateBack loads a canned page into the room")
    func paginate() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        await pager.setPage(PaginationChunk(
            start: "p1", end: nil, chunk: [message("a"), message("b")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        #expect(await timeline.canPaginateBack())
        #expect(try await timeline.paginateBack() == 2)
        #expect(await pager.calls == 1)
        #expect(await timeline.events().count == 2)
        // No further cursor: second call is a no-op.
        #expect(try await timeline.paginateBack() == 0)
    }

    @Test("paginateBack applies the decryptor")
    func decryptor() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        await pager.setPage(PaginationChunk(
            start: "p1", end: nil, chunk: [message("cipher")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        await timeline.setDecryptor { event, _ in
            var copy = event
            copy.content["body"] = .string("plain")
            return copy
        }
        #expect(try await timeline.paginateBack() == 1)
        #expect(
            await timeline.events().first?.content["body"]
                == .string("plain"))
    }

    @Test("retryDecryption unlocks stored ciphertext once the key arrives")
    func retryAfterKeyArrival() async throws {
        let (roomId, aliceUser, bobUser) = try roomFixture()
        let (alice, bob, aliceSharer, aliceSender) = try wirePair()
        await aliceSharer.setDevices([bobUser.value: ["BOB"]])
        try await alice.shareRoomKey(roomId: roomId, users: [bobUser])
        _ = try await alice.sendEncryptedContent(roomId, MessageContent.markdown("late key"))
        let sent = await aliceSender.sent
        let wire = MessageEvent(
            type: sent[0].type, eventId: EventId(unchecked: "$late"),
            sender: aliceUser, roomId: roomId, originServerTs: 1,
            content: sent[0].content)
        let clear = MessageEvent(
            type: "m.room.message", eventId: EventId(unchecked: "$clear"),
            sender: aliceUser, roomId: roomId, originServerTs: 2,
            content: ["body": .string("plain")])
        let room = RoomActor(roomId: roomId)
        let stream = await room.updates()
        var iterator = stream.makeAsyncIterator()
        await room.prependHistory([wire, clear], prevBatch: nil)
        // prependHistory's own reset; drain so the next read is ours.
        #expect(await iterator.next() == .timelineReset)
        let decryptor: @Sendable (MessageEvent, RoomId) async -> MessageEvent? = {
            (event: MessageEvent, room: RoomId) in
            await bob.decryptRoomEvent(event, in: room)
        }
        // No session yet: nothing decrypts, no update fires.
        #expect(await room.retryDecryption(decryptor) == 0)
        #expect(await room.timeline.first?.type == "m.room.encrypted")
        // The shared key arrives late (backup restore, room-key share):
        // stored ciphertext decrypts in place and observers rebuild.
        let shares = await aliceSharer.shares
        await bob.receiveRoomKey(BasicEvent(
            type: "m.room_key", sender: aliceUser,
            content: shares[0].content))
        #expect(await room.retryDecryption(decryptor) == 1)
        #expect(await iterator.next() == .timelineReset)
        let events = await room.timeline
        #expect(events[0].type == "m.room.message")
        #expect(events[0].content["body"] == .string("late key"))
        #expect(events[1].type == "m.room.message")
    }

    @Test("reactionEvent finds own reaction for toggling")
    func reactionLookup() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        let target = EventId(unchecked: "$target:x")
        let reaction = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$reaction:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: ["m.relates_to": .object([
                "event_id": .string("$target:x"),
                "rel_type": .string("m.annotation"),
                "key": .string("👍"),
            ])])
        await room.appendLocalEcho(reaction)
        let timeline = Timeline(roomId: roomId, messages: FakePager(), room: room)
        #expect(await timeline.reactionEvent(
            target: target, key: "👍",
            sender: UserId(unchecked: "@alice:x"))?.value == "$reaction:x")
        #expect(await timeline.reactionEvent(
            target: target, key: "👎",
            sender: UserId(unchecked: "@alice:x")) == nil)
        #expect(await timeline.reactionEvent(
            target: target, key: "👍",
            sender: UserId(unchecked: "@bob:x")) == nil)
    }

    @Test("reactionEvent skips redacted reactions")
    func reactionLookupSkipsRedacted() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        let target = EventId(unchecked: "$target:x")
        let reaction = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$reaction:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: ["m.relates_to": .object([
                "event_id": .string("$target:x"),
                "rel_type": .string("m.annotation"),
                "key": .string("👍"),
            ])],
            unsigned: ["redacted_because": .object([
                "event_id": .string("$redaction:x"),
            ])])
        await room.appendLocalEcho(reaction)
        let timeline = Timeline(roomId: roomId, messages: FakePager(), room: room)
        #expect(await timeline.reactionEvent(
            target: target, key: "👍",
            sender: UserId(unchecked: "@alice:x")) == nil)
    }
}

@Suite("MatrixClientEncryption")
struct MatrixClientEncryptionTests {
    @Test("restore + configureEncryption wires hooks without network")
    @MainActor
    func smoke() async throws {
        // Against the harness: well-known adoption + /versions resolve
        // over loopback in milliseconds. Pointing restore at a dead host
        // burns two 30s connect timeouts (the 60s this suite used to take).
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let client = await MatrixClient.restore(
                homeserver: baseURL,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"),
                accessToken: "harness-token-alice")
            #expect(client.isAuthenticated)
            #expect(await client.serverVersions?.supportsVersion(.v1_13) == true)
            await client.configureEncryption()
            try? await client.transport.shutdown()
        }
    }

    @Test("message + device-list models round trip")
    func models() throws {
        let content = MessageContent.text("hi")
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(MessageContent.self, from: data) == content)
        let lists = DeviceLists(
            changed: [UserId(unchecked: "@a:x")], left: nil)
        let listsData = try JSONEncoder().encode(lists)
        #expect(
            try JSONDecoder().decode(DeviceLists.self, from: listsData)
                == lists)
    }
}
