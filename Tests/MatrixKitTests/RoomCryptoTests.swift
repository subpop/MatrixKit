import Foundation
import Testing

@testable import MatrixKit
@testable import MatrixKitCrypto

/// In-memory `RoomKeySharer`: serves a fixed device list and records
/// `m.room_key` shares.
actor FakeSharer: RoomKeySharer {
    var devices: [String: [String]] = [:]
    var shares: [(user: String, devices: [String], content: [String: AnyCodable])] = []
    var identity = "SELFEDKEY"

    func deviceIds(for user: UserId) async throws(MatrixError) -> [String] {
        devices[user.value] ?? []
    }

    func sendEncrypted(
        eventType: String, content: [String: AnyCodable],
        to user: UserId, devices: [DeviceId]
    ) async throws(MatrixError) {
        shares.append((user.value, devices.map(\.value), content))
    }

    func identityKey() async throws(MatrixError) -> String { identity }
}

/// In-memory `RoomEventSender`: records sent room events.
actor FakeRoomSender: RoomEventSender {
    var sent: [(room: String, type: String, content: [String: AnyCodable], txn: String)] = []
    private var counter = 0

    func sendEvent(
        _ roomId: RoomId,
        eventType: String,
        content: any Encodable & Sendable,
        transactionId: TransactionId
    ) async throws(MatrixError) -> EventId {
        guard let dict = content as? [String: AnyCodable] else {
            throw .encodingError("FakeRoomSender only handles dict content")
        }
        counter += 1
        sent.append((roomId.value, eventType, dict, transactionId.value))
        return EventId(unchecked: "$fake\(counter)")
    }
}

/// Canned `TimelinePaging`: serves one fixed page per direction plus a
/// configurable event-context window.
actor FakePager: TimelinePaging {
    var page: PaginationChunk<MessageEvent> = PaginationChunk(start: "s")
    var forwardPage: PaginationChunk<MessageEvent> = PaginationChunk(start: "s")
    var calls = 0
    var contextBefore: [MessageEvent] = []
    var contextEvent: MessageEvent?
    var contextAfter: [MessageEvent] = []
    var contextStart: BatchToken?
    var contextEnd: BatchToken?

    func paginate(
        _ roomId: RoomId,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent> {
        calls += 1
        switch direction {
        case .backward: return page
        case .forward: return forwardPage
        }
    }

    func context(
        _ roomId: RoomId,
        eventId: EventId,
        limit: Int
    ) async throws(MatrixError) -> EventContext {
        EventContext(
            roomId: roomId, focusEventId: eventId,
            eventsBefore: contextBefore, event: contextEvent,
            eventsAfter: contextAfter, start: contextStart, end: contextEnd)
    }

    var eventsById: [EventId: MessageEvent] = [:]
    var relationChunk: [MessageEvent] = []
    var relationEnd: String?
    var eventError: MatrixError?
    var relationsError: MatrixError?

    func event(
        _ roomId: RoomId,
        _ eventId: EventId
    ) async throws(MatrixError) -> MessageEvent {
        if let eventError { throw eventError }
        guard let event = eventsById[eventId] else { throw .notAuthenticated }
        return event
    }

    func relations(
        _ roomId: RoomId,
        eventId: EventId,
        relType: String,
        eventType: String?,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> RelationsResponse {
        calls += 1
        if let relationsError { throw relationsError }
        return RelationsResponse(
            chunk: relationChunk, nextBatch: relationEnd)
    }

    func setContext(
        before: [MessageEvent], focus: MessageEvent?, after: [MessageEvent],
        start: String?, end: String?
    ) {
        contextBefore = before
        contextEvent = focus
        contextAfter = after
        contextStart = start.map { BatchToken($0) }
        contextEnd = end.map { BatchToken($0) }
    }

    func setForwardPage(_ page: PaginationChunk<MessageEvent>) {
        self.forwardPage = page
    }

    func setEvents(_ events: [EventId: MessageEvent]) {
        self.eventsById = events
    }

    func setRelations(chunk: [MessageEvent], nextBatch: String?) {
        self.relationChunk = chunk
        self.relationEnd = nextBatch
    }

    func setEventError(_ error: MatrixError?) {
        self.eventError = error
    }

    func setRelationsError(_ error: MatrixError?) {
        self.relationsError = error
    }
}

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

extension FakePager {
    func setPage(_ page: PaginationChunk<MessageEvent>) {
        self.page = page
    }
}

@Suite("MatrixClientEncryption")
struct MatrixClientEncryptionTests {
    @Test("restore + configureEncryption wires hooks without network")
    @MainActor
    func smoke() async throws {
        let client = await MatrixClient.restore(
            homeserver: URL(string: "https://matrix.example")!,
            userId: UserId(unchecked: "@alice:x"),
            deviceId: DeviceId("ALICE"),
            accessToken: "token")
        #expect(client.isAuthenticated)
        await client.configureEncryption()
        try? await client.transport.shutdown()
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
