import Foundation
import Testing

@testable import MatrixKit
import MatrixKitSQLite

@Suite("SQLiteCache")
struct SQLiteCacheTests {
    private func database() throws -> SQLiteCache {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("store.sqlite")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteCache(database: file)
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
                    prevBatch: "s100_101"
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
        #expect(room.members[UserId(unchecked: "@alice:example.com")]?.displayname == "Alice")

        // And it recomposes a live store.
        let store = StateStore()
        await store.restore(loaded)
        let actor = await store.room(RoomId(unchecked: "!room1:example.com"))
        #expect(await actor.displayName() == "General")
        #expect(await actor.timeline.count == 1)
    }

    @Test("Empty database loads as nil")
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
    }

    @Test("Clear empties the cache")
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
            .appendingPathComponent("store.sqlite")
        // Must not throw despite the missing parents.
        _ = try SQLiteCache(database: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
