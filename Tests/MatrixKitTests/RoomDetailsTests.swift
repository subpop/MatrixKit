import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// `RoomClient.roomDetails`: state walk, membership, permissions.
///
/// Exercised registry endpoints: `GET /rooms/{roomId}/state`,
/// `GET /rooms/{roomId}/members`.
@Suite("RoomDetails")
struct RoomDetailsTests {
    @Test("Details assemble name, members, and defaults")
    func assembles() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let (roomState, _, _) = await harness.roomStateClient()
            let roomId = try await rooms.create(CreateRoomRequest(
                roomAliasName: "general"))
            try await roomState.setName(roomId, name: "General")
            try await roomState.setTopic(roomId, topic: "Lounge")
            _ = try await roomState.sendStateEvent(
                roomId, type: "m.room.power_levels",
                content: [
                    "ban": .int(50), "events_default": .int(0),
                    "invite": .int(0), "kick": .int(50),
                    "redact": .int(50), "state_default": .int(50),
                    "users": .object(["@alice:test": .int(100)]),
                    "users_default": .int(0),
                ])
            try await rooms.invite(
                roomId, user: UserId(unchecked: "@bob:test"))
            let details = try await rooms.roomDetails(
                roomId, localUser: UserId(unchecked: "@alice:test"))
            #expect(details.id == roomId)
            #expect(details.name == "General")
            #expect(details.topic == "Lounge")
            #expect(details.memberCount == 2)
            let byId = Dictionary(
                uniqueKeysWithValues: details.members.map { ($0.userId, $0) })
            #expect(byId[UserId(unchecked: "@alice:test")]?.role == .administrator)
            #expect(byId[UserId(unchecked: "@bob:test")]?.role == .user)
            #expect(details.bannedUserIds.isEmpty)
            #expect(!details.isPublic)
            #expect(details.roomVersion == "1")
            #expect(details.permissions?.canEditName == true)
            #expect(details.powerLevelSettings != nil)
        }
    }

    @Test("Nil local user omits permissions, isDirect passes through")
    func options() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(name: "Room"))
            let anonymous = try await rooms.roomDetails(roomId, localUser: nil)
            #expect(anonymous.permissions == nil)
            #expect(!anonymous.isDirect)
            let direct = try await rooms.roomDetails(
                roomId, localUser: nil, isDirect: true)
            #expect(direct.isDirect)
        }
    }

    @Test("Banned users are reported, not listed")
    func banned() async throws {
        try await withHarness { harness in
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(
                invite: [UserId(unchecked: "@mallory:test")]))
            try await rooms.ban(
                roomId, user: UserId(unchecked: "@mallory:test"))
            let details = try await rooms.roomDetails(
                roomId, localUser: UserId(unchecked: "@alice:test"))
            #expect(details.bannedUserIds == [UserId(unchecked: "@mallory:test")])
            #expect(!details.members.map(\.userId).contains(
                UserId(unchecked: "@mallory:test")))
        }
    }
}
