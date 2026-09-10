import Foundation
import Testing

@testable import MatrixKit

@Suite("Directory, search, and aliases")
@MainActor
struct DirectorySearchTests {
    @Test("Directory filter encodes the search term")
    func filterEncode() throws {
        let request = PublicRoomsRequest(
            limit: 10, filter: PublicRoomsFilter(genericSearchTerm: "matrix"))
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(json["filter"]?["generic_search_term"]?.stringValue == "matrix")
        #expect(json["limit"]?.intValue == 10)
    }

    @Test("Directory rows map entries")
    func directoryMapping() {
        let room = DirectoryRoom(entry: PublicRoomEntry(
            roomId: RoomId(unchecked: "!r:x"),
            name: "Room",
            topic: "hi",
            canonicalAlias: "#r:x",
            numJoinedMembers: 42,
            worldReadable: true,
            avatarUrl: "mxc://x/a"))
        #expect(room.roomId.value == "!r:x")
        #expect(room.alias == "#r:x")
        #expect(room.memberCount == 42)
        #expect(room.isWorldReadable)
        #expect(room.avatarURL?.value == "mxc://x/a")
        #expect(!room.isSpace)
    }

    @Test("Alias resolution decodes room and servers")
    func aliasResolution() throws {
        let json = """
        {"room_id": "!r:x", "servers": ["x", "y"]}
        """.data(using: .utf8)!
        let resolution = try JSONDecoder().decode(AliasResolution.self, from: json)
        #expect(resolution.roomId.value == "!r:x")
        #expect(resolution.servers == ["x", "y"])
    }

    @Test("Search response decodes ranks, highlights, and cursors")
    func searchDecode() throws {
        let json = """
        {
            "search_categories": {
                "room_events": {
                    "count": 2,
                    "highlights": ["hello"],
                    "next_batch": "n1",
                    "results": [
                        {"rank": 0.9,
                         "result": {"type": "m.room.message", "event_id": "$a:x",
                                    "sender": "@alice:x", "room_id": "!r:x",
                                    "origin_server_ts": 1000,
                                    "content": {"msgtype": "m.text", "body": "hello"}},
                         "context": {"profile_info": {"@alice:x": {"displayname": "Alice"}}}},
                        {"rank": 0.5,
                         "result": {"type": "m.room.message", "event_id": "$b:x",
                                    "sender": "@bob:x", "room_id": "!r:x",
                                    "origin_server_ts": 2000,
                                    "content": {"msgtype": "m.text", "body": "hello again"}}}
                    ]
                }
            }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SearchResponse.self, from: json)
        let events = try #require(response.searchCategories?.roomEvents)
        #expect(events.count == 2)
        #expect(events.highlights == ["hello"])
        #expect(events.nextBatch == "n1")
        #expect(events.results?.count == 2)
        #expect(events.results?[0].rank == 0.9)
        #expect(events.results?[0].result.roomId?.value == "!r:x")
        #expect(events.results?[0].context?.profileInfo?["@alice:x"]?.displayname == "Alice")
    }

    @Test("Search filter defaults to recent order")
    func filterDefaults() {
        let filter = MessageSearchFilter()
        #expect(filter.orderBy == .recent)
        #expect(filter.roomIds == nil)
        #expect(filter.senderIds == nil)
    }
}
