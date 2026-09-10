import Foundation
import Testing

@testable import MatrixKit

/// Sample sync payload covering joined (timeline + state + ephemeral +
/// unread + summary) and invited rooms.
private let sampleSyncJSON = """
    {
      "next_batch": "s105_106",
      "rooms": {
        "join": {
          "!room1:example.com": {
            "timeline": {
              "events": [
                {
                  "type": "m.room.message",
                  "event_id": "$ev1:example.com",
                  "sender": "@alice:example.com",
                  "origin_server_ts": 1700000000000,
                  "content": {"msgtype": "m.text", "body": "hello"}
                }
              ],
              "limited": true,
              "prev_batch": "s100_101"
            },
            "state": {
              "events": [
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
              ]
            },
            "ephemeral": {
              "events": [
                {
                  "type": "m.typing",
                  "content": {"user_ids": ["@bob:example.com"]}
                }
              ]
            },
            "unread_notifications": {"notification_count": 3, "highlight_count": 1},
            "summary": {"m.heroes": ["@bob:example.com"], "m.joined_member_count": 2}
          }
        },
        "invite": {
          "!room2:example.com": {
            "invite_state": {
              "events": [
                {
                  "type": "m.room.member",
                  "state_key": "@me:example.com",
                  "sender": "@carol:example.com",
                  "content": {"membership": "invite", "displayname": "Me"}
                }
              ]
            }
          }
        },
        "leave": {},
        "knock": {}
      }
    }
    """

@Suite("SyncResponseParser")
struct SyncResponseParserTests {
    private func decoded() throws -> SyncResponse {
        try JSONDecoder().decode(
            SyncResponse.self, from: Data(sampleSyncJSON.utf8))
    }

    @Test("Decodes a realistic sync payload")
    func decode() throws {
        let response = try decoded()
        #expect(response.nextBatch == "s105_106")
        #expect(response.rooms?.join.count == 1)
        #expect(response.rooms?.invite.count == 1)
    }

    @Test("Parses joined room deltas")
    func parseJoined() throws {
        let delta = SyncResponseParser.parse(try decoded())
        #expect(delta.nextBatch.value == "s105_106")
        let roomId = RoomId(unchecked: "!room1:example.com")
        let joined = try #require(delta.joined[roomId])
        #expect(joined.timeline.count == 1)
        #expect(joined.timelineLimited)
        #expect(joined.prevBatch?.value == "s100_101")
        #expect(joined.state.count == 2)
        #expect(joined.ephemeral.count == 1)
        #expect(joined.unreadCount == 3)
        #expect(joined.highlightCount == 1)
        #expect(joined.heroes == [UserId(unchecked: "@bob:example.com")])
    }

    @Test("Extracts the inviter from stripped state")
    func parseInvite() throws {
        let delta = SyncResponseParser.parse(try decoded())
        let roomId = RoomId(unchecked: "!room2:example.com")
        let invite = try #require(delta.invited[roomId])
        #expect(invite.inviter == UserId(unchecked: "@carol:example.com"))
    }

    @Test("Encodes SyncFilter as JSON for the filter query param")
    func encodeFilter() throws {
        let filter = SyncFilter(
            room: RoomFilter(timeline: RoomEventFilter(limit: 10)),
            eventFields: ["type", "content"])
        let json = try SyncResponseParser.encodeFilter(filter)
        #expect(json.contains("event_fields"))
        #expect(json.contains("\"limit\":10"))
    }
}

@Suite("StateStore")
struct StateStoreTests {
    private func message(
        _ body: String, sender: String = "@alice:example.com", id: String = "$e"
    ) -> MessageEvent {
        MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: sender),
            originServerTs: 1_700_000_000_000,
            content: ["msgtype": .string("m.text"), "body": .string(body)]
        )
    }

    private func stateEvent(type: String, stateKey: String, content: [String: AnyCodable]) -> MessageEvent {
        MessageEvent(
            type: type,
            eventId: EventId(unchecked: "$s"),
            sender: UserId(unchecked: "@alice:example.com"),
            stateKey: stateKey,
            originServerTs: 1_700_000_000_000,
            content: content
        )
    }

    @Test("Applies joined deltas: name, members, timeline, unreads")
    func applyJoined() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        let delta = SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [message("hi")],
                state: [
                    stateEvent(
                        type: "m.room.name", stateKey: "",
                        content: ["name": .string("General")]),
                    stateEvent(
                        type: "m.room.member", stateKey: "@alice:example.com",
                        content: [
                            "membership": .string("join"),
                            "displayname": .string("Alice"),
                        ]),
                ],
                unreadCount: 2,
                highlightCount: 1
            )]
        )
        await store.apply(delta)
        #expect(await store.syncToken?.value == "s2")
        let room = await store.room(roomId)
        #expect(await room.name == "General")
        #expect(await room.timeline.count == 1)
        #expect(await room.unreadCount == 2)
        #expect(await room.highlightCount == 1)
        let members = await room.members
        #expect(members[UserId(unchecked: "@alice:example.com")]?.displayname == "Alice")
        let info = await room.info()
        #expect(info.name == "General")
    }

    @Test("Limited timeline replaces the window instead of appending")
    func limitedReset() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        await store.apply(
            SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [roomId: JoinedRoomDelta(timeline: [message("old", id: "$old")])]))
        await store.apply(
            SyncDelta(
                nextBatch: BatchToken("s2"),
                joined: [roomId: JoinedRoomDelta(
                    timeline: [message("new", id: "$new")], timelineLimited: true)]))
        let room = await store.room(roomId)
        let timeline = await room.timeline
        #expect(timeline.count == 1)
        #expect(timeline.first?.eventId == EventId(unchecked: "$new"))
    }

    @Test("Invite deltas set membership to invite")
    func applyInvite() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        await store.apply(
            SyncDelta(
                nextBatch: BatchToken("s1"),
                invited: [roomId: InvitedRoomDelta(events: [
                    StrippedStateEvent(
                        type: "m.room.member", stateKey: "@me:example.com",
                        sender: UserId(unchecked: "@carol:example.com"),
                        content: ["membership": .string("invite")])
                ])]))
        let room = await store.room(roomId)
        #expect(await room.membership == .invite)
        #expect(await store.invitedRoomIds() == [roomId])
    }

    @Test("Typing ephemeral updates typing users")
    func typing() async {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!r:example.com")
        // The server echoes our own typing notification (m.typing with our
        // user ID) back via sync; it must not show up as typing.
        await store.room(roomId).setLocalUser(UserId(unchecked: "@me:example.com"))
        let typingEvent = BasicEvent(
            type: "m.typing",
            content: ["user_ids": .array([.string("@bob:example.com"), .string("@me:example.com")])]
        )
        await store.apply(
            SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [roomId: JoinedRoomDelta(ephemeral: [typingEvent])]))
        let room = await store.room(roomId)
        #expect(await room.typingUsers == [UserId(unchecked: "@bob:example.com")])
    }
}
