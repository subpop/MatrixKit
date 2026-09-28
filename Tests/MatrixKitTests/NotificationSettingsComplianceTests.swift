import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Notification-settings actor compliance: defaults, toggles, keywords,
/// and per-room modes read-modify-write through the push routes.
///
/// Exercised registry endpoints: `GET /pushrules/`,
/// `PUT .../{kind}/{ruleId}[/{actions,enabled}]`,
/// `DELETE .../{kind}/{ruleId}`.
@Suite("NotificationSettingsCompliance")
struct NotificationSettingsComplianceTests {
    private func settings(_ harness: Harness) async -> NotificationSettings {
        let (push, _, _) = await harness.pushClient()
        return NotificationSettings(push: push)
    }

    @Test("Defaults read all-messages, set to mentions, drift fixes")
    func defaults() async throws {
        try await withHarness { harness in
            let settings = await settings(harness)
            let (push, _, _) = await harness.pushClient()
            #expect(try await settings.getDefaultNotificationMode(isOneToOne: true) == .allMessages)
            #expect(try await settings.getDefaultNotificationMode(isOneToOne: false) == .allMessages)
            #expect(try await settings.hasConsistentNotificationSettings())
            try await settings.setDefaultNotificationMode(isOneToOne: false, mode: .mentionsAndKeywordsOnly)
            #expect(try await settings.getDefaultNotificationMode(isOneToOne: false) == .mentionsAndKeywordsOnly)
            // The setter keeps encrypted/unencrypted pairs aligned; break
            // one side out-of-band to simulate external drift.
            try await push.setPushRuleActions(
                kind: "underride", ruleId: ".m.rule.encrypted", actions: [.notify])
            #expect(!(try await settings.hasConsistentNotificationSettings()))
            try await settings.fixInconsistentNotificationSettings()
            #expect(try await settings.hasConsistentNotificationSettings())
        }
    }

    @Test("Call and invite toggles round-trip", arguments: [true, false])
    func toggles(enabled: Bool) async throws {
        try await withHarness { harness in
            let settings = await settings(harness)
            try await settings.setCallNotificationEnabled(enabled)
            #expect(try await settings.isCallNotificationEnabled() == enabled)
            try await settings.setInviteNotificationEnabled(enabled)
            #expect(try await settings.isInviteNotificationEnabled() == enabled)
        }
    }

    @Test("Mention toggles round-trip with legacy rules")
    func mentions() async throws {
        try await withHarness { harness in
            let settings = await settings(harness)
            try await settings.setRoomMentionEnabled(false)
            #expect(!(try await settings.isRoomMentionEnabled()))
            try await settings.setRoomMentionEnabled(true)
            #expect(try await settings.isRoomMentionEnabled())
            try await settings.setUserMentionEnabled(false)
            #expect(!(try await settings.isUserMentionEnabled()))
            try await settings.setUserMentionEnabled(true)
            #expect(try await settings.isUserMentionEnabled())
        }
    }

    @Test("Keywords add, list, and remove")
    func keywords() async throws {
        try await withHarness { harness in
            let settings = await settings(harness)
            #expect(try await settings.getNotificationKeywords().isEmpty)
            try await settings.addNotificationKeyword("matrix")
            #expect(try await settings.getNotificationKeywords() == ["matrix"])
            try await settings.removeNotificationKeyword("matrix")
            #expect(try await settings.getNotificationKeywords().isEmpty)
        }
    }

    @Test("Room modes set, read, list custom, and restore")
    func roomModes() async throws {
        try await withHarness { harness in
            let settings = await settings(harness)
            let room = RoomId(unchecked: "!r:test")
            #expect(try await settings.getRoomNotificationMode(roomId: room) == nil)
            try await settings.setRoomNotificationMode(roomId: room, mode: .mute)
            #expect(try await settings.getRoomNotificationMode(roomId: room) == .mute)
            try await settings.setRoomNotificationMode(roomId: room, mode: .allMessages)
            #expect(try await settings.getRoomNotificationMode(roomId: room) == .allMessages)
            #expect(try await settings.roomsWithCustomNotificationSettings() == [room])
            try await settings.restoreDefaultRoomNotificationMode(roomId: room)
            #expect(try await settings.getRoomNotificationMode(roomId: room) == nil)
            #expect(try await settings.pushRulesSnapshot().global["room"]?.isEmpty != false)
        }
    }
}
