/// High-level push notification settings over `PushClient`.
///
/// Replicates the Matrix Rust SDK `NotificationSettings` semantics:
/// default modes keyed off underride rules (`.m.rule.message` /
/// `.m.rule.encrypted` and the one-to-one pair), per-room overrides via
/// room-kind (notify) and override (mute) rules, and keyword content
/// rules. Evaluation helpers are pure (`nonisolated static`) so they
/// test without a server.
import Foundation

/// Default notification mode for rooms of one type.
public enum DefaultNotificationMode: Sendable, Equatable, CaseIterable {
    /// Notify for every message in the room.
    case allMessages
    /// Notify only when the user is mentioned or a keyword matches.
    case mentionsAndKeywordsOnly
    /// Suppress all notifications from the room.
    case mute
}

/// Notification mode for a specific room.
public enum RoomNotificationMode: Sendable, Equatable, CaseIterable, Codable {
    /// Notify for every message in the room.
    case allMessages
    /// Notify only when the user is mentioned or a keyword matches.
    case mentionsAndKeywordsOnly
    /// Suppress all notifications from the room.
    case mute
}

public actor NotificationSettings {
    // MARK: - Rule IDs

    private nonisolated static let messageRule = ".m.rule.message"
    private nonisolated static let encryptedRule = ".m.rule.encrypted"
    private nonisolated static let roomOneToOneRule = ".m.rule.room_one_to_one"
    private nonisolated static let encryptedRoomOneToOneRule = ".m.rule.encrypted_room_one_to_one"
    private nonisolated static let pollStartRule = ".m.rule.poll_start"
    private nonisolated static let pollStartOneToOneRule = ".m.rule.poll_start_one_to_one"
    private nonisolated static let pollStartUnstableRule = ".org.matrix.msc3381.poll_start"
    private nonisolated static let pollStartOneToOneUnstableRule =
        ".org.matrix.msc3381.poll_start_one_to_one"
    private nonisolated static let callRule = ".m.rule.call"
    private nonisolated static let inviteRule = ".m.rule.invite_for_me"
    private nonisolated static let isRoomMentionRule = ".m.rule.is_room_mention"
    private nonisolated static let roomNotifRule = ".m.rule.roomnotif"
    private nonisolated static let isUserMentionRule = ".m.rule.is_user_mention"
    private nonisolated static let containsDisplayNameRule = ".m.rule.contains_display_name"
    private nonisolated static let containsUserNameRule = ".m.rule.contains_user_name"

    private let push: PushClient

    init(push: PushClient) {
        self.push = push
    }

    // MARK: - Pure evaluation

    /// Underride rule ID for one room type.
    nonisolated static func underrideId(encrypted: Bool, oneToOne: Bool) -> String {
        switch (encrypted, oneToOne) {
        case (true, true): encryptedRoomOneToOneRule
        case (false, true): roomOneToOneRule
        case (true, false): encryptedRule
        case (false, false): messageRule
        }
    }

    /// Poll-start rule IDs for one room type (stable plus unstable).
    nonisolated static func pollIds(oneToOne: Bool) -> [String] {
        oneToOne
            ? [pollStartOneToOneRule, pollStartOneToOneUnstableRule]
            : [pollStartRule, pollStartUnstableRule]
    }

    /// Whether actions trigger a notification (contain `notify`).
    nonisolated static func notifies(_ actions: [AnyCodable]) -> Bool {
        actions.contains(.string("notify"))
    }

    /// Decode a rule's match conditions (unparseable entries dropped).
    nonisolated static func conditions(of rule: PushRule) -> [PushCondition] {
        (rule.conditions ?? []).compactMap { condition in
            guard
                let data = try? JSONEncoder().encode(condition),
                let decoded = try? JSONDecoder().decode(PushCondition.self, from: data)
            else { return nil }
            return decoded
        }
    }

    /// Whether a rule targets a room (by ID or `room_id` condition).
    nonisolated static func matchesRoom(_ rule: PushRule, roomId: RoomId) -> Bool {
        if rule.ruleId == roomId.value { return true }
        return conditions(of: rule).contains {
            $0.kind == "event_match" && $0.key == "room_id" && $0.pattern == roomId.value
        }
    }

    /// Default mode from an underride rule: notifying and enabled means
    /// all messages, anything else means mentions and keywords.
    nonisolated static func defaultMode(
        in ruleset: PushRuleset, encrypted: Bool, oneToOne: Bool
    ) -> DefaultNotificationMode {
        let id = underrideId(encrypted: encrypted, oneToOne: oneToOne)
        if let rule = ruleset.global["underride"]?.first(where: { $0.ruleId == id }),
            rule.enabled, notifies(rule.actions)
        {
            return .allMessages
        }
        return .mentionsAndKeywordsOnly
    }

    /// User-defined room mode: an enabled non-notifying override rule
    /// means mute; a room-kind rule means all messages when notifying,
    /// mute when explicitly silenced (`dont_notify`, the legacy mute
    /// shape), mentions otherwise; nothing means the default applies.
    nonisolated static func roomMode(
        in ruleset: PushRuleset, roomId: RoomId
    ) -> RoomNotificationMode? {
        let overrides = ruleset.global["override"] ?? []
        if overrides.contains(where: {
            $0.enabled && matchesRoom($0, roomId: roomId) && !notifies($0.actions)
        }) {
            return .mute
        }
        if let rule = ruleset.global["room"]?.first(where: { $0.ruleId == roomId.value }) {
            if notifies(rule.actions) {
                return .allMessages
            }
            if rule.actions.contains(.string("dont_notify")) {
                return .mute
            }
            return .mentionsAndKeywordsOnly
        }
        return nil
    }

    /// Custom (non-default) rules targeting a room: override/underride
    /// rules with `room_id` conditions plus the room-kind rule.
    nonisolated static func customRules(
        for roomId: RoomId, in ruleset: PushRuleset
    ) -> [(kind: String, ruleId: String)] {
        var found: [(String, String)] = []
        for rule in ruleset.global["override"] ?? [] where matchesRoom(rule, roomId: roomId) {
            found.append(("override", rule.ruleId))
        }
        if ruleset.global["room"]?.contains(where: { $0.ruleId == roomId.value }) == true {
            found.append(("room", roomId.value))
        }
        for rule in ruleset.global["underride"] ?? [] where matchesRoom(rule, roomId: roomId) {
            found.append(("underride", rule.ruleId))
        }
        return found
    }

    /// Room IDs with user-defined rules, optionally filtered by enabled.
    nonisolated static func customRoomIds(
        in ruleset: PushRuleset, enabled: Bool? = nil
    ) -> [RoomId] {
        var ids = Set<RoomId>()
        func passes(_ rule: PushRule) -> Bool {
            guard !rule.isDefault else { return false }
            if let enabled, rule.enabled != enabled { return false }
            return true
        }
        for rule in ruleset.global["room"] ?? [] where passes(rule) {
            // Rule IDs here are room IDs by definition; keep even ones
            // that fail strict validation (some servers emit bare IDs
            // with no `:server` part).
            ids.insert((try? RoomId(rule.ruleId)) ?? RoomId(unchecked: rule.ruleId))
        }
        for kind in ["override", "underride"] {
            for rule in ruleset.global[kind] ?? [] where passes(rule) {
                for condition in conditions(of: rule)
                where condition.kind == "event_match" && condition.key == "room_id" {
                    if let pattern = condition.pattern {
                        ids.insert(
                            (try? RoomId(pattern)) ?? RoomId(unchecked: pattern))
                    }
                }
            }
        }
        return ids.sorted { $0.value < $1.value }
    }

    /// Enabled keyword patterns (non-default content rules with actions).
    nonisolated static func keywords(in ruleset: PushRuleset) -> [String] {
        (ruleset.global["content"] ?? []).compactMap { rule in
            guard !rule.isDefault, rule.enabled, let pattern = rule.pattern,
                !rule.actions.isEmpty
            else { return nil }
            return pattern
        }
    }

    /// Room-mention state: the MSC3952 rule when present, else the
    /// legacy `roomnotif` rule (which must also notify).
    nonisolated static func roomMentionEnabled(in ruleset: PushRuleset) -> Bool {
        let overrides = ruleset.global["override"] ?? []
        if let modern = overrides.first(where: { $0.ruleId == isRoomMentionRule }) {
            return modern.enabled
        }
        return overrides.first(where: { $0.ruleId == roomNotifRule })
            .map { $0.enabled && notifies($0.actions) } ?? false
    }

    /// User-mention state: the MSC3952 rule when present, else either
    /// legacy rule notifying.
    nonisolated static func userMentionEnabled(in ruleset: PushRuleset) -> Bool {
        let overrides = ruleset.global["override"] ?? []
        if let modern = overrides.first(where: { $0.ruleId == isUserMentionRule }) {
            return modern.enabled
        }
        let displayName = overrides.first(where: { $0.ruleId == containsDisplayNameRule })
            .map { $0.enabled && notifies($0.actions) } ?? false
        let userName = ruleset.global["content"]?
            .first(where: { $0.ruleId == containsUserNameRule })
            .map { $0.enabled && notifies($0.actions) } ?? false
        return displayName || userName
    }

    /// Notify actions for "all messages" (notify plus default sound).
    nonisolated static var notifyActions: [PushAction] {
        [.notify, .sound("default")]
    }

    // MARK: - Defaults

    /// Default mode for rooms of one type (reads the encrypted variant,
    /// matching the previous implementation).
    public func getDefaultNotificationMode(isOneToOne: Bool) async throws -> DefaultNotificationMode {
        Self.defaultMode(
            in: try await push.getPushRules(), encrypted: true, oneToOne: isOneToOne)
    }

    /// Set the default mode for rooms of one type (both encrypted and
    /// unencrypted variants, plus poll rules best-effort).
    public func setDefaultNotificationMode(
        isOneToOne: Bool, mode: DefaultNotificationMode
    ) async throws {
        try await setDefaultVariant(encrypted: true, oneToOne: isOneToOne, mode: mode)
        try await setDefaultVariant(encrypted: false, oneToOne: isOneToOne, mode: mode)
    }

    private func setDefaultVariant(
        encrypted: Bool, oneToOne: Bool, mode: DefaultNotificationMode
    ) async throws {
        let actions: [PushAction] = mode == .allMessages ? Self.notifyActions : []
        let ruleId = Self.underrideId(encrypted: encrypted, oneToOne: oneToOne)
        try await push.setPushRuleActions(kind: "underride", ruleId: ruleId, actions: actions)
        let ruleset = try await push.getPushRules()
        if !(ruleset.global["underride"]?.first(where: { $0.ruleId == ruleId })?.enabled ?? false) {
            try await push.setPushRuleEnabled(kind: "underride", ruleId: ruleId, enabled: true)
        }
        // Poll-start rules are unstable and may be absent; skip those.
        for pollId in Self.pollIds(oneToOne: oneToOne) {
            guard
                let poll = ruleset.global["underride"]?.first(where: { $0.ruleId == pollId })
            else { continue }
            try await push.setPushRuleActions(
                kind: "underride", ruleId: pollId, actions: actions)
            if !poll.enabled {
                try await push.setPushRuleEnabled(
                    kind: "underride", ruleId: pollId, enabled: true)
            }
        }
    }

    /// Whether encrypted and unencrypted defaults agree for both room types.
    public func hasConsistentNotificationSettings() async throws -> Bool {
        let ruleset = try await push.getPushRules()
        return Self.defaultMode(in: ruleset, encrypted: true, oneToOne: true)
            == Self.defaultMode(in: ruleset, encrypted: false, oneToOne: true)
            && Self.defaultMode(in: ruleset, encrypted: true, oneToOne: false)
                == Self.defaultMode(in: ruleset, encrypted: false, oneToOne: false)
    }

    /// Align unencrypted defaults with the encrypted ones.
    public func fixInconsistentNotificationSettings() async throws {
        let ruleset = try await push.getPushRules()
        try await setDefaultVariant(
            encrypted: false, oneToOne: true,
            mode: Self.defaultMode(in: ruleset, encrypted: true, oneToOne: true))
        try await setDefaultVariant(
            encrypted: false, oneToOne: false,
            mode: Self.defaultMode(in: ruleset, encrypted: true, oneToOne: false))
    }

    /// Room IDs with enabled user-defined rules.
    public func roomsWithCustomNotificationSettings() async throws -> [RoomId] {
        Self.customRoomIds(in: try await push.getPushRules(), enabled: true)
    }

    /// Raw server ruleset (`GET /pushrules/`). Diagnostic surface for
    /// debugging tools; prefer the typed accessors above in app code.
    public func pushRulesSnapshot() async throws -> PushRuleset {
        try await push.getPushRules()
    }

    // MARK: - Toggles

    /// Whether call notifications fire (`.m.rule.call`).
    public func isCallNotificationEnabled() async throws -> Bool {
        let ruleset = try await push.getPushRules()
        return ruleset.global["override"]?.first(where: { $0.ruleId == Self.callRule })?.enabled
            ?? false
    }

    /// Toggle call notifications.
    public func setCallNotificationEnabled(_ enabled: Bool) async throws {
        try await push.setPushRuleEnabled(
            kind: "override", ruleId: Self.callRule, enabled: enabled)
    }

    /// Whether invite notifications fire (`.m.rule.invite_for_me`).
    public func isInviteNotificationEnabled() async throws -> Bool {
        let ruleset = try await push.getPushRules()
        return ruleset.global["override"]?.first(where: { $0.ruleId == Self.inviteRule })?.enabled
            ?? false
    }

    /// Toggle invite notifications.
    public func setInviteNotificationEnabled(_ enabled: Bool) async throws {
        try await push.setPushRuleEnabled(
            kind: "override", ruleId: Self.inviteRule, enabled: enabled)
    }

    /// Whether `@room` mentions notify.
    public func isRoomMentionEnabled() async throws -> Bool {
        Self.roomMentionEnabled(in: try await push.getPushRules())
    }

    /// Toggle `@room` mentions (modern rule, legacy best-effort).
    public func setRoomMentionEnabled(_ enabled: Bool) async throws {
        try await push.setPushRuleEnabled(
            kind: "override", ruleId: Self.isRoomMentionRule, enabled: enabled)
        // Removed rule; the modern one governs. Skip when absent.
        let ruleset = try await push.getPushRules()
        if ruleset.global["override"]?.contains(where: { $0.ruleId == Self.roomNotifRule })
            == true
        {
            try await push.setPushRuleEnabled(
                kind: "override", ruleId: Self.roomNotifRule, enabled: enabled)
        }
    }

    /// Whether `@user` mentions notify.
    public func isUserMentionEnabled() async throws -> Bool {
        Self.userMentionEnabled(in: try await push.getPushRules())
    }

    /// Toggle `@user` mentions (modern rule, legacy best-effort).
    public func setUserMentionEnabled(_ enabled: Bool) async throws {
        try await push.setPushRuleEnabled(
            kind: "override", ruleId: Self.isUserMentionRule, enabled: enabled)
        // Removed rules; the modern one governs. Skip absent ones.
        let ruleset = try await push.getPushRules()
        if ruleset.global["content"]?.contains(where: { $0.ruleId == Self.containsUserNameRule })
            == true
        {
            try await push.setPushRuleEnabled(
                kind: "content", ruleId: Self.containsUserNameRule, enabled: enabled)
        }
        if ruleset.global["override"]?
            .contains(where: { $0.ruleId == Self.containsDisplayNameRule }) == true
        {
            try await push.setPushRuleEnabled(
                kind: "override", ruleId: Self.containsDisplayNameRule, enabled: enabled)
        }
    }

    // MARK: - Keywords

    /// Enabled keyword patterns.
    public func getNotificationKeywords() async throws -> [String] {
        Self.keywords(in: try await push.getPushRules())
    }

    /// Add a keyword rule (PUT is idempotent: absent rules are created,
    /// present ones are rewritten with notifying actions).
    public func addNotificationKeyword(_ keyword: String) async throws {
        try await push.setKeywordPushRule(keyword: keyword, actions: [
            .notify, .highlight(nil), .sound("default"),
        ])
    }

    /// Delete every content rule with this pattern.
    public func removeNotificationKeyword(_ keyword: String) async throws {
        let ruleset = try await push.getPushRules()
        for rule in ruleset.global["content"] ?? []
        where !rule.isDefault && rule.pattern == keyword {
            try await push.deletePushRule(kind: "content", ruleId: rule.ruleId)
        }
    }

    // MARK: - Per-room modes

    /// User-defined mode for a room, or nil when the default applies.
    public func getRoomNotificationMode(roomId: RoomId) async throws -> RoomNotificationMode? {
        Self.roomMode(in: try await push.getPushRules(), roomId: roomId)
    }

    /// Set a room's mode (room-kind rule for all/mentions, override rule
    /// for mute), deleting other custom rules for the room.
    public func setRoomNotificationMode(
        roomId: RoomId, mode: RoomNotificationMode
    ) async throws {
        let ruleset = try await push.getPushRules()
        if Self.roomMode(in: ruleset, roomId: roomId) == mode {
            return
        }
        switch mode {
        case .allMessages:
            try await push.setRoomPushRule(
                ruleId: roomId.value, actions: Self.notifyActions)
        case .mentionsAndKeywordsOnly:
            try await push.setRoomPushRule(ruleId: roomId.value, actions: [])
        case .mute:
            try await push.setConditionalPushRule(
                kind: "override", ruleId: roomId.value,
                conditions: [.roomId(roomId)], actions: [])
        }
        for custom in Self.customRules(for: roomId, in: ruleset) {
            let isNew =
                (mode == .mute ? custom.kind == "override" : custom.kind == "room")
                && custom.ruleId == roomId.value
            if !isNew {
                try await push.deletePushRule(kind: custom.kind, ruleId: custom.ruleId)
            }
        }
    }

    /// Delete a room's custom rules so the default applies.
    public func restoreDefaultRoomNotificationMode(roomId: RoomId) async throws {
        let ruleset = try await push.getPushRules()
        for custom in Self.customRules(for: roomId, in: ruleset) {
            try await push.deletePushRule(kind: custom.kind, ruleId: custom.ruleId)
        }
    }
}
