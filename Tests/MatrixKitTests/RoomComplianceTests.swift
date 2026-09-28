import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Room compliance suite: lifecycle, moderation, members, directory,
/// and aliases against world state.
///
/// Exercised registry endpoints: `POST /createRoom`,
/// `POST /join/{roomIdOrAlias}`, `POST /knock/{roomIdOrAlias}`,
/// `POST /rooms/{roomId}/{leave,forget,invite,kick,ban,unban,upgrade}`,
/// `POST /rooms/{roomId}/report/{eventId}`,
/// `GET /rooms/{roomId}/{members,joined_members,aliases}`,
/// `GET+POST /publicRooms`, `GET+PUT /directory/list/room/{roomId}`,
/// `PUT+DELETE+GET /directory/room/{roomAlias}`,
/// `PUT /rooms/{roomId}/state/{eventType}/`.
@Suite("RoomCompliance")
struct RoomComplianceTests {
    @Test("Create, join by alias, leave, forget lifecycle")
    func lifecycle() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(
                roomAliasName: "general", name: "General"))
            #expect(roomId.value == "!r1:test")
            // Creator is joined; the alias resolves.
            var members = try await rooms.members(roomId)
            #expect(members.map(\.stateKey).contains("@alice:test"))
            #expect(try await rooms.aliases(roomId) == ["#general:test"])
            // Leave then forget.
            try await rooms.leave(roomId)
            members = try await rooms.members(roomId)
            let alice = try #require(members.first { $0.stateKey == "@alice:test" })
            #expect(alice.content.membership == .leave)
            try await rooms.forget(roomId)
            members = try await rooms.members(roomId)
            #expect(!members.map(\.stateKey).contains("@alice:test"))
        }
    }

    @Test("Create with invites seeds membership")
    func createWithInvite() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(
                invite: [UserId(unchecked: "@bob:test")]))
            let members = try await rooms.members(roomId)
            let bob = try #require(members.first { $0.stateKey == "@bob:test" })
            #expect(bob.content.membership == .invite)
            let joined = try await rooms.joinedMembers(roomId)
            #expect(joined[UserId(unchecked: "@alice:test")] != nil)
            #expect(joined[UserId(unchecked: "@bob:test")] == nil)
        }
    }

    enum ModerationOp: Sendable {
        case kick
        case ban
        case unban
    }

    @Test("Moderation sets membership", arguments: [ModerationOp.kick, .ban, .unban])
    func moderation(_ op: ModerationOp) async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest())
            let bob = UserId(unchecked: "@bob:test")
            try await rooms.invite(roomId, user: bob)
            switch op {
            case .kick:
                try await rooms.kick(roomId, user: bob)
            case .ban:
                try await rooms.ban(roomId, user: bob)
            case .unban:
                try await rooms.ban(roomId, user: bob)
                try await rooms.unban(roomId, user: bob)
            }
            let members = try await rooms.members(roomId)
            let record = try #require(members.first { $0.stateKey == "@bob:test" })
            #expect(record.content.membership == (op == .ban ? .ban : .leave))
        }
    }

    @Test("Knock resolves the room")
    func knock() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(roomAliasName: "knockable"))
            let byAlias = try await rooms.knock(RoomAlias(unchecked: "#knockable:test"))
            #expect(byAlias == roomId)
            let byId = try await rooms.knock(roomId)
            #expect(byId == roomId)
        }
    }

    @Test("Unknown rooms report M_NOT_FOUND", arguments: ["join", "leave", "members", "knock"])
    func unknownRooms(_ op: String) async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let ghost = RoomId(unchecked: "!ghost:test")
            let expected = MatrixError.serverError(code: "M_NOT_FOUND", message: "No such room", retryAfter: nil)
            switch op {
            case "join":
                await #expect(throws: expected) { try await rooms.join(ghost) }
            case "leave":
                await #expect(throws: expected) { try await rooms.leave(ghost) }
            case "members":
                await #expect(throws: expected) { _ = try await rooms.members(ghost) }
            case "knock":
                await #expect(throws: expected) { _ = try await rooms.knock(ghost) }
            default:
                Issue.record("unknown op")
            }
        }
    }

    @Test("Upgrade mints a replacement room")
    func upgrade() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let old = try await rooms.create(CreateRoomRequest())
            let new = try await rooms.upgrade(old, newVersion: "11")
            #expect(new != old)
            #expect(try await rooms.members(new).map(\.stateKey).contains("@alice:test"))
        }
    }

    @Test("Report accepts events in known rooms")
    func report() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest())
            try await rooms.report(EventId(unchecked: "$e:test"), in: roomId, score: -50, reason: "spam")
            let ghost = RoomId(unchecked: "!ghost:test")
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such room", retryAfter: nil)) {
                try await rooms.report(EventId(unchecked: "$e:test"), in: ghost)
            }
        }
    }

    @Test("Directory lists, filters, visibility, and aliases round-trip")
    func directory() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let general = try await rooms.create(CreateRoomRequest(
                visibility: .public, roomAliasName: "general", name: "General"))
            _ = try await rooms.create(CreateRoomRequest(name: "Secret"))
            // Unfiltered listing shows both rooms.
            let listed = try await rooms.publicRoomsGet()
            #expect(listed.chunk.count == 2)
            // Server-side filter narrows.
            let (filtered, _) = try await rooms.searchDirectory(query: "General")
            #expect(filtered.map(\.roomId) == [general])
            let (missed, _) = try await rooms.searchDirectory(query: "no-such-room-xyz")
            #expect(missed.isEmpty)
            // Visibility get/set.
            #expect(try await rooms.roomVisibility(general) == .public)
            try await rooms.setRoomVisibility(general, visibility: .private)
            #expect(try await rooms.roomVisibility(general) == .private)
            // Alias publish/resolve/remove.
            let alias = RoomAlias(unchecked: "#lounge:test")
            #expect(try await rooms.isAliasAvailable(alias))
            try await rooms.publishAlias(alias, roomId: general)
            #expect(!(try await rooms.isAliasAvailable(alias)))
            #expect(try await rooms.resolveAlias(alias).roomId == general)
            #expect(try await rooms.aliases(general).contains("#lounge:test"))
            try await rooms.removeAlias(alias)
            #expect(try await rooms.isAliasAvailable(alias))
        }
    }

    @Test("Canonical alias writes to room state")
    func canonicalAlias() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest())
            let alias = RoomAlias(unchecked: "#general:test")
            try await rooms.setCanonicalAlias(roomId: roomId, alias: alias)
            let requests = await harness.requests
            let state = try #require(requests.first {
                $0.method == "PUT" && $0.path.contains("/state/m.room.canonical_alias/")
            })
            #expect(state.hadBearer)
        }
    }

    enum GuardedCall: Sendable {
        case create
        case join
        case leave
        case invite
    }

    @Test("Room calls reject invalid sessions without network", arguments: [GuardedCall.create, .join, .leave, .invite])
    func roomGuards(_ call: GuardedCall) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let rooms = RoomClient(transport: transport, session: session)
        let roomId = RoomId(unchecked: "!r:example.com")
        switch call {
        case .create:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.create(CreateRoomRequest())
            }
        case .join:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.join(roomId) }
        case .leave:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.leave(roomId) }
        case .invite:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.invite(roomId, user: UserId(unchecked: "@b:c"))
            }
        }
        try? await transport.shutdown()
    }

    @Test("Join by alias resolves through the directory")
    func joinByAlias() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(roomAliasName: "general"))
            try await rooms.leave(roomId)
            try await rooms.join(RoomAlias(unchecked: "#general:test"))
            let members = try await rooms.members(roomId)
            #expect(members.first { $0.stateKey == "@alice:test" }?.content.membership == .join)
        }
    }

    @Test("Preview reads state and recent messages")
    func preview() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (rooms, _, _) = await harness.roomClient()
            let (state, _, _) = await harness.roomStateClient()
            let roomId = try await rooms.create(CreateRoomRequest(name: "Preview"))
            _ = try await state.sendStateEvent(
                roomId, type: "m.room.name", content: ["name": .string("Preview")])
            let first = await world.stageMessage(roomId: roomId.value, body: "peek")
            let second = await world.stageMessage(roomId: roomId.value, body: "peek2")
            let preview = try await rooms.preview(roomId)
            #expect(preview.name == "Preview")
            #expect(preview.messages.map(\.eventId.value) == [first.eventId.value, second.eventId.value])
        }
    }
}
