#if canImport(SwiftData)
import Foundation
import Testing

@testable import MatrixKit
import MatrixKitSwiftData

@Suite("SwiftDataCache")
struct SwiftDataCacheTests {
    private func database() throws -> SwiftDataCache {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("store.swiftdata")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SwiftDataCache(database: file)
    }

    private func message(_ body: String, id: String = "$e") -> MessageEvent {
        MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: "@alice:example.com"),
            originServerTs: 1_700_000_000_000,
            content: ["msgtype": .string("m.text"), "body": .string(body)]
        )
    }

    private func snapshot() -> StoreSnapshot {
        let roomId = RoomId(unchecked: "!room1:example.com")
        return StoreSnapshot(
            syncToken: "s105_106",
            localUser: UserId(unchecked: "@me:example.com"),
            accountData: ["m.push_rules": ["global": .string("yes")]],
            rooms: [
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
                    prevBatch: "s100_101",
                    notificationMode: .mute
                )
            ]
        )
    }

    @Test("Save/load round-trips the snapshot")
    func roundTrip() async throws {
        let cache = try database()
        try await cache.save(snapshot())

        let loaded = try #require(await cache.load())
        #expect(loaded.syncToken?.value == "s105_106")
        #expect(loaded.localUser == UserId(unchecked: "@me:example.com"))
        #expect(loaded.accountData["m.push_rules"]?["global"] == .string("yes"))
        #expect(loaded.rooms.count == 1)

        let room = try #require(loaded.rooms.first)
        #expect(room.name == "General")
        #expect(room.membership == .join)
        #expect(room.timeline.count == 1)
        #expect(room.unreadCount == 3)
        #expect(room.highlightCount == 1)
        #expect(room.prevBatch?.value == "s100_101")
        #expect(room.notificationMode == .mute)
        #expect(room.members[UserId(unchecked: "@alice:example.com")]?.displayname == "Alice")

        // And it recomposes a live store.
        let store = StateStore()
        await store.restore(loaded)
        let actor = await store.room(RoomId(unchecked: "!room1:example.com"))
        #expect(await actor.displayName() == "General")
        #expect(await actor.timeline.count == 1)
    }

    @Test("Save/load round-trips room flags for list filtering")
    func roomFlags() async throws {
        let cache = try database()
        var snapshot = StoreSnapshot()
        snapshot.rooms = [
            RoomSnapshot(
                roomId: RoomId(unchecked: "!space:x"),
                name: "Work",
                membership: .join,
                isSpace: true,
                isDirect: false,
                isFavourite: false),
            RoomSnapshot(
                roomId: RoomId(unchecked: "!dm:x"),
                membership: .join,
                isEncrypted: true,
                canonicalAlias: "#dm:x",
                successorRoomId: "!dm2:x",
                isSpace: false,
                isDirect: true,
                isFavourite: true),
        ]
        try await cache.save(snapshot)

        let loaded = try #require(await cache.load())
        #expect(loaded.rooms.count == 2)
        let space = loaded.rooms.first { $0.roomId.value == "!space:x" }
        #expect(space?.isSpace == true)
        #expect(space?.isFavourite == false)
        let dm = loaded.rooms.first { $0.roomId.value == "!dm:x" }
        #expect(dm?.isDirect == true)
        #expect(dm?.isFavourite == true)
        #expect(dm?.isEncrypted == true)
        #expect(dm?.canonicalAlias == "#dm:x")
        #expect(dm?.successorRoomId == "!dm2:x")
    }

    @Test("Save/load round-trips the space graph and heroes")
    func spaceGraph() async throws {
        let cache = try database()
        var snapshot = StoreSnapshot()
        snapshot.rooms = [
            RoomSnapshot(
                roomId: RoomId(unchecked: "!space:x"),
                membership: .join,
                members: [:],
                isSpace: true,
                spaceChildren: [RoomId(unchecked: "!room:x")]),
            RoomSnapshot(
                roomId: RoomId(unchecked: "!room:x"),
                membership: .join,
                members: [:],
                spaceParents: [RoomId(unchecked: "!space:x")],
                canonicalParentIds: [RoomId(unchecked: "!space:x")],
                powerLevelsContent: [
                    "events": .object(["m.space.child": .int(50)]),
                    "users_default": .int(0),
                ],
                heroes: [UserId(unchecked: "@alice:x")]),
        ]
        try await cache.save(snapshot)

        let loaded = try #require(await cache.load())
        let space = loaded.rooms.first { $0.roomId.value == "!space:x" }
        #expect(space?.spaceChildren == [RoomId(unchecked: "!room:x")])
        let room = loaded.rooms.first { $0.roomId.value == "!room:x" }
        #expect(room?.spaceParents == [RoomId(unchecked: "!space:x")])
        #expect(room?.canonicalParentIds == [RoomId(unchecked: "!space:x")])
        #expect(room?.powerLevelsContent?["events"]?["m.space.child"]?.intValue == 50)
        #expect(room?.heroes == [UserId(unchecked: "@alice:x")])

        // And restore applies them to live actors.
        let store = StateStore()
        await store.restore(loaded)
        let actor = await store.room(RoomId(unchecked: "!room:x"))
        #expect(await actor.spaceParents == [RoomId(unchecked: "!space:x")])
        #expect(await actor.canonicalParentIds == [RoomId(unchecked: "!space:x")])
    }

    @Test("Save/load round-trips the read marker")
    func readMarker() async throws {
        let cache = try database()
        var snapshot = StoreSnapshot()
        snapshot.rooms = [
            RoomSnapshot(
                roomId: RoomId(unchecked: "!marked:x"),
                membership: .join,
                fullyReadEventId: EventId(unchecked: "$marker"),
                readMarkerTsMs: 1_789_000_000_000),
            RoomSnapshot(
                roomId: RoomId(unchecked: "!unmarked:x"),
                membership: .join),
        ]
        try await cache.save(snapshot)

        let loaded = try #require(await cache.load())
        let marked = loaded.rooms.first { $0.roomId.value == "!marked:x" }
        #expect(marked?.fullyReadEventId == EventId(unchecked: "$marker"))
        #expect(marked?.readMarkerTsMs == 1_789_000_000_000)
        let unmarked = loaded.rooms.first { $0.roomId.value == "!unmarked:x" }
        #expect(unmarked?.readMarkerTsMs == nil)

        // And restore applies the marker to the live actor.
        let store = StateStore()
        await store.restore(loaded)
        let actor = await store.room(RoomId(unchecked: "!marked:x"))
        #expect(await actor.readMarkerTsMs == 1_789_000_000_000)
    }

    @Test("Save/load round-trips cached hierarchy rows")
    func hierarchyRows() async throws {
        let cache = try database()
        let spaceId = RoomId(unchecked: "!space:x")
        let childId = RoomId(unchecked: "!room:x")
        var snapshot = StoreSnapshot()
        snapshot.rooms = [
            RoomSnapshot(
                roomId: spaceId,
                name: "Work",
                membership: .join,
                isSpace: true,
                hierarchyChildren: [
                    SpaceChild(
                        roomId: childId, name: "General", memberCount: 42,
                        roomType: .room, isJoined: true,
                        joinRule: .restricted)
                ],
                hierarchyDirectChildren: [
                    SpaceChildEdge(roomId: childId, via: ["x"])
                ],
                hierarchyNextBatch: BatchToken("t1")),
        ]
        try await cache.save(snapshot)

        let loaded = try #require(await cache.load())
        let space = try #require(
            loaded.rooms.first { $0.roomId == spaceId })
        #expect(space.hierarchyChildren.count == 1)
        #expect(space.hierarchyChildren.first?.name == "General")
        #expect(space.hierarchyChildren.first?.memberCount == 42)
        #expect(space.hierarchyChildren.first?.joinRule == .restricted)
        #expect(space.hierarchyDirectChildren.map(\.roomId) == [childId])
        #expect(space.hierarchyNextBatch?.value == "t1")

        // And restore applies them to the live actor.
        let store = StateStore()
        await store.restore(loaded)
        let actor = await store.room(spaceId)
        #expect(await actor.hierarchyChildren.count == 1)
        #expect(await actor.hierarchyDirectChildren.map(\.roomId) == [childId])
        #expect(await actor.hierarchyNextBatch?.value == "t1")
    }

    @Test("Empty store loads as nil")
    func emptyLoad() async throws {
        #expect(await (try database().load()) == nil)
    }

    @Test("Resaving replaces stale rows")
    func replace() async throws {
        let cache = try database()
        try await cache.save(snapshot())
        try await cache.save(StoreSnapshot(syncToken: "s200", rooms: []))
        let loaded = try #require(await cache.load())
        #expect(loaded.syncToken?.value == "s200")
        #expect(loaded.rooms.isEmpty)
        #expect(loaded.accountData.isEmpty)
    }

    @Test("Clear removes the snapshot")
    func clear() async throws {
        let cache = try database()
        try await cache.save(snapshot())
        try await cache.clear()
        #expect(await cache.load() == nil)
    }

    @Test("Opening creates missing parent directories")
    func createsParentDirectories() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
            .appendingPathComponent("store.swiftdata")
        // Must not throw despite the missing parents.
        _ = try SwiftDataCache(database: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
