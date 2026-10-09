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

    struct DeltaCase: Sendable {
        var id: String
        var check: @Sendable (SyncDelta) -> Bool
    }

    static let deltaCases: [DeltaCase] = [
        DeltaCase(id: "next batch", check: { $0.nextBatch.value == "s105_106" }),
        DeltaCase(id: "timeline event", check: {
            $0.joined[RoomId(unchecked: "!room1:example.com")]?.timeline.count == 1
        }),
        DeltaCase(id: "limited window", check: {
            let joined = $0.joined[RoomId(unchecked: "!room1:example.com")]
            return joined?.timelineLimited == true && joined?.prevBatch?.value == "s100_101"
        }),
        DeltaCase(id: "state and ephemeral", check: {
            let joined = $0.joined[RoomId(unchecked: "!room1:example.com")]
            return joined?.state.count == 2 && joined?.ephemeral.count == 1
        }),
        DeltaCase(id: "unreads and heroes", check: {
            let joined = $0.joined[RoomId(unchecked: "!room1:example.com")]
            return joined?.unreadCount == 3 && joined?.highlightCount == 1
                && joined?.heroes == [UserId(unchecked: "@bob:example.com")]
        }),
        DeltaCase(id: "invite inviter", check: {
            $0.invited[RoomId(unchecked: "!room2:example.com")]?.inviter
                == UserId(unchecked: "@carol:example.com")
        }),
    ]

    @Test("Decodes a realistic sync payload")
    func decode() throws {
        let response = try decoded()
        #expect(response.nextBatch == "s105_106")
        #expect(response.rooms?.join.count == 1)
        #expect(response.rooms?.invite.count == 1)
    }

    @Test("Parses room deltas", arguments: deltaCases)
    func parseDelta(_ c: DeltaCase) throws {
        #expect(c.check(SyncResponseParser.parse(try decoded())))
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

    @Test("Parser captures room account data for joined and left rooms")
    func parserAccountData() throws {
        let json = """
        {
          "next_batch": "s1",
          "rooms": {
            "join": {"!r:x": {"account_data": {"events": [
                {"type": "m.tag", "content": {"tags": {"m.favourite": {}}}}
            ]}}},
            "leave": {"!l:x": {"account_data": {"events": [
                {"type": "m.tag", "content": {"tags": {}}}
            ]}}}
          }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SyncResponse.self, from: json)
        let delta = SyncResponseParser.parse(response)
        #expect(delta.joined[RoomId(unchecked: "!r:x")]?.accountData.map(\.type) == ["m.tag"])
        #expect(delta.left[RoomId(unchecked: "!l:x")]?.accountData.map(\.type) == ["m.tag"])
    }
}
