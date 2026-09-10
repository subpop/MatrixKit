import Foundation
import Testing

@testable import MatrixKit

@Suite("Spaces")
@MainActor
struct SpacesTests {
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
                roomId: RoomId(unchecked: "!\(id):x"), order: "same", via: ["x"],
                originServerTs: 5)
        }
        let ordered = SpacesClient.orderedChildren([edge("z"), edge("a"), edge("m")])
        #expect(ordered.map(\.roomId.value) == ["!a:x", "!m:x", "!z:x"])
    }

    @Test("Order hints follow the spec's character range")
    func orderValidation() {
        let valid = SpaceChildContent(via: ["x"], order: "hello")
        #expect(valid.validOrder == "hello")
        let space = SpaceChildContent(via: ["x"], order: " ")
        #expect(space.validOrder == " ")
        let over50 = SpaceChildContent(
            via: ["x"], order: String(repeating: "a", count: 51))
        #expect(over50.validOrder == nil)
        let nonAscii = SpaceChildContent(via: ["x"], order: "h\u{00E9}llo")
        #expect(nonAscii.validOrder == nil)
        let control = SpaceChildContent(via: ["x"], order: "a\u{00} b")
        #expect(control.validOrder == nil)
    }

    @Test("Join rules parse known values")
    func joinRules() {
        #expect(SpaceChildJoinRule.parse("public") == .public)
        #expect(SpaceChildJoinRule.parse("knock") == .knock)
        #expect(SpaceChildJoinRule.parse("invite") == .invite)
        #expect(SpaceChildJoinRule.parse("restricted") == .restricted)
        #expect(SpaceChildJoinRule.parse("knock_restricted") == .knockRestricted)
        #expect(SpaceChildJoinRule.parse("bogus") == nil)
        #expect(SpaceChildJoinRule.parse(nil) == nil)
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

    @Test("Parent claims validate against child edges or sender power")
    func isValidParent() {
        let roomId = RoomId(unchecked: "!room:x")
        let sender = UserId(unchecked: "@admin:x")
        let spaceId = RoomId(unchecked: "!space:x")
        let power: [String: AnyCodable] = [
            "users": .object(["@admin:x": .int(100)]),
            "state_default": .int(50),
            "users_default": .int(0),
        ]
        let none: [String: AnyCodable] = [
            "users": .object(["@admin:x": .int(0)]),
            "state_default": .int(50),
        ]
        // A matching child edge alone suffices, with no power data.
        #expect(SpacesClient.isValidParent(
            roomId: roomId, sender: sender, parentSpaceId: spaceId,
            knownChildIds: [roomId], knownIsSpace: true, knownPowerLevels: nil))
        // Not a space: never valid, even with a claimed child edge.
        #expect(!SpacesClient.isValidParent(
            roomId: roomId, sender: sender, parentSpaceId: spaceId,
            knownChildIds: [roomId], knownIsSpace: false, knownPowerLevels: nil))
        // No edge but sender power suffices.
        #expect(SpacesClient.isValidParent(
            roomId: roomId, sender: sender, parentSpaceId: spaceId,
            knownChildIds: [], knownIsSpace: true, knownPowerLevels: power))
        // No edge and insufficient power: invalid.
        #expect(!SpacesClient.isValidParent(
            roomId: roomId, sender: sender, parentSpaceId: spaceId,
            knownChildIds: [], knownIsSpace: true, knownPowerLevels: none))
        // Uninspected space (no edge, no power data): assumed invalid.
        #expect(!SpacesClient.isValidParent(
            roomId: roomId, sender: sender, parentSpaceId: spaceId,
            knownChildIds: [], knownIsSpace: true, knownPowerLevels: nil))
    }

    @Test("Child management needs the state threshold")
    func canManage() {
        let levels: [String: AnyCodable] = [
            "users": .object(["@admin:x": .int(100), "@mod:x": .int(50)]),
            "state_default": .int(50),
            "users_default": .int(0),
        ]
        #expect(SpacesClient.canManageChildren(
            powerLevels: levels, userId: UserId(unchecked: "@admin:x")))
        #expect(SpacesClient.canManageChildren(
            powerLevels: levels, userId: UserId(unchecked: "@mod:x")))
        #expect(!SpacesClient.canManageChildren(
            powerLevels: levels, userId: UserId(unchecked: "@pleb:x")))
    }

    @Test("Per-event thresholds apply")
    func perEventThreshold() {
        let levels: [String: AnyCodable] = [
            "users": .object(["@mod:x": .int(50)]),
            "state_default": .int(50),
            "events": .object(["m.space.child": .int(100)]),
        ]
        #expect(!SpacesClient.canManageChildren(
            powerLevels: levels, userId: UserId(unchecked: "@mod:x")))
    }
}
