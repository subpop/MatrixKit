#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// Fetch-based reads over the normalized store: room entries with
/// display-name fallbacks, detail, timeline windows, members, cursors —
/// plus the combined `MatrixClient` marker-heal pass serving both
/// stores from one fetch.
@Suite("StoreReader")
@MainActor
struct StoreReaderTests {
    // MARK: - Tables

    struct DisplayNameCase: Sendable {
        var id: String
        var name: String?
        var members: [String]
        var expected: String
    }

    nonisolated static let displayNameCases: [DisplayNameCase] = [
        DisplayNameCase(
            id: "explicit", name: "General", members: ["@alice:x"],
            expected: "General"),
        DisplayNameCase(
            id: "member-fallback", name: nil,
            members: ["@alice:x", "@me:x"], expected: "@alice:x"),
        DisplayNameCase(
            id: "room-id-fallback", name: nil, members: [],
            expected: "!room:x"),
    ]

    // MARK: - Helpers

    private func writer() throws -> (MatrixStoreWriter, ModelContainer) {
        let container = try MatrixStore.makeInMemory()
        return (MatrixStoreWriter(modelContainer: container), container)
    }

    private func reader(
        _ container: ModelContainer
    ) -> MatrixStoreReader {
        MatrixStoreReader(
            modelContainer: container,
            localUser: UserId(unchecked: "@me:x"))
    }

    // MARK: - Tests

    @Test("Display names fall back like the actor", arguments: displayNameCases)
    func displayNames(_ row: DisplayNameCase) async throws {
        let (writer, container) = try writer()
        var state: [MessageEvent] = []
        if let name = row.name {
            state.append(stateEvent(
                type: "m.room.name", content: ["name": .string(name)]))
        }
        for (index, user) in row.members.enumerated() {
            state.append(memberStateEvent(
                user, membership: "join", id: "$m\(index)"))
        }
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(state: state)]))
        let entries = try reader(container).roomEntries()
        #expect(entries.joined.map(\.displayName) == [row.expected])
    }

    @Test("Entries split joined and invited, sorted by name")
    func entries() async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [
                RoomId(unchecked: "!b:x"): JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.name",
                        content: ["name": .string("Zebra")])
                ]),
                RoomId(unchecked: "!a:x"): JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.name",
                        content: ["name": .string("Alpha")])
                ]),
            ],
            invited: [
                RoomId(unchecked: "!c:x"): InvitedRoomDelta(
                    events: [
                        StrippedStateEvent(
                            type: "m.room.name", stateKey: "",
                            sender: UserId(unchecked: "@alice:x"),
                            content: ["name": .string("Invite")])
                    ],
                    inviter: UserId(unchecked: "@alice:x"))
            ]))
        let (joined, invited) = try reader(container).roomEntries()
        #expect(joined.map(\.displayName) == ["Alpha", "Zebra"])
        #expect(invited.map(\.displayName) == ["Invite"])
        #expect(invited.first?.membership == .invite)
    }

    @Test("Detail carries counts, markers, and flags")
    func detail() async throws {
        let (writer, container) = try writer()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(
                timeline: [unreadMessage("a", ts: 10)],
                prevBatch: BatchToken("p1"),
                state: [
                    memberStateEvent(
                        "@alice:x", membership: "join",
                        displayname: "Alice")
                ],
                unreadCount: 4,
                highlightCount: 2)]))
        let detail = try #require(try reader(container).roomDetail(
            RoomId(unchecked: "!room:x")))
        #expect(detail.unread == 4)
        #expect(detail.highlight == 2)
        #expect(detail.prevBatch == "p1")
        #expect(detail.memberCount == 1)
        #expect(detail.membership == .join)
        #expect(try reader(container).roomDetail(
            RoomId(unchecked: "!missing:x")) == nil)
    }

    @Test("Timeline limit returns the newest window oldest-first")
    func timelineLimit() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta(
            (1...5).map { unreadMessage("e\($0)", ts: $0) }))
        let roomId = RoomId(unchecked: "!room:x")
        let full = try reader(container).timeline(roomId)
        #expect(full.map(\.eventId.value) == ["$e1", "$e2", "$e3", "$e4", "$e5"])
        let window = try reader(container).timeline(roomId, limit: 2)
        #expect(window.map(\.eventId.value) == ["$e4", "$e5"])
    }

    @Test("Members sort by user ID with profiles")
    func members() async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(state: [
                memberStateEvent(
                    "@bob:x", membership: "join", displayname: "Bob",
                    id: "$m1"),
                memberStateEvent(
                    "@alice:x", membership: "join", displayname: "Alice",
                    id: "$m2"),
            ])]))
        let members = try reader(container).members(
            RoomId(unchecked: "!room:x"))
        #expect(members.map(\.userId.value) == ["@alice:x", "@bob:x"])
        #expect(members.first?.displayname == "Alice")
    }

    @Test("Cursors report both engines' positions")
    func cursors() async throws {
        let (writer, container) = try writer()
        let cursors = try reader(container).syncCursors()
        #expect(cursors.syncToken == nil)
        try await writer.apply(joinedTimelineDelta([], nextBatch: "s7"))
        try await writer.applySliding(joinedTimelineDelta([], nextBatch: "p3"))
        let moved = try reader(container).syncCursors()
        #expect(moved.syncToken == "s7")
        #expect(moved.slidingPos == "p3")
    }

    @Test("v2 sync lands in the writer through the real loop")
    func v2Delivery() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "hello")
            await world.stageMessage(body: "world")
            let (sync, _, _, _) = await harness.syncClient()
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            await sync.addDeltaSink(writer)
            let delta = try await sync.syncOnce()
            #expect(delta.nextBatch.value == "s1")
            let events = try await writer.storedEvents(
                roomId: RoomId(unchecked: "!room:test"))
            #expect(events.map(\.eventId.value) == ["$e1:test", "$e2:test"])
            let context = ModelContext(container)
            let meta = try #require(try context.fetch(
                FetchDescriptor<SDStoreMeta>()).first)
            #expect(meta.syncToken == "s1")
        }
    }

    @Test("Sliding sync lands in the writer without touching the v2 cursor")
    func slidingDelivery() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", body: "sliding hello")
            let (sliding, _, _) = await harness.slidingSyncClient()
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            await sliding.addDeltaSink(writer)
            let delta = try await sliding.syncOnce(
                lists: SlidingSyncClient.defaultLists)
            #expect(delta.nextBatch.value == "p1")
            let events = try await writer.storedEvents(
                roomId: RoomId(unchecked: "!a:test"))
            #expect(events.map(\.eventId.value) == ["$e1:test"])
            let context = ModelContext(container)
            let meta = try #require(try context.fetch(
                FetchDescriptor<SDStoreMeta>()).first)
            #expect(meta.slidingPos == "p1")
            #expect(meta.syncToken == nil)
        }
    }

    @Test("Marker heal adopts the fetched timestamp from one fetch")
    func markerHealing() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "first")
            let client = await MatrixClient.restore(
                homeserver: await harness.baseURL,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"),
                accessToken: "harness-token-alice")
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            await client.addDeltaSink(writer)
            client.setMarkerHealer(writer)
            try await client.syncOnce()
            // A marker for an event the sync window never carried.
            let ghost = await world.stageMessage(body: "ghost")
            let roomId = RoomId(unchecked: "!room:test")
            try await writer.setFullyRead(roomId: roomId, eventId: ghost.eventId)
            await client.resolveReadMarkers()
            let context = ModelContext(container)
            let id = roomId.value
            let row = try #require(try context.fetch(
                FetchDescriptor<SDRoom>(
                    predicate: #Predicate { $0.roomId == id })).first)
            #expect(row.readMarkerTs == ghost.originServerTs)
            // …from a single GET event round-trip.
            let fetches = await harness.requests.filter {
                $0.method == "GET" && $0.path.contains("/event/")
            }
            #expect(fetches.count == 1)
        }
    }
}
#endif
