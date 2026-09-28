import Foundation
import Testing

@testable import MatrixKit

@Suite("Spaces")
@MainActor
struct SpacesTests {
    /// Named power-level fixtures for parent/management tables.
    enum PowerFixture: Sendable {
        case admin
        case nobody
        case managers
        case gatedManager

        var levels: [String: AnyCodable] {
            switch self {
            case .admin:
                ["users": .object(["@admin:x": .int(100)]),
                 "state_default": .int(50),
                 "users_default": .int(0)]
            case .nobody:
                ["users": .object(["@admin:x": .int(0)]),
                 "state_default": .int(50)]
            case .managers:
                ["users": .object(["@admin:x": .int(100), "@mod:x": .int(50)]),
                 "state_default": .int(50),
                 "users_default": .int(0)]
            case .gatedManager:
                ["users": .object(["@mod:x": .int(50)]),
                 "state_default": .int(50),
                 "events": .object(["m.space.child": .int(100)])]
            }
        }
    }

    struct ParentCase: Sendable {
        var childIds: [String]
        var isSpace: Bool
        var power: PowerFixture?
        var expected: Bool
    }

    @Test("HierarchyResponse decodes the wire shape")
    func hierarchyDecode() throws {
        let json = """
        {
            "next_batch": "n1",
            "rooms": [
                {"room_id": "!s:x", "room_type": "m.space", "name": "Space",
                 "num_joined_members": 3,
                 "world_readable": true, "guest_can_join": false,
                 "children_state": [
                     {"state_key": "!c:x", "origin_server_ts": 1629413349153,
                      "sender": "@alice:x", "type": "m.space.child",
                      "content": {"via": ["x"], "order": "first",
                                  "suggested": true}}
                 ]},
                {"room_id": "!c:x", "name": "Child", "topic": "hi",
                 "avatar_url": "mxc://x/c", "canonical_alias": "#c:x",
                 "join_rule": "restricted", "num_joined_members": 5,
                 "allowed_room_ids": ["!a:x", "!b:x"], "room_version": "9",
                 "encryption": "m.megolm.v1.aes-sha2"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(HierarchyResponse.self, from: json)
        #expect(response.nextBatch == "n1")
        #expect(response.rooms.count == 2)
        #expect(response.rooms[0].roomType == "m.space")
        #expect(response.rooms[0].worldReadable == true)
        #expect(response.rooms[0].guestCanJoin == false)
        let edge = try #require(response.rooms[0].childrenState?.first)
        #expect(edge.originServerTs == 1_629_413_349_153)
        #expect(edge.sender == UserId(unchecked: "@alice:x"))
        #expect(edge.content.validOrder == "first")
        #expect(edge.content.suggested == true)
        #expect(response.rooms[1].joinRule == "restricted")
        #expect(response.rooms[1].allowedRoomIds == [
            RoomId(unchecked: "!a:x"), RoomId(unchecked: "!b:x")])
        #expect(response.rooms[1].roomVersion == "9")
        #expect(response.rooms[1].encryption == "m.megolm.v1.aes-sha2")
    }

    @Test("Child rows map with join state and counts")
    func mapChild() {
        let dto = HierarchyRoom(
            roomId: RoomId(unchecked: "!c:x"),
            roomType: "m.space",
            name: "Child",
            joinRule: "knock",
            memberCount: 5,
            childrenState: [
                SpaceChildState(
                    stateKey: "!g:x",
                    content: SpaceChildContent(
                        via: ["x"], order: "aa", suggested: true),
                    originServerTs: 100),
                SpaceChildState(stateKey: "!h:x", content: SpaceChildContent(via: [])),
            ],
            worldReadable: true,
            guestCanJoin: false,
            allowedRoomIds: [RoomId(unchecked: "!a:x")],
            roomVersion: "9",
            encryption: "m.megolm.v1.aes-sha2")
        let child = SpacesClient.mapChild(from: dto, isJoined: true)
        #expect(child.roomId.value == "!c:x")
        #expect(child.roomType == .space)
        #expect(child.name == "Child")
        #expect(child.memberCount == 5)
        #expect(child.isJoined)
        #expect(child.childrenCount == 2)
        #expect(child.joinRule == .knock)
        #expect(child.childIds == [
            RoomId(unchecked: "!g:x"), RoomId(unchecked: "!h:x")])
        #expect(child.worldReadable == true)
        #expect(child.guestCanJoin == false)
        #expect(child.allowedRoomIds == [RoomId(unchecked: "!a:x")])
        #expect(child.roomVersion == "9")
        #expect(child.encryption == "m.megolm.v1.aes-sha2")
        #expect(child.childEdges.count == 1)
        #expect(child.childEdges[0].roomId == RoomId(unchecked: "!g:x"))
        #expect(child.childEdges[0].order == "aa")
        #expect(child.childEdges[0].via == ["x"])
        #expect(child.childEdges[0].suggested == true)
        #expect(child.childEdges[0].originServerTs == 100)
    }

    @Test("Space children order per the spec algorithm")
    func orderedChildren() {
        func edge(_ id: String, _ order: String?, _ ts: Int, suggested: Bool = false)
            -> SpaceChildEdge
        {
            SpaceChildEdge(
                roomId: RoomId(unchecked: "!\(id):example.org"),
                order: order,
                via: ["example.org"],
                suggested: suggested,
                originServerTs: ts)
        }
        let ordered = SpacesClient.orderedChildren([
            edge("b", " ", 1_640_341_000_000),
            edge("a", "aaaa", 1_640_141_000_000),
            edge("c", "first", 1_640_841_000_000),
            edge("e", nil, 1_640_641_000_000),
            edge("d", nil, 1_640_741_000_000),
        ])
        #expect(ordered.map { $0.roomId.value } == [
            "!b:example.org", "!a:example.org", "!c:example.org",
            "!e:example.org", "!d:example.org",
        ])
    }

    @Test("Space children tie on room ID when order and time match")
    func orderedChildrenTiebreak() {
        func edge(_ id: String) -> SpaceChildEdge {
            SpaceChildEdge(
                roomId: RoomId(unchecked: "!" + id + ":x"), order: "same", via: ["x"],
                originServerTs: 5)
        }
        let ordered = SpacesClient.orderedChildren([edge("z"), edge("a"), edge("m")])
        #expect(ordered.map(\.roomId.value) == ["!a:x", "!m:x", "!z:x"])
    }

    @Test("Ordered children sort before unordered ones", arguments: [true, false])
    func orderedBeforeUnordered(orderedFirst: Bool) {
        let ordered = SpaceChildEdge(
            roomId: RoomId(unchecked: "!o:x"), order: "x", via: ["x"],
            originServerTs: 2)
        let unordered = SpaceChildEdge(
            roomId: RoomId(unchecked: "!u:x"), order: nil, via: ["x"],
            originServerTs: 1)
        let input = orderedFirst ? [ordered, unordered] : [unordered, ordered]
        #expect(SpacesClient.orderedChildren(input).map(\.roomId.value) == ["!o:x", "!u:x"])
    }

    @Test("Order hints follow the spec's character range", arguments: [
        ("hello", "hello"),
        (" ", " "),
        (String(repeating: "a", count: 51), nil as String?),
        ("h\u{00E9}llo", nil),
        ("a\u{00} b", nil),
    ])
    func orderValidation(order: String, expected: String?) {
        #expect(SpaceChildContent(via: ["x"], order: order).validOrder == expected)
    }

    @Test("Join rules parse known values", arguments: [
        ("public", SpaceChildJoinRule.public),
        ("knock", SpaceChildJoinRule.knock),
        ("invite", SpaceChildJoinRule.invite),
        ("restricted", SpaceChildJoinRule.restricted),
        ("knock_restricted", SpaceChildJoinRule.knockRestricted),
        ("bogus", nil),
        (nil, nil),
    ])
    func joinRules(raw: String?, expected: SpaceChildJoinRule?) {
        #expect(SpaceChildJoinRule.parse(raw) == expected)
    }

    @Test("Parents resolve from m.space.parent state")
    func parents() {
        let state = [
            MessageEvent(
                type: "m.space.parent",
                eventId: EventId(unchecked: "$p:x"),
                sender: UserId(unchecked: "@a:x"),
                stateKey: "!s1:x",
                originServerTs: 1,
                content: ["via": .array([.string("x")])]),
            MessageEvent(
                type: "m.room.name",
                eventId: EventId(unchecked: "$n:x"),
                sender: UserId(unchecked: "@a:x"),
                originServerTs: 1,
                content: ["name": .string("Room")]),
        ]
        #expect(SpacesClient.parents(in: state) == [RoomId(unchecked: "!s1:x")])
    }

    @Test("Canonical parents filter to the flag and tiebreak on room ID")
    func canonical() {
        func parent(_ id: String, canonical: Bool) -> MessageEvent {
            var content: [String: AnyCodable] = ["via": .array([.string("x")])]
            if canonical { content["canonical"] = .bool(true) }
            return MessageEvent(
                type: "m.space.parent",
                eventId: EventId(unchecked: "$\(id):x"),
                sender: UserId(unchecked: "@a:x"),
                stateKey: id,
                originServerTs: 1,
                content: content)
        }
        let state = [parent("!z:x", canonical: true), parent("!a:x", canonical: true),
                     parent("!m:x", canonical: false)]
        #expect(SpacesClient.canonicalParents(in: state) == [
            RoomId(unchecked: "!a:x"), RoomId(unchecked: "!z:x")])
        #expect(SpacesClient.lowestCanonical(
            [RoomId(unchecked: "!z:x"), RoomId(unchecked: "!a:x"),
             RoomId(unchecked: "!m:x")]) == RoomId(unchecked: "!a:x"))
        #expect(SpacesClient.lowestCanonical([]) == nil)
    }

    @Test("Parent claims validate against child edges or sender power", arguments: [
        // A matching child edge alone suffices, with no power data.
        ParentCase(childIds: ["!room:x"], isSpace: true, power: nil, expected: true),
        // Not a space: never valid, even with a claimed child edge.
        ParentCase(childIds: ["!room:x"], isSpace: false, power: nil, expected: false),
        // No edge but sender power suffices.
        ParentCase(childIds: [], isSpace: true, power: .admin, expected: true),
        // No edge and insufficient power: invalid.
        ParentCase(childIds: [], isSpace: true, power: .nobody, expected: false),
        // Uninspected space (no edge, no power data): assumed invalid.
        ParentCase(childIds: [], isSpace: true, power: nil, expected: false),
    ])
    func isValidParent(_ c: ParentCase) {
        #expect(SpacesClient.isValidParent(
            roomId: RoomId(unchecked: "!room:x"),
            sender: UserId(unchecked: "@admin:x"),
            parentSpaceId: RoomId(unchecked: "!space:x"),
            knownChildIds: Set(c.childIds.map { RoomId(unchecked: $0) }),
            knownIsSpace: c.isSpace,
            knownPowerLevels: c.power?.levels) == c.expected)
    }

    @Test("Child management needs the state threshold", arguments: [
        (PowerFixture.managers, "@admin:x", true),
        (PowerFixture.managers, "@mod:x", true),
        (PowerFixture.managers, "@pleb:x", false),
        (PowerFixture.gatedManager, "@mod:x", false),
    ])
    func canManage(levels: PowerFixture, user: String, expected: Bool) {
        #expect(SpacesClient.canManageChildren(
            powerLevels: levels.levels,
            userId: UserId(unchecked: user)) == expected)
    }
}
