import Foundation
import Testing

@testable import MatrixKit

/// Sample simplified-sliding-sync response: two rooms (one full initial
/// with required state + limited timeline, one incremental), list metadata
/// with a SYNC op, opaque extensions, and an unknown top-level field.
private let sampleSlidingSyncJSON = """
    {
      "pos": "5",
      "txn_ignored_unknown": {"future": true},
      "lists": {
        "main": {
          "count": 2,
          "ops": [
            {
              "op": "SYNC",
              "range": [0, 1],
              "room_ids": ["!room1:example.com", "!room2:example.com"]
            }
          ]
        }
      },
      "rooms": {
        "!room1:example.com": {
          "name": "General",
          "avatar": "mxc://example.com/abc",
          "initial": true,
          "required_state": [
            {
              "type": "m.room.name",
              "event_id": "$name1:example.com",
              "sender": "@alice:example.com",
              "state_key": "",
              "origin_server_ts": 1699999999000,
              "content": {"name": "General"}
            },
            {
              "type": "m.room.member",
              "event_id": "$mem1:example.com",
              "sender": "@alice:example.com",
              "state_key": "@alice:example.com",
              "origin_server_ts": 1699999998000,
              "content": {"membership": "join", "displayname": "Alice"}
            }
          ],
          "timeline": [
            {
              "type": "m.room.message",
              "event_id": "$ev1:example.com",
              "sender": "@alice:example.com",
              "origin_server_ts": 1700000000000,
              "content": {"msgtype": "m.text", "body": "hello"}
            }
          ],
          "prev_batch": "p1",
          "limited": true,
          "unread_notifications": {"notification_count": 3, "highlight_count": 1},
          "heroes": [{"user_id": "@alice:example.com"}],
          "bump_stamp": 42
        },
        "!room2:example.com": {
          "timeline": [
            {
              "type": "m.room.message",
              "event_id": "$ev2:example.com",
              "sender": "@bob:example.com",
              "origin_server_ts": 1700000001000,
              "content": {"msgtype": "m.text", "body": "incremental"}
            }
          ],
          "limited": false
        }
      },
      "extensions": {
        "typing": {"rooms": {"!room1:example.com": {"user_ids": ["@bob:example.com"]}}},
        "e2ee": {"device_lists": {"changed": ["@alice:example.com"]}},
        "unknown_future": {"x": 1}
      }
    }
    """

@Suite("SlidingSyncModels")
struct SlidingSyncModelsTests {
    private func decoded() throws -> SlidingSyncResponse {
        try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(sampleSlidingSyncJSON.utf8))
    }

    @Test("Decodes pos, lists, rooms, and opaque extensions")
    func decode() throws {
        let response = try decoded()
        #expect(response.pos == "5")
        #expect(response.lists["main"]?.count == 2)
        #expect(response.lists["main"]?.ops.count == 1)
        #expect(response.lists["main"]?.ops.first?.op == "SYNC")
        #expect(response.lists["main"]?.ops.first?.roomIds?.count == 2)
        #expect(response.rooms.count == 2)
        #expect(response.extensions?.keys.contains("e2ee") == true)
    }

    @Test("Decodes room payloads with required state and timeline")
    func decodeRooms() throws {
        let response = try decoded()
        let room = try #require(response.rooms["!room1:example.com"])
        #expect(room.name == "General")
        #expect(room.avatar == "mxc://example.com/abc")
        #expect(room.initial)
        #expect(room.requiredState.count == 2)
        #expect(room.timeline.count == 1)
        #expect(room.limited)
        #expect(room.prevBatch == "p1")
        #expect(room.unreadCount == 3)
        #expect(room.highlightCount == 1)
    }

    @Test("Missing room sections default to empty")
    func decodeDefaults() throws {
        let response = try decoded()
        let room = try #require(response.rooms["!room2:example.com"])
        #expect(!room.initial)
        #expect(room.requiredState.isEmpty)
        #expect(room.prevBatch == nil)
        #expect(room.unreadCount == 0)
    }

    @Test("Decodes heroes and bump_stamp")
    func decodeHeroes() throws {
        let response = try decoded()
        let room = try #require(response.rooms["!room1:example.com"])
        #expect(room.heroes.map { $0.userId } == [UserId(unchecked: "@alice:example.com")])
        #expect(room.bumpStamp == 42)
    }

    @Test("Encodes requests with spec field names")
    func encodeRequest() throws {
        let request = SlidingSyncRequest(
            connId: "c1", pos: "4", timeoutMs: 30_000,
            lists: ["main": SlidingSyncList(
                ranges: [[0, 19]],
                requiredState: [["m.room.name", ""]],
                timelineLimit: 10)],
            roomSubscriptions: [
                "!r:example.com": SlidingSyncRoomSubscription(timelineLimit: 5)]
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"conn_id\":\"c1\""))
        #expect(json.contains("\"pos\":\"4\""))
        #expect(json.contains("\"timeout\":30000"))
        #expect(json.contains("\"ranges\":[[0,19]]"))
        #expect(json.contains("\"required_state\":[[\"m.room.name\",\"\"]]"))
        #expect(json.contains("\"timeline_limit\":10"))
        #expect(json.contains("\"room_subscriptions\""))
    }

    @Test("Response round-trips through Codable")
    func roundTrip() throws {
        let response = try decoded()
        let data = try JSONEncoder().encode(response)
        let redecoded = try JSONDecoder().decode(SlidingSyncResponse.self, from: data)
        #expect(redecoded == response)
    }
}

@Suite("SlidingSyncResponseParser")
struct SlidingSyncResponseParserTests {
    @Test("Maps rooms to joined deltas with pos as nextBatch")
    func parse() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(sampleSlidingSyncJSON.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        #expect(delta.nextBatch.value == "5")
        let roomId = RoomId(unchecked: "!room1:example.com")
        let joined = try #require(delta.joined[roomId])
        #expect(joined.timeline.count == 1)
        #expect(joined.timelineLimited)
        #expect(joined.prevBatch?.value == "p1")
        #expect(joined.state.count == 2)
        #expect(joined.unreadCount == 3)
        #expect(joined.highlightCount == 1)
    }

    @Test("Incremental rooms append without state")
    func parseIncremental() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(sampleSlidingSyncJSON.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        let roomId = RoomId(unchecked: "!room2:example.com")
        let joined = try #require(delta.joined[roomId])
        #expect(!joined.timelineLimited)
        #expect(joined.state.isEmpty)
        #expect(joined.timeline.first?.eventId == EventId(unchecked: "$ev2:example.com"))
    }

    @Test("Empty response parses to pos-only delta")
    func parseEmpty() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(#"{"pos": "0"}"#.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        #expect(delta.nextBatch.value == "0")
        #expect(delta.joined.isEmpty)
    }

    @Test("Typing extension becomes a synthetic m.typing ephemeral event")
    func parseTyping() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(sampleSlidingSyncJSON.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        let roomId = RoomId(unchecked: "!room1:example.com")
        let joined = try #require(delta.joined[roomId])
        let typing = try #require(joined.ephemeral.first(where: { $0.type == "m.typing" }))
        #expect(typing.content["user_ids"]?.arrayValue?.compactMap { $0.stringValue }
            == ["@bob:example.com"])
    }

    @Test("Heroes land in the joined delta")
    func parseHeroes() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self, from: Data(sampleSlidingSyncJSON.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        let roomId = RoomId(unchecked: "!room1:example.com")
        #expect(delta.joined[roomId]?.heroes == [UserId(unchecked: "@alice:example.com")])
    }

    @Test("Typing for rooms outside the rooms map still creates a delta")
    func parseTypingOnlyRoom() throws {
        let response = try JSONDecoder().decode(
            SlidingSyncResponse.self,
            from: Data(#"""
                {"pos": "6", "extensions": {"typing": {"rooms": {
                    "!other:example.com": {"user_ids": []}
                }}}}
                """#.utf8))
        let delta = SlidingSyncResponseParser.parse(response)
        let roomId = RoomId(unchecked: "!other:example.com")
        let joined = try #require(delta.joined[roomId])
        #expect(joined.ephemeral.count == 1)
        #expect(joined.timeline.isEmpty)
    }
}

@Suite("SlidingSyncStateStore")
struct SlidingSyncStateStoreTests {
    @Test("applySliding routes rooms without touching the v2 sync token")
    func applySlidingKeepsToken() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        await store.apply(SyncDelta(nextBatch: BatchToken("s9")))
        #expect(await store.syncToken?.value == "s9")
        await store.applySliding(SyncDelta(
            nextBatch: BatchToken("pos-ignored"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [MessageEvent(
                    type: "m.room.message",
                    eventId: EventId(unchecked: "$e"),
                    sender: UserId(unchecked: "@alice:example.com"),
                    originServerTs: 1_700_000_000_000,
                    content: ["body": .string("hi")])])]))
        #expect(await store.syncToken?.value == "s9")
        let room = await store.room(roomId)
        #expect(await room.timeline.count == 1)
    }

    @Test("Sliding typing ephemeral updates typingUsers")
    func applySlidingTyping() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        var room = JoinedRoomDelta()
        room.ephemeral = [BasicEvent(
            type: "m.typing",
            content: ["user_ids": .array([.string("@bob:example.com")])])]
        await store.applySliding(SyncDelta(nextBatch: BatchToken("1"), joined: [roomId: room]))
        let stored = await store.room(roomId)
        #expect(await stored.typingUsers == [UserId(unchecked: "@bob:example.com")])
    }

    @Test("Limited sliding timelines replace the window")
    func applySlidingLimitedReset() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        func message(_ id: String) -> MessageEvent {
            MessageEvent(
                type: "m.room.message", eventId: EventId(unchecked: id),
                sender: UserId(unchecked: "@alice:example.com"),
                originServerTs: 1_700_000_000_000,
                content: ["body": .string(id)])
        }
        await store.applySliding(SyncDelta(
            nextBatch: BatchToken("1"),
            joined: [roomId: JoinedRoomDelta(timeline: [message("$old")])]))
        await store.applySliding(SyncDelta(
            nextBatch: BatchToken("2"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [message("$new")], timelineLimited: true)]))
        let room = await store.room(roomId)
        let timeline = await room.timeline
        #expect(timeline.count == 1)
        #expect(timeline.first?.eventId == EventId(unchecked: "$new"))
    }
}

@Suite("SlidingSyncClient")
struct SlidingSyncClientTests {
    private func makeClient(accessToken: String = "t") -> (client: SlidingSyncClient, transport: MatrixTransport) {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: accessToken)
        let client = SlidingSyncClient(
            transport: transport, session: session, store: StateStore())
        return (client, transport)
    }

    @Test("Starts idle with no pos")
    func initialState() async {
        let (client, transport) = makeClient()
        #expect(await client.pos == nil)
        #expect(await client.isRunning == false)
        try? await transport.shutdown()
    }

    @Test("syncOnce and start reject invalid sessions without network")
    func requiresAuth() async {
        let (client, transport) = makeClient(accessToken: "")
        await #expect(throws: MatrixError.notAuthenticated) {
            try await client.syncOnce()
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await client.start(lists: [:])
        }
        try? await transport.shutdown()
    }

    @Test("Subscriptions accumulate into the next request")
    func subscriptions() async {
        let (client, transport) = makeClient()
        let roomId = RoomId(unchecked: "!r:example.com")
        await client.subscribe(roomId, timelineLimit: 7)
        var request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.roomSubscriptions["!r:example.com"]?.timelineLimit == 7)
        #expect(request.pos == nil)
        #expect(request.timeoutMs == 1000)
        await client.unsubscribe(roomId)
        request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.roomSubscriptions.isEmpty)
        try? await transport.shutdown()
    }

    @Test("Request before start has no conn_id")
    func requestShape() async {
        let (client, transport) = makeClient()
        let request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.connId == nil)
        #expect(request.lists.isEmpty)
        try? await transport.shutdown()
    }

    @Test("Default sliding lists cover the first window")
    func defaultLists() throws {
        let lists = SlidingSyncClient.defaultLists
        let main = try #require(lists["main"])
        #expect(main.ranges == [[0, 19]])
        #expect(main.timelineLimit > 0)
        #expect(main.requiredState?.contains(["m.room.name", ""]) == true)
    }

    @Test("Default endpoint is the MSC4186 unstable path Synapse serves")
    func defaultEndpoint() {
        #expect(SlidingSyncClient.defaultEndpointPath
            == "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync")
    }

    @Test("Requests always carry the typing extension")
    func typingExtensionDefault() async {
        let (client, transport) = makeClient()
        let request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.extensions?.typing?.enabled == true)
        try? await transport.shutdown()
    }

    @Test("M_UNKNOWN_POS is classified for connection reset")
    func unknownPos() {
        #expect(SlidingSyncClient.isUnknownPos(
            .serverError(code: "M_UNKNOWN_POS", message: "expired", retryAfter: nil)))
        #expect(!SlidingSyncClient.isUnknownPos(.unknownToken))
        #expect(!SlidingSyncClient.isUnknownPos(
            .serverError(code: "M_FORBIDDEN", message: "no", retryAfter: nil)))
    }
}
