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

    struct PermissionCase: Sendable {
        var user: String
        var check: @Sendable (RoomPermissions) -> Bool
        var expected: Bool
    }

    static let permissionCases: [PermissionCase] = [
        PermissionCase(user: "@admin:x", check: { $0.canBan }, expected: true),
        PermissionCase(user: "@admin:x", check: { $0.canKick }, expected: true),
        PermissionCase(user: "@admin:x", check: { $0.canChangePermissions }, expected: true),
        PermissionCase(user: "@admin:x", check: { $0.canEditName }, expected: true),
        PermissionCase(user: "@admin:x", check: { $0.canSendMessages }, expected: true),
        PermissionCase(user: "@admin:x", check: { $0.canEditDetails }, expected: true),
        PermissionCase(user: "@mod:x", check: { $0.canBan }, expected: false),
        PermissionCase(user: "@mod:x", check: { $0.canKick }, expected: true),
        PermissionCase(user: "@mod:x", check: { $0.canChangePermissions }, expected: false),
        PermissionCase(user: "@mod:x", check: { $0.canEditName }, expected: true),
        PermissionCase(user: "@user:x", check: { $0.canKick }, expected: false),
        PermissionCase(user: "@user:x", check: { $0.canEditName }, expected: false),
        PermissionCase(user: "@user:x", check: { $0.canSendMessages }, expected: true),
        PermissionCase(user: "@user:x", check: { $0.canEditDetails }, expected: false),
    ]

    static let permissionContent: [String: AnyCodable] = powerContent(
        users: ["@admin:x": 100, "@mod:x": 50],
        ban: 60,
        events: ["m.room.power_levels": 100])

    @Test("Permissions evaluate per user", arguments: permissionCases)
    func evaluate(_ c: PermissionCase) {
        let permissions = RoomPermissions.evaluate(
            powerLevels: Self.permissionContent,
            userId: UserId(unchecked: c.user))
        #expect(c.check(permissions) == c.expected)
    }

    @Test("Custom thresholds apply")
    func customThresholds() {
        let content = powerContent(users: ["@a:x": 10], invite: 10, eventsDefault: 20)
        let permissions = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@a:x"))
        #expect(permissions.canInvite)
        #expect(!permissions.canSendMessages)
    }

    @Test("String-encoded power levels coerce per spec")
    func stringLevels() {
        let content: [String: AnyCodable] = [
            "users": .object(["@admin:x": .string("100")]),
            "users_default": .string("10"),
            "ban": .string("60"),
        ]
        #expect(RoomPermissions.powerLevel(
            of: UserId(unchecked: "@admin:x"), in: content) == 100)
        #expect(RoomPermissions.powerLevel(
            of: UserId(unchecked: "@other:x"), in: content) == 10)
        let permissions = RoomPermissions.evaluate(
            powerLevels: content, userId: UserId(unchecked: "@admin:x"))
        #expect(permissions.canBan)
        #expect(RoomPowerLevelSettings.parse(content).usersDefault == 10)
    }

    @Test("Non-integral values fall back to defaults")
    func nonIntegralLevels() {
        #expect(AnyCodable.string("admin").intValue == nil)
        #expect(AnyCodable.double(50.5).intValue == nil)
        #expect(AnyCodable.double(50.0).intValue == 50)
        let content: [String: AnyCodable] = [
            "users": .object(["@a:x": .string("high")]),
        ]
        #expect(RoomPermissions.powerLevel(
            of: UserId(unchecked: "@a:x"), in: content) == 0)
    }

    @Test("Roles bucket power levels", arguments: [
        (100, RoomMemberDetails.Role.administrator),
        (150, RoomMemberDetails.Role.administrator),
        (50, RoomMemberDetails.Role.moderator),
        (0, RoomMemberDetails.Role.user),
    ])
    func roles(level: Int, expected: RoomMemberDetails.Role) {
        #expect(RoomMemberDetails.Role.of(level) == expected)
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

    @Test("Member content decodes invite is_direct flag", arguments: [
        ("{\"membership\": \"invite\", \"is_direct\": true}", true as Bool?),
        ("{\"membership\": \"join\"}", nil),
    ])
    func memberIsDirect(json: String, expected: Bool?) throws {
        #expect(try JSONDecoder().decode(MemberContent.self, from: Data(json.utf8)).isDirect == expected)
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
