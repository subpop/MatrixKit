import Foundation
import Testing

@testable import MatrixKit

private func powerContent(
    users: [String: Int] = [:],
    ban: Int? = nil, kick: Int? = nil, invite: Int? = nil, redact: Int? = nil,
    eventsDefault: Int? = nil, stateDefault: Int? = nil, usersDefault: Int? = nil,
    events: [String: Int] = [:]
) -> [String: AnyCodable] {
    var content: [String: AnyCodable] = [
        "users": .object(Dictionary(
            uniqueKeysWithValues: users.map { ($0.key, AnyCodable.int($0.value)) })),
    ]
    if let ban { content["ban"] = .int(ban) }
    if let kick { content["kick"] = .int(kick) }
    if let invite { content["invite"] = .int(invite) }
    if let redact { content["redact"] = .int(redact) }
    if let eventsDefault { content["events_default"] = .int(eventsDefault) }
    if let stateDefault { content["state_default"] = .int(stateDefault) }
    if let usersDefault { content["users_default"] = .int(usersDefault) }
    if !events.isEmpty {
        content["events"] = .object(Dictionary(
            uniqueKeysWithValues: events.map { ($0.key, AnyCodable.int($0.value)) }))
    }
    return content
}

@Suite("Power levels and permissions")
struct PowerLevelTests {
    @Test("Thresholds parse with spec defaults")
    func parseDefaults() {
        let settings = RoomPowerLevelSettings.parse([:])
        #expect(settings.ban == 50)
        #expect(settings.kick == 50)
        #expect(settings.invite == 0)
        #expect(settings.redact == 50)
        #expect(settings.eventsDefault == 0)
        #expect(settings.stateDefault == 50)
        #expect(settings.usersDefault == 0)
        #expect(settings.roomName == 50)
    }

    @Test("Thresholds parse overrides")
    func parseOverrides() {
        let settings = RoomPowerLevelSettings.parse(powerContent(
            ban: 100, invite: 50,
            events: ["m.room.name": 100]))
        #expect(settings.ban == 100)
        #expect(settings.invite == 50)
        #expect(settings.roomName == 100)
        #expect(settings.roomTopic == 50)
    }

    @Test("Applying preserves users and unrelated keys")
    func applying() {
        var content = powerContent(users: ["@a:x": 100])
        content["notifications"] = .object(["room": .int(50)])
        let updated = RoomPowerLevelSettings(ban: 100, kick: 100).applying(to: content)
        #expect(updated["ban"] == .int(100))
        #expect(updated["kick"] == .int(100))
        #expect(updated["users"]?.objectValue?["@a:x"] == .int(100))
        #expect(updated["notifications"]?.objectValue?["room"] == .int(50))
        #expect(updated["events"]?.objectValue?["m.room.name"] == .int(50))
    }

    @Test("Admins can do everything participants cannot")
    func evaluate() {
        let content = powerContent(
            users: ["@admin:x": 100, "@mod:x": 50],
            ban: 60,
            events: ["m.room.power_levels": 100])
        let admin = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@admin:x"))
        #expect(admin.canBan)
        #expect(admin.canKick)
        #expect(admin.canChangePermissions)
        #expect(admin.canEditName)
        #expect(admin.canSendMessages)

        let mod = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@mod:x"))
        #expect(!mod.canBan)
        #expect(mod.canKick)
        #expect(!mod.canChangePermissions)
        #expect(mod.canEditName)

        let user = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@user:x"))
        #expect(!user.canKick)
        #expect(!user.canEditName)
        #expect(user.canSendMessages)
        #expect(!user.canEditDetails)
        #expect(admin.canEditDetails)
    }

    @Test("Custom thresholds apply")
    func customThresholds() {
        let content = powerContent(users: ["@a:x": 10], invite: 10, eventsDefault: 20)
        let permissions = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@a:x"))
        #expect(permissions.canInvite)
        #expect(!permissions.canSendMessages)
    }

    @Test("Roles bucket power levels")
    func roles() {
        #expect(RoomMemberDetails.Role.of(100) == .administrator)
        #expect(RoomMemberDetails.Role.of(150) == .administrator)
        #expect(RoomMemberDetails.Role.of(50) == .moderator)
        #expect(RoomMemberDetails.Role.of(0) == .user)
    }
}

@Suite("Ignore list")
struct IgnoreListTests {
    @Test("Ignore edits preserve other users")
    func ignore() {
        let content: [String: AnyCodable] = [
            "ignored_users": .object(["@spam:x": .object([:])]),
        ]
        let added = AccountDataClient.ignoredList(
            in: content, userId: UserId(unchecked: "@troll:x"), ignored: true)
        #expect(added["ignored_users"]?.objectValue?["@troll:x"] != nil)
        #expect(added["ignored_users"]?.objectValue?["@spam:x"] != nil)
        let removed = AccountDataClient.ignoredList(
            in: added, userId: UserId(unchecked: "@spam:x"), ignored: false)
        #expect(removed["ignored_users"]?.objectValue?["@spam:x"] == nil)
        #expect(removed["ignored_users"]?.objectValue?["@troll:x"] != nil)
    }

    @Test("Direct edits preserve other users and rooms")
    func direct() {
        let content: [String: AnyCodable] = [
            "@alice:x": .array([.string("!one:x")]),
        ]
        let added = AccountDataClient.directRoomsContent(
            in: content, userId: UserId(unchecked: "@alice:x"),
            roomId: RoomId(unchecked: "!two:x"), isDirect: true)
        #expect(added["@alice:x"]?.arrayValue?.compactMap(\.stringValue) == ["!one:x", "!two:x"])
        let idempotent = AccountDataClient.directRoomsContent(
            in: added, userId: UserId(unchecked: "@alice:x"),
            roomId: RoomId(unchecked: "!two:x"), isDirect: true)
        #expect(idempotent["@alice:x"]?.arrayValue?.compactMap(\.stringValue) == ["!one:x", "!two:x"])
        let removed = AccountDataClient.directRoomsContent(
            in: added, userId: UserId(unchecked: "@alice:x"),
            roomId: RoomId(unchecked: "!one:x"), isDirect: false)
        #expect(removed["@alice:x"]?.arrayValue?.compactMap(\.stringValue) == ["!two:x"])
        let emptied = AccountDataClient.directRoomsContent(
            in: removed, userId: UserId(unchecked: "@alice:x"),
            roomId: RoomId(unchecked: "!two:x"), isDirect: false)
        #expect(emptied["@alice:x"] == nil)
    }

    @Test("Member content decodes invite is_direct flag")
    func memberIsDirect() throws {
        let flagged = """
        {"membership": "invite", "is_direct": true}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(MemberContent.self, from: flagged).isDirect == true)
        let plain = """
        {"membership": "join"}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(MemberContent.self, from: plain).isDirect == nil)
    }

    @Test("Devices decode with timestamps")
    func devices() throws {
        let json = """
        {"devices": [
            {"device_id": "A", "display_name": "Phone",
             "last_seen_ip": "1.2.3.4", "last_seen_ts": 1700000000000},
            {"device_id": "B"}
        ]}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DevicesResponse.self, from: json)
        #expect(response.devices.count == 2)
        #expect(response.devices[0].displayName == "Phone")
        #expect(response.devices[0].lastSeenIP == "1.2.3.4")
        #expect(response.devices[0].lastSeenTimestampMs == 1_700_000_000_000)
        #expect(response.devices[1].displayName == nil)
    }
}
