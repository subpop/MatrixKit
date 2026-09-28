import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Room-state, receipts, and account-data compliance: state CRUD,
/// power-level read-modify-write, typing, receipts, markers, and tags.
///
/// Exercised registry endpoints: `GET /rooms/{roomId}/state`,
/// `GET|PUT /rooms/{roomId}/state/{eventType}[/{stateKey}]`,
/// `PUT /rooms/{roomId}/typing/{userId}`,
/// `POST /rooms/{roomId}/receipt/{receiptType}/{eventId}`,
/// `POST /rooms/{roomId}/read_markers`,
/// `GET|PUT /user/{userId}/account_data/{type}`,
/// `GET|PUT /user/{userId}/rooms/{roomId}/account_data/{type}`,
/// `GET|PUT|DELETE /user/{userId}/rooms/{roomId}/tags[/{tag}]`.
@Suite("StateCompliance")
struct StateComplianceTests {
    @Test("State round-trips through send and fetch")
    func stateRoundTrip() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (state, _, _) = await harness.roomStateClient()
            let room = RoomId(unchecked: "!room:test")
            await world.stageMessage(roomId: room.value, body: "creates the room shell")
            _ = try await state.sendStateEvent(
                room, type: "m.room.name", content: ["name": .string("General")])
            let full = try await state.getState(room)
            #expect(full.map(\.type).contains("m.room.name"))
            let name = try await state.getStateEvent(room, type: "m.room.name")
            #expect(name["name"]?.stringValue == "General")
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such state", retryAfter: nil)) {
                try await state.getStateEvent(room, type: "m.room.topic")
            }
        }
    }

    @Test("Name, topic, and avatar conveniences write state", arguments: ["name", "topic", "avatar"])
    func conveniences(_ field: String) async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (state, _, _) = await harness.roomStateClient()
            let room = RoomId(unchecked: "!room:test")
            await world.stageMessage(roomId: room.value, body: "shell")
            switch field {
            case "name":
                _ = try await state.setName(room, name: "General")
                #expect(try await state.getStateEvent(room, type: "m.room.name")["name"]?.stringValue == "General")
            case "topic":
                _ = try await state.setTopic(room, topic: "All chat")
                #expect(try await state.getStateEvent(room, type: "m.room.topic")["topic"]?.stringValue == "All chat")
            default:
                _ = try await state.setAvatar(room, url: try MXCURI("mxc://test/avatar"))
                #expect(try await state.getStateEvent(room, type: "m.room.avatar")["url"]?.stringValue == "mxc://test/avatar")
            }
            let puts = await harness.requests.filter { $0.method == "PUT" && $0.path.contains("/state/") }
            #expect(puts.count == 1)
            #expect(puts.first?.hadBearer == true)
        }
    }

    @Test("Power levels read-modify-write preserves the room")
    func powerLevels() async throws {
        try await withHarness { harness in
            let (state, _, _) = await harness.roomStateClient()
            let room = RoomId(unchecked: "!room:test")
            _ = try await state.sendStateEvent(
                room, type: "m.room.power_levels",
                content: ["ban": .int(50), "users": .object(["@alice:test": .int(100)])])
            try await state.setMemberPowerLevel(
                room, userId: UserId(unchecked: "@bob:test"), powerLevel: 50)
            let levels = try await state.powerLevels(room)
            #expect(levels["users"]?.objectValue?["@alice:test"]?.intValue == 100)
            #expect(levels["users"]?.objectValue?["@bob:test"]?.intValue == 50)
            #expect(levels["ban"]?.intValue == 50)
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such room", retryAfter: nil)) {
                try await state.powerLevels(RoomId(unchecked: "!ghost:test"))
            }
        }
    }

    @Test("Typing and receipts record server-side")
    func typingAndReceipts() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (state, _, _) = await harness.roomStateClient()
            let room = RoomId(unchecked: "!room:test")
            await world.stageMessage(roomId: room.value, body: "shell")
            let me = UserId(unchecked: "@alice:test")
            try await state.sendTyping(room, userId: me, typing: true)
            #expect(await world.typingUsers(roomId: room.value) == ["@alice:test"])
            try await state.sendTyping(room, userId: me, typing: false)
            #expect(await world.typingUsers(roomId: room.value) == [])
            let event = await world.stageMessage(roomId: room.value, body: "read me")
            try await state.sendReceipt(room, eventId: event.eventId)
            let receipts = await world.recordedReceipts()
            #expect(receipts.count == 1)
            #expect(receipts.first?.type == "m.read")
            #expect(receipts.first?.event == event.eventId.value)
            #expect(receipts.first?.user == "@alice:test")
        }
    }

    @Test("Account data round-trips globally and per room")
    func accountData() async throws {
        try await withHarness { harness in
            let (data, _, _) = await harness.accountDataClient()
            #expect(try await data.get("m.push_rules") == nil)
            try await data.put("m.push_rules", content: ["global": .string("yes")])
            #expect(try await data.get("m.push_rules")?["global"] == .string("yes"))
            let room = RoomId(unchecked: "!room:test")
            #expect(try await data.getRoom(room, "m.fully_read") == nil)
            try await data.putRoom(room, "m.fully_read", content: ["event_id": .string("$e1:test")])
            #expect(try await data.getRoom(room, "m.fully_read")?["event_id"] == .string("$e1:test"))
        }
    }

    @Test("Read markers advance the fully-read event")
    func readMarkers() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (data, _, _) = await harness.accountDataClient()
            let room = RoomId(unchecked: "!room:test")
            await world.stageMessage(roomId: room.value, body: "shell")
            #expect(try await data.fullyRead(room) == nil)
            try await data.setFullyRead(room, eventId: EventId(unchecked: "$e1:test"))
            #expect(try await data.fullyRead(room) == EventId(unchecked: "$e1:test"))
        }
    }

    @Test("Tags add, list, favourite, and delete")
    func tags() async throws {
        try await withHarness { harness in
            let (data, _, _) = await harness.accountDataClient()
            let room = RoomId(unchecked: "!room:test")
            #expect(try await data.tags(room)?.tags.isEmpty == true)
            try await data.addTag(room, "m.favourite", order: 0.5)
            #expect(try await data.tags(room)?.tags["m.favourite"]?.order == 0.5)
            try await data.setFavourite(room, isFavourite: false)
            #expect(try await data.tags(room)?.tags.isEmpty == true)
            // Deleting an absent tag is not an error (idempotent UX).
            try await data.deleteTag(room, "m.favourite")
        }
    }

    @Test("State and account-data calls reject invalid sessions", arguments: [true, false])
    func stateGuards(stateClient: Bool) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let roomId = RoomId(unchecked: "!r:example.com")
        if stateClient {
            let state = RoomStateClient(transport: transport, session: session)
            await #expect(throws: MatrixError.notAuthenticated) {
                try await state.getState(roomId)
            }
        } else {
            let data = AccountDataClient(transport: transport, session: session)
            await #expect(throws: MatrixError.notAuthenticated) {
                try await data.get("m.push_rules")
            }
        }
        try? await transport.shutdown()
    }

    @Test("Ignore list adds, lists, and removes")
    func ignoreList() async throws {
        try await withHarness { harness in
            let (data, _, _) = await harness.accountDataClient()
            #expect(try await data.ignoredUsers().isEmpty)
            try await data.setIgnored(UserId(unchecked: "@spam:test"), ignored: true)
            #expect(try await data.ignoredUsers() == [UserId(unchecked: "@spam:test")])
            try await data.setIgnored(UserId(unchecked: "@spam:test"), ignored: false)
            #expect(try await data.ignoredUsers().isEmpty)
        }
    }
}
