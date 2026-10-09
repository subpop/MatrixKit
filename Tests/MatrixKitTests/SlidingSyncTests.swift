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

    struct RoomCase: Sendable {
        var roomId: String
        var check: @Sendable (SlidingSyncRoom) -> Bool
    }

    static let roomCases: [RoomCase] = [
        RoomCase(roomId: "!room1:example.com", check: { $0.name == "General" }),
        RoomCase(roomId: "!room1:example.com", check: { $0.avatar == "mxc://example.com/abc" }),
        RoomCase(roomId: "!room1:example.com", check: { $0.initial }),
        RoomCase(roomId: "!room1:example.com", check: { $0.requiredState.count == 2 }),
        RoomCase(roomId: "!room1:example.com", check: { $0.timeline.count == 1 }),
        RoomCase(roomId: "!room1:example.com", check: { $0.limited }),
        RoomCase(roomId: "!room1:example.com", check: { $0.prevBatch == "p1" }),
        RoomCase(roomId: "!room1:example.com", check: { $0.unreadCount == 3 }),
        RoomCase(roomId: "!room1:example.com", check: { $0.highlightCount == 1 }),
        RoomCase(roomId: "!room1:example.com", check: { $0.heroes.map(\.userId) == [UserId(unchecked: "@alice:example.com")] }),
        RoomCase(roomId: "!room1:example.com", check: { $0.bumpStamp == 42 }),
        RoomCase(roomId: "!room2:example.com", check: { !$0.initial }),
        RoomCase(roomId: "!room2:example.com", check: { $0.requiredState.isEmpty }),
        RoomCase(roomId: "!room2:example.com", check: { $0.prevBatch == nil }),
        RoomCase(roomId: "!room2:example.com", check: { $0.unreadCount == 0 }),
        RoomCase(roomId: "!room2:example.com", check: { $0.timeline.count == 1 }),
    ]

    @Test("Room payloads decode state, timeline, and metadata", arguments: roomCases)
    func decodeRooms(_ c: RoomCase) throws {
        let response = try decoded()
        let room = try #require(response.rooms[c.roomId])
        #expect(c.check(room))
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
            transport: transport, session: session)
        return (client, transport)
    }

    @Test("Starts idle with no pos")
    func initialState() async {
        let (client, transport) = makeClient()
        #expect(await client.pos == nil)
        #expect(await client.isRunning == false)
        try? await transport.shutdown()
    }

    enum GuardedCall: Sendable {
        case syncOnce
        case start
    }

    @Test("syncOnce and start reject invalid sessions without network", arguments: [GuardedCall.syncOnce, .start])
    func requiresAuth(_ call: GuardedCall) async {
        let (client, transport) = makeClient(accessToken: "")
        switch call {
        case .syncOnce:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await client.syncOnce()
            }
        case .start:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await client.start(lists: [:])
            }
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

    @Test("M_UNKNOWN_POS is classified for connection reset", arguments: [
        (MatrixError.serverError(code: "M_UNKNOWN_POS", message: "expired", retryAfter: nil), true),
        (MatrixError.unknownToken(softLogout: nil), false),
        (MatrixError.serverError(code: "M_FORBIDDEN", message: "no", retryAfter: nil), false),
    ])
    func unknownPos(_ error: MatrixError, expected: Bool) {
        #expect(SlidingSyncClient.isUnknownPos(error) == expected)
    }
}
