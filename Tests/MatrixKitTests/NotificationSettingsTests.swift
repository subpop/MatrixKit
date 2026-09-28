import Foundation
import Testing

@testable import MatrixKit

private func rule(
    _ ruleId: String, enabled: Bool = true, isDefault: Bool = false,
    actions: [AnyCodable] = [.string("notify")], pattern: String? = nil,
    roomCondition: String? = nil
) -> PushRule {
    var conditions: [AnyCodable]?
    if let roomCondition {
        conditions = [.object([
            "kind": .string("event_match"),
            "key": .string("room_id"),
            "pattern": .string(roomCondition),
        ])]
    }
    return PushRule(
        ruleId: ruleId, isDefault: isDefault, enabled: enabled,
        conditions: conditions, actions: actions, pattern: pattern)
}

private func ruleset(
    override: [PushRule] = [], content: [PushRule] = [],
    room: [PushRule] = [], underride: [PushRule] = []
) -> PushRuleset {
    PushRuleset(global: [
        "override": override, "content": content, "room": room, "underride": underride,
    ])
}

@Suite("Notification settings evaluation")
struct NotificationSettingsTests {
    struct ModeCase: Sendable {
        var ruleset: PushRuleset
        var encrypted: Bool
        var oneToOne: Bool
        var expected: DefaultNotificationMode
    }

    static let defaultCases: [ModeCase] = [
        ModeCase(
            ruleset: ruleset(underride: [
                rule(".m.rule.message"), rule(".m.rule.encrypted"),
                rule(".m.rule.room_one_to_one"), rule(".m.rule.encrypted_room_one_to_one"),
            ]),
            encrypted: true, oneToOne: true, expected: .allMessages),
        ModeCase(
            ruleset: ruleset(underride: [
                rule(".m.rule.message"), rule(".m.rule.encrypted"),
                rule(".m.rule.room_one_to_one"), rule(".m.rule.encrypted_room_one_to_one"),
            ]),
            encrypted: false, oneToOne: false, expected: .allMessages),
        ModeCase(
            ruleset: ruleset(underride: [
                rule(".m.rule.message", actions: []),
                rule(".m.rule.encrypted", enabled: false),
            ]),
            encrypted: false, oneToOne: false, expected: .mentionsAndKeywordsOnly),
        ModeCase(
            ruleset: ruleset(underride: [
                rule(".m.rule.message", actions: []),
                rule(".m.rule.encrypted", enabled: false),
            ]),
            encrypted: true, oneToOne: false, expected: .mentionsAndKeywordsOnly),
        ModeCase(
            ruleset: ruleset(underride: [
                rule(".m.rule.message", actions: []),
                rule(".m.rule.encrypted", enabled: false),
            ]),
            encrypted: true, oneToOne: true, expected: .mentionsAndKeywordsOnly),
    ]

    @Test("Default modes follow the underride matrix", arguments: defaultCases)
    func defaults(_ c: ModeCase) {
        #expect(NotificationSettings.defaultMode(
            in: c.ruleset, encrypted: c.encrypted, oneToOne: c.oneToOne) == c.expected)
    }

    struct RoomModeCase: Sendable {
        var ruleset: PushRuleset
        var roomId: RoomId
        var expected: RoomNotificationMode?
    }

    static let roomModeCases: [RoomModeCase] = [
        RoomModeCase(ruleset: ruleset(), roomId: RoomId(unchecked: "!r:x"), expected: nil),
        RoomModeCase(
            ruleset: ruleset(override: [
                rule(".m.rule.room_mute", actions: [], roomCondition: "!r:x"),
            ]),
            roomId: RoomId(unchecked: "!r:x"), expected: .mute),
        RoomModeCase(
            ruleset: ruleset(room: [rule("!r:x")]),
            roomId: RoomId(unchecked: "!r:x"), expected: .allMessages),
        RoomModeCase(
            ruleset: ruleset(room: [rule("!r:x", actions: [])]),
            roomId: RoomId(unchecked: "!r:x"), expected: .mentionsAndKeywordsOnly),
        // Legacy mutes (pre-migration clients) are room-kind rules with
        // `dont_notify` actions: still mute, not mentions.
        RoomModeCase(
            ruleset: ruleset(room: [rule("!r:x", actions: [.string("dont_notify")])]),
            roomId: RoomId(unchecked: "!r:x"), expected: .mute),
        // Other rooms' rules do not leak across.
        RoomModeCase(
            ruleset: ruleset(room: [rule("!r:x")]),
            roomId: RoomId(unchecked: "!other:x"), expected: nil),
    ]

    @Test("Room modes distinguish override mutes from room rules", arguments: roomModeCases)
    func roomModes(_ c: RoomModeCase) {
        #expect(NotificationSettings.roomMode(in: c.ruleset, roomId: c.roomId) == c.expected)
    }

    @Test("Custom rooms collect room rules and room conditions")
    func customRooms() {
        let roomA = RoomId(unchecked: "!a:x")
        let roomB = RoomId(unchecked: "!b:x")
        let set = ruleset(
            override: [
                rule(".m.rule.call", isDefault: true),
                rule("custom", roomCondition: "!b:x"),
            ],
            room: [rule("!a:x")])
        #expect(NotificationSettings.customRoomIds(in: set) == [roomA, roomB])
        #expect(NotificationSettings.customRoomIds(in: set, enabled: false) == [])
        #expect(NotificationSettings.customRoomIds(in: ruleset()) == [])
    }

    @Test("Custom rooms keep server IDs that fail strict validation")
    func customRoomsBareIds() {
        // Some servers emit room IDs with no `:server` part. Strict
        // `RoomId` parsing rejects those, but they must still surface
        // here or the room silently falls back to its default mode.
        let bare = RoomId(unchecked: "!barehash")
        let set = ruleset(override: [
            rule("!barehash", actions: [], roomCondition: "!barehash"),
        ])
        #expect(NotificationSettings.customRoomIds(in: set) == [bare])
        #expect(NotificationSettings.roomMode(in: set, roomId: bare) == .mute)
    }

    @Test("Keywords are enabled non-default content patterns with actions")
    func keywords() {
        let set = ruleset(content: [
            rule(".m.rule.contains_user_name", isDefault: true, pattern: "alice"),
            rule("kw1", pattern: "matrix"),
            rule("kw2", enabled: false, pattern: "quiet"),
            rule("kw3", actions: [], pattern: "silent"),
        ])
        #expect(NotificationSettings.keywords(in: set) == ["matrix"])
    }

    @Test("Room mentions prefer the modern rule", arguments: [
        (ruleset(override: [rule(".m.rule.is_room_mention", enabled: false)]), false),
        (ruleset(override: [rule(".m.rule.roomnotif")]), true),
        (ruleset(override: [rule(".m.rule.roomnotif", actions: [])]), false),
        (ruleset(), false),
    ])
    func roomMentions(_ set: PushRuleset, expected: Bool) {
        #expect(NotificationSettings.roomMentionEnabled(in: set) == expected)
    }

    @Test("User mentions prefer the modern rule over legacy", arguments: [
        (ruleset(
            override: [rule(".m.rule.is_user_mention")],
            content: [rule(".m.rule.contains_user_name", enabled: false)]), true),
        (ruleset(content: [rule(".m.rule.contains_user_name")]), true),
        (ruleset(override: [rule(".m.rule.contains_display_name")]), true),
        (ruleset(), false),
    ])
    func userMentions(_ set: PushRuleset, expected: Bool) {
        #expect(NotificationSettings.userMentionEnabled(in: set) == expected)
    }

    @Test("Push actions encode spec shapes", arguments: [
        (PushAction.notify, AnyCodable.string("notify")),
        (
            PushAction.sound("default"),
            AnyCodable.object(["set_tweak": .string("sound"), "value": .string("default")])),
        (
            PushAction.highlight(nil),
            AnyCodable.object(["set_tweak": .string("highlight")])),
        (
            PushAction.highlight(false),
            AnyCodable.object(["set_tweak": .string("highlight"), "value": .bool(false)])),
    ])
    func actionEncoding(_ action: PushAction, expected: AnyCodable) throws {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(AnyCodable.self, from: data) == expected)
    }

    @Test("Underride IDs map the room matrix", arguments: [
        ((true, true), ".m.rule.encrypted_room_one_to_one"),
        ((false, true), ".m.rule.room_one_to_one"),
        ((true, false), ".m.rule.encrypted"),
        ((false, false), ".m.rule.message"),
    ])
    func underrideIds(flags: (Bool, Bool), expected: String) {
        #expect(NotificationSettings.underrideId(encrypted: flags.0, oneToOne: flags.1) == expected)
    }

    @Test("Poll IDs map one-to-one rooms", arguments: [
        (true, [".m.rule.poll_start_one_to_one", ".org.matrix.msc3381.poll_start_one_to_one"]),
        (false, [".m.rule.poll_start", ".org.matrix.msc3381.poll_start"]),
    ])
    func pollIds(oneToOne: Bool, expected: [String]) {
        #expect(NotificationSettings.pollIds(oneToOne: oneToOne) == expected)
    }
}
