#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// `RoomStateProvider` over the normalized store: summaries, members,
/// space IDs, and hierarchy writes through a real `SpacesClient`.
@Suite("RoomStateProvider")
@MainActor
struct RoomStateProviderTests {
    // MARK: - Tables

    struct SummaryCase: Sendable {
        var id: String
        var expected: RoomStateSummary?
    }

    nonisolated static let summaryCases: [SummaryCase] = [
        SummaryCase(
            id: "member",
            expected: RoomStateSummary(
                membership: .join, name: "General",
                avatarURL: "mxc://x/avatar")),
        SummaryCase(
            id: "space",
            expected: RoomStateSummary(
                membership: .join, isSpace: true,
                spaceChildren: [RoomId(unchecked: "!child:x")],
                powerLevels: ["users_default": .int(0)])),
        SummaryCase(
            id: "leave-keeps-profile",
            expected: RoomStateSummary(membership: .join)),
        SummaryCase(id: "unknown", expected: nil),
    ]

    // MARK: - Helpers

    private func adapter() throws -> (
        MatrixStoreWriter, NormalizedRoomStateProvider
    ) {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        let adapter = NormalizedRoomStateProvider(
            modelContainer: container, writer: writer)
        return (writer, adapter)
    }

    private func deltas(_ id: String) -> [SyncDelta] {
        let roomId = RoomId(unchecked: "!room:x")
        switch id {
        case "member":
            return [SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [roomId: JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.name",
                        content: ["name": .string("General")]),
                    stateEvent(
                        type: "m.room.avatar",
                        content: ["url": .string("mxc://x/avatar")]),
                    memberStateEvent(
                        "@alice:x", membership: "join",
                        displayname: "Alice"),
                ])])]
        case "space":
            return [SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [roomId: JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.create",
                        content: ["type": .string("m.space")]),
                    stateEvent(
                        type: "m.room.power_levels",
                        content: ["users_default": .int(0)]),
                    stateEvent(
                        type: "m.space.child", stateKey: "!child:x",
                        content: ["via": .string("x")]),
                ])])]
        case "leave-keeps-profile":
            return [SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [roomId: JoinedRoomDelta(state: [
                    memberStateEvent(
                        "@alice:x", membership: "join",
                        displayname: "Alice", id: "$m1"),
                    memberStateEvent(
                        "@alice:x", membership: "leave", id: "$m2"),
                ])])]
        default:
            return []
        }
    }

    // MARK: - Tests

    @Test("Adapter serves summaries, members, and space IDs", arguments: summaryCases)
    func summaries(_ row: SummaryCase) async throws {
        let (writer, adapter) = try adapter()
        let roomId = RoomId(unchecked: "!room:x")
        for delta in deltas(row.id) {
            try await writer.apply(delta)
        }
        let actual = await adapter.roomState(roomId)
        #expect(actual == row.expected)
        let member = await adapter.member(
            roomId, userId: UserId(unchecked: "@alice:x"))
        if row.id == "member" {
            #expect(member?.membership == .join)
            #expect(member?.displayname == "Alice")
        } else if row.id == "leave-keeps-profile" {
            // The member left, but the stored profile survived.
            #expect(member?.membership == .leave)
            #expect(member?.displayname == "Alice")
        } else {
            #expect(member == nil)
        }
        let spaces = await adapter.spaceRoomIds()
        #expect(spaces == (row.id == "space" ? [roomId] : []))
    }

    @Test("Hierarchy writes round-trip through the adapter")
    func hierarchy() async throws {
        let (writer, adapter) = try adapter()
        let spaceId = RoomId(unchecked: "!space:x")
        let child = RoomId(unchecked: "!room:x")
        let rows = [
            SpaceChild(
                roomId: child, name: "General", memberCount: 7,
                roomType: .room, isJoined: true, joinRule: .public)
        ]
        let edges = [SpaceChildEdge(roomId: child, via: ["x"])]
        try await adapter.setHierarchy(
            rows, directChildren: edges, nextBatch: BatchToken("t1"),
            for: spaceId)
        #expect(
            await adapter.roomState(spaceId)
                == RoomStateSummary(
                    membership: .leave, hierarchyChildren: rows,
                    hierarchyDirectChildren: edges))
    }

    @Test("SpacesClient caches hierarchy through the adapter")
    func spacesHierarchyCaching() async throws {
        try await withHarness { harness in
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            let adapter = NormalizedRoomStateProvider(
                modelContainer: container, writer: writer)
            let (_, session, transport) = await harness.spacesClient()
            let spaces = SpacesClient(
                transport: transport, session: session, provider: adapter)
            let (rooms, _, _) = await harness.roomClient()
            let space = try await rooms.create(CreateRoomRequest(name: "Space"))
            let child = try await rooms.create(CreateRoomRequest(name: "Child"))
            try await spaces.addChild(child, to: space, via: ["test"])
            let (children, _, _, _) = try await spaces.hierarchy(space)
            #expect(children.map(\.roomId) == [child])
            // And the page landed in the normalized store.
            let reader = MatrixStoreReader(modelContainer: container)
            let summary = try #require(
                try reader.roomStateSummary(space))
            #expect(summary.hierarchyChildren.map(\.roomId) == [child])
            #expect(summary.hierarchyDirectChildren.map(\.roomId) == [child])
        }
    }

    @Test("Editable spaces prefer persisted power levels")
    func editableSpacesPersisted() async throws {
        try await withHarness { harness in
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            let adapter = NormalizedRoomStateProvider(
                modelContainer: container, writer: writer)
            let (_, session, transport) = await harness.spacesClient()
            let spaces = SpacesClient(
                transport: transport, session: session, provider: adapter)
            let spaceId = RoomId(unchecked: "!space:x")
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [spaceId: JoinedRoomDelta(state: [
                    memberStateEvent(
                        "@alice:test", membership: "join", id: "$m"),
                    stateEvent(
                        type: "m.room.power_levels",
                        content: [
                            "users": .object(["@alice:test": .int(100)]),
                            "state_default": .int(50),
                        ]),
                    stateEvent(
                        type: "m.room.create",
                        content: ["type": .string("m.space")]),
                ])]))
            let editable = try await spaces.editableSpaces()
            #expect(editable.map(\.roomId) == [spaceId])
            // Persisted levels skip the per-space getState fan-out.
            let stateFetches = await harness.requests.filter {
                $0.method == "GET" && $0.path.contains("/state")
            }
            #expect(stateFetches.isEmpty)
        }
    }

    @Test("Leave candidates flag last ownership")
    func leaveCandidates() async throws {
        try await withHarness { harness in
            let container = try MatrixStore.makeInMemory()
            let writer = MatrixStoreWriter(modelContainer: container)
            let adapter = NormalizedRoomStateProvider(
                modelContainer: container, writer: writer)
            let (_, session, transport) = await harness.spacesClient()
            let spaces = SpacesClient(
                transport: transport, session: session, provider: adapter)
            let (rooms, _, _) = await harness.roomClient()
            let (state, _, _) = await harness.roomStateClient()
            let space = try await rooms.create(CreateRoomRequest())
            let owned = try await rooms.create(CreateRoomRequest(name: "Owned"))
            let shared = try await rooms.create(CreateRoomRequest(name: "Shared"))
            try await spaces.addChild(owned, to: space, via: ["test"])
            try await spaces.addChild(shared, to: space, via: ["test"])
            _ = try await state.sendStateEvent(
                owned, type: "m.room.power_levels",
                content: ["users": .object(["@alice:test": .int(100)])])
            _ = try await state.sendStateEvent(
                shared, type: "m.room.power_levels",
                content: ["users": .object(["@bob:test": .int(100)])])
            // Both children joined, as a sync would report.
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [
                    owned: JoinedRoomDelta(state: [
                        memberStateEvent(
                            "@alice:test", membership: "join",
                            id: "$m1"),
                    ]),
                    shared: JoinedRoomDelta(state: [
                        memberStateEvent(
                            "@alice:test", membership: "join",
                            id: "$m2"),
                    ]),
                ]))
            let candidates = try await spaces.leaveCandidates(spaceId: space)
            #expect(Set(candidates.map(\.roomId)) == [owned, shared])
            #expect(candidates.first { $0.roomId == owned }?.isLastOwner == true)
            #expect(candidates.first { $0.roomId == shared }?.isLastOwner == false)
        }
    }
}
#endif
