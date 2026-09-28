import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Spaces compliance suite: hierarchy pages, child/parent management,
/// and parent validation against world state.
///
/// Exercised registry endpoints: `GET /v1/rooms/{roomId}/hierarchy`,
/// `PUT /rooms/{roomId}/state/{eventType}/{stateKey}` (via `RoomStateClient`),
/// `GET /rooms/{roomId}/state`.
@Suite("SpacesCompliance")
struct SpacesComplianceTests {
    @Test("Hierarchy serves the space row plus children")
    func hierarchy() async throws {
        try await withHarness { harness in
            let (spaces, _, _, _) = await harness.spacesClient()
            let (rooms, _, _) = await harness.roomClient()
            let space = try await rooms.create(CreateRoomRequest(name: "Space"))
            let child = try await rooms.create(CreateRoomRequest(name: "Child"))
            try await spaces.addChild(child, to: space, via: ["test"], order: "aa")
            let (children, directIds, edges, next) = try await spaces.hierarchy(space)
            #expect(children.map(\.roomId) == [child])
            #expect(children.first?.name == "Child")
            #expect(directIds == [child])
            #expect(edges.map(\.roomId) == [child])
            #expect(edges.first?.order == "aa")
            #expect(next == nil)
            // Removing the child empties the next page.
            try await spaces.removeChild(child, from: space)
            let (gone, _, _, _) = try await spaces.hierarchy(space)
            #expect(gone.isEmpty)
        }
    }

    @Test("Parents resolve, canonical wins, validation holds")
    func parents() async throws {
        try await withHarness { harness in
            let (spaces, _, _, _) = await harness.spacesClient()
            let (state, _, _) = await harness.roomStateClient()
            let (rooms, _, _) = await harness.roomClient()
            let space = try await rooms.create(CreateRoomRequest())
            let other = try await rooms.create(CreateRoomRequest())
            let child = try await rooms.create(CreateRoomRequest())
            // Flag both parents as spaces, like m.room.create would.
            for parent in [space, other] {
                _ = try await state.sendStateEvent(
                    parent, type: "m.room.create",
                    content: ["type": .string("m.space")])
            }
            try await spaces.addChild(child, to: space, via: ["test"])
            try await spaces.addChild(child, to: other, via: ["test"])
            try await spaces.addParent(space, of: child, via: ["test"], canonical: true)
            try await spaces.addParent(other, of: child, via: ["test"])
            #expect(try await spaces.parents(of: child) == [space, other])
            #expect(try await spaces.canonicalParent(of: child) == space)
            // Both spaces list the child, so both claims validate without
            // power-level inspection.
            #expect(try await spaces.validatedParents(of: child) == [space, other])
        }
    }

    @Test("Editable spaces prefer persisted power levels")
    func editableSpaces() async throws {
        try await withHarness { harness in
            let (spaces, store, _, _) = await harness.spacesClient()
            let (rooms, _, _) = await harness.roomClient()
            let (state, _, _) = await harness.roomStateClient()
            let space = try await rooms.create(CreateRoomRequest())
            // Power levels with alice at 100: manageable from disk.
            _ = try await state.sendStateEvent(
                space, type: "m.room.power_levels",
                content: [
                    "users": .object(["@alice:test": .int(100)]),
                    "state_default": .int(50),
                ])
            _ = try await state.sendStateEvent(
                space, type: "m.room.create",
                content: ["type": .string("m.space")])
            // Seed the suite store (membership + state) as a sync would.
            func stateEvent(type: String, content: [String: AnyCodable]) -> MessageEvent {
                MessageEvent(
                    type: type,
                    eventId: EventId(unchecked: "$s:\(type)"),
                    sender: UserId(unchecked: "@alice:test"),
                    stateKey: type == "m.room.member" ? "@alice:test" : "",
                    originServerTs: 1,
                    content: content)
            }
            await store.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [space: JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.member",
                        content: ["membership": .string("join")]),
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
            #expect(editable.map(\.roomId) == [space])
        }
    }

    @Test("Leave candidates flag last ownership")
    func leaveCandidates() async throws {
        try await withHarness { harness in
            let (spaces, store, _, _) = await harness.spacesClient()
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
            // Both children joined in the suite store.
            func member(_ user: String) -> MessageEvent {
                MessageEvent(
                    type: "m.room.member",
                    eventId: EventId(unchecked: "$m:\(user)"),
                    sender: UserId(unchecked: user),
                    stateKey: user,
                    originServerTs: 1,
                    content: ["membership": .string("join")])
            }
            await store.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                joined: [
                    owned: JoinedRoomDelta(state: [member("@alice:test")]),
                    shared: JoinedRoomDelta(state: [member("@alice:test")]),
                ]))
            let candidates = try await spaces.leaveCandidates(spaceId: space)
            #expect(Set(candidates.map(\.roomId)) == [owned, shared])
            #expect(candidates.first { $0.roomId == owned }?.isLastOwner == true)
            #expect(candidates.first { $0.roomId == shared }?.isLastOwner == false)
        }
    }

    @Test("Space calls reject invalid sessions without network", arguments: [true, false])
    func spacesGuards(managing: Bool) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let spaces = SpacesClient(
            transport: transport, session: session, store: StateStore())
        let space = RoomId(unchecked: "!s:example.com")
        let child = RoomId(unchecked: "!c:example.com")
        if managing {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await spaces.addChild(child, to: space)
            }
        } else {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await spaces.parents(of: child)
            }
        }
        try? await transport.shutdown()
    }
}
