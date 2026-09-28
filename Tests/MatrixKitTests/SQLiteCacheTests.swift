import Foundation
import Testing

import MatrixKitTesting
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

    private func snapshot() -> StoreSnapshot {
        populatedSnapshot()
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

    @Test("Garbage file fails to open")
    func garbageFileFailsOpen() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("store.sqlite")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: file)
        #expect(throws: SQLiteError.self) {
            try SQLiteCache(database: file)
        }
    }

    @Test("Room details round-trip through scalar columns")
    func roomDetails() async throws {
        let cache = try database()
        var snap = snapshot()
        snap.rooms[0].topic = "All chat"
        snap.rooms[0].avatarURL = MXCURI(unchecked: "mxc://x/avatar")
        snap.rooms[0].fullyReadEventId = EventId(unchecked: "$read:test")
        try await cache.save(snap)
        let room = try #require(await cache.load()?.rooms.first)
        #expect(room.topic == "All chat")
        #expect(room.avatarURL?.value == "mxc://x/avatar")
        #expect(room.fullyReadEventId == EventId(unchecked: "$read:test"))
    }

    @Test("databaseURL sanitizes the user ID", arguments: [
        ("@alice:example.com", "_alice_example_com"),
        ("@bob:x", "_bob_x"),
    ])
    func databaseURL(userId: String, expected: String) {
        let url = SQLiteCache.databaseURL(for: UserId(unchecked: userId))
        #expect(url?.lastPathComponent == "store.sqlite")
        #expect(url?.deletingLastPathComponent().lastPathComponent == expected)
    }
}
