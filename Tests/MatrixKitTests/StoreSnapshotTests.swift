import Foundation
import Testing

@testable import MatrixKit

@Suite("StoreSnapshot")
struct StoreSnapshotTests {
    private func message(_ body: String, id: String = "$e") -> MessageEvent {
        MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: "@alice:example.com"),
            originServerTs: 1_700_000_000_000,
            content: ["msgtype": .string("m.text"), "body": .string(body)]
        )
    }

    private func populatedStore() async -> StateStore {
        let store = StateStore()
        let roomId = RoomId(unchecked: "!room1:example.com")
        await store.setLocalUser(UserId(unchecked: "@me:example.com"))
        let room = await store.room(roomId)
        await room.restore(
            RoomSnapshot(
                roomId: roomId,
                name: "General",
                membership: .join,
                members: [
                    UserId(unchecked: "@alice:example.com"): MemberContent(
                        membership: .join, displayname: "Alice")
                ],
                timeline: [message("hello")],
                unreadCount: 3,
                highlightCount: 1,
                prevBatch: "s100_101"
            ))
        await store.setSyncToken("s105_106")
        await store.setAccountData(
            type: "m.push_rules", content: ["global": .string("yes")])
        return store
    }

    @Test("Snapshot round-trips through JSON and restores state")
    func roundTrip() async throws {
        let store = await populatedStore()
        let snapshot = await store.snapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(StoreSnapshot.self, from: data)

        let fresh = StateStore()
        await fresh.restore(decoded)

        #expect(await fresh.syncToken?.value == "s105_106")
        #expect(await fresh.localUser == UserId(unchecked: "@me:example.com"))
        #expect(
            await fresh.getAccountData(type: "m.push_rules")?["global"]
                == .string("yes"))

        let roomId = RoomId(unchecked: "!room1:example.com")
        let room = await fresh.room(roomId)
        #expect(await room.displayName() == "General")
        #expect(await room.membership == .join)
        #expect(await room.timeline.count == 1)
        #expect(await room.unreadCount == 3)
        #expect(await room.highlightCount == 1)
        #expect(await room.prevBatch?.value == "s100_101")
        #expect(
            await room.members[UserId(unchecked: "@alice:example.com")]?
                .displayname == "Alice")
    }

    @Test("Version-mismatched snapshots are ignored")
    func versionMismatch() async {
        let store = StateStore()
        await store.restore(StoreSnapshot(version: 999, rooms: []))
        #expect(await store.syncToken == nil)
        #expect(await store.allRoomIds.isEmpty)
    }

    @Test("Timeline is trimmed to the snapshot window")
    func timelineTrimmed() {
        let events = (0..<250).map { message("m\($0)", id: "$\($0)") }
        let snapshot = RoomSnapshot(
            roomId: RoomId(unchecked: "!r:example.com"), timeline: events)
        #expect(snapshot.timeline.count == RoomSnapshot.maxTimelineEvents)
        #expect(snapshot.timeline.last?.eventId.value == "$249")
    }

    @Test("Hierarchy rows round-trip through JSON and restore state")
    func hierarchyRoundTrip() async throws {
        let spaceId = RoomId(unchecked: "!space:example.com")
        let childId = RoomId(unchecked: "!room:example.com")
        let store = StateStore()
        await store.setHierarchy(
            [
                SpaceChild(
                    roomId: childId, name: "General", memberCount: 42,
                    roomType: .room, isJoined: true, joinRule: .public,
                    childEdges: [
                        SpaceChildEdge(
                            roomId: RoomId(unchecked: "!sub:example.com"),
                            order: "a", via: ["example.com"])
                    ])
            ],
            directChildren: [
                SpaceChildEdge(roomId: childId, via: ["example.com"])
            ],
            nextBatch: BatchToken("t1"),
            for: spaceId)

        let data = try JSONEncoder().encode(await store.snapshot())
        let decoded = try JSONDecoder().decode(StoreSnapshot.self, from: data)

        let fresh = StateStore()
        await fresh.restore(decoded)
        let space = await fresh.room(spaceId)
        let children = await space.hierarchyChildren
        #expect(children.count == 1)
        #expect(children.first?.name == "General")
        #expect(children.first?.memberCount == 42)
        #expect(children.first?.joinRule == .public)
        #expect(children.first?.childEdges.first?.order == "a")
        #expect(await space.hierarchyDirectChildren.map(\.roomId) == [childId])
        #expect(await space.hierarchyNextBatch?.value == "t1")
    }

    @Test("setHierarchy keeps unknown spaces out of joined lists")
    func hierarchyUnknownSpaceMembership() async {
        let store = StateStore()
        let spaceId = RoomId(unchecked: "!space:example.com")
        await store.setHierarchy([], nextBatch: nil, for: spaceId)
        #expect(await store.joinedRoomIds().isEmpty)
        let space = await store.room(spaceId)
        #expect(await space.membership == .leave)
    }
}
