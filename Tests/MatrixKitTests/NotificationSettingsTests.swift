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
    @Test("Default modes follow the underride matrix")
    func defaults() {
        let all = ruleset(underride: [
            rule(".m.rule.message"), rule(".m.rule.encrypted"),
            rule(".m.rule.room_one_to_one"), rule(".m.rule.encrypted_room_one_to_one"),
        ])
        #expect(NotificationSettings.defaultMode(in: all, encrypted: true, oneToOne: true)
            == .allMessages)
        #expect(NotificationSettings.defaultMode(in: all, encrypted: false, oneToOne: false)
            == .allMessages)

        let silent = ruleset(underride: [
            rule(".m.rule.message", actions: []),
            rule(".m.rule.encrypted", enabled: false),
        ])
        #expect(NotificationSettings.defaultMode(in: silent, encrypted: false, oneToOne: false)
            == .mentionsAndKeywordsOnly)
        #expect(NotificationSettings.defaultMode(in: silent, encrypted: true, oneToOne: false)
            == .mentionsAndKeywordsOnly)
        #expect(NotificationSettings.defaultMode(in: silent, encrypted: true, oneToOne: true)
            == .mentionsAndKeywordsOnly)
    }

    @Test("Room modes distinguish override mutes from room rules")
    func roomModes() {
        let roomId = RoomId(unchecked: "!r:x")
        #expect(NotificationSettings.roomMode(
            in: ruleset(), roomId: roomId) == nil)

        let muted = ruleset(override: [
            rule(".m.rule.room_mute", actions: [], roomCondition: "!r:x"),
        ])
        #expect(NotificationSettings.roomMode(in: muted, roomId: roomId) == .mute)

        let all = ruleset(room: [rule("!r:x")])
        #expect(NotificationSettings.roomMode(in: all, roomId: roomId) == .allMessages)

        let mentions = ruleset(room: [rule("!r:x", actions: [])])
        #expect(NotificationSettings.roomMode(in: mentions, roomId: roomId)
            == .mentionsAndKeywordsOnly)

        // Legacy mutes (pre-migration clients) are room-kind rules with
        // `dont_notify` actions: still mute, not mentions.
        let legacyMute = ruleset(room: [rule("!r:x", actions: [.string("dont_notify")])])
        #expect(NotificationSettings.roomMode(in: legacyMute, roomId: roomId) == .mute)

        // Other rooms' rules do not leak across.
        #expect(NotificationSettings.roomMode(
            in: all, roomId: RoomId(unchecked: "!other:x")) == nil)
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

    @Test("Room mentions prefer the modern rule")
    func roomMentions() {
        let modern = ruleset(override: [rule(".m.rule.is_room_mention", enabled: false)])
        #expect(!NotificationSettings.roomMentionEnabled(in: modern))

        let legacy = ruleset(override: [rule(".m.rule.roomnotif")])
        #expect(NotificationSettings.roomMentionEnabled(in: legacy))

        let legacySilent = ruleset(override: [rule(".m.rule.roomnotif", actions: [])])
        #expect(!NotificationSettings.roomMentionEnabled(in: legacySilent))

        #expect(!NotificationSettings.roomMentionEnabled(in: ruleset()))
    }

    @Test("User mentions prefer the modern rule over legacy")
    func userMentions() {
        let modern = ruleset(
            override: [rule(".m.rule.is_user_mention")],
            content: [rule(".m.rule.contains_user_name", enabled: false)])
        #expect(NotificationSettings.userMentionEnabled(in: modern))

        let legacyName = ruleset(content: [rule(".m.rule.contains_user_name")])
        #expect(NotificationSettings.userMentionEnabled(in: legacyName))

        let legacyDisplay = ruleset(override: [rule(".m.rule.contains_display_name")])
        #expect(NotificationSettings.userMentionEnabled(in: legacyDisplay))

        #expect(!NotificationSettings.userMentionEnabled(in: ruleset()))
    }

    @Test("Push actions encode spec shapes")
    func actionEncoding() throws {
        func encoded(_ action: PushAction) throws -> AnyCodable {
            let data = try JSONEncoder().encode(action)
            return try JSONDecoder().decode(AnyCodable.self, from: data)
        }
        #expect(try encoded(.notify) == .string("notify"))
        #expect(
            try encoded(.sound("default"))
                == .object(["set_tweak": .string("sound"), "value": .string("default")]))
        #expect(
            try encoded(.highlight(nil)) == .object(["set_tweak": .string("highlight")]))
        #expect(
            try encoded(.highlight(false))
                == .object(["set_tweak": .string("highlight"), "value": .bool(false)]))
    }

    @Test("Underride and poll IDs map the room matrix")
    func ruleIds() {
        #expect(NotificationSettings.underrideId(encrypted: true, oneToOne: true)
            == ".m.rule.encrypted_room_one_to_one")
        #expect(NotificationSettings.underrideId(encrypted: false, oneToOne: true)
            == ".m.rule.room_one_to_one")
        #expect(NotificationSettings.underrideId(encrypted: true, oneToOne: false)
            == ".m.rule.encrypted")
        #expect(NotificationSettings.underrideId(encrypted: false, oneToOne: false)
            == ".m.rule.message")
        #expect(NotificationSettings.pollIds(oneToOne: true)
            == [".m.rule.poll_start_one_to_one", ".org.matrix.msc3381.poll_start_one_to_one"])
        #expect(NotificationSettings.pollIds(oneToOne: false)
            == [".m.rule.poll_start", ".org.matrix.msc3381.poll_start"])
    }
}
