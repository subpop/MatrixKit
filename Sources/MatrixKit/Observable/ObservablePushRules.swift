/// A push rule with its server-side kind (`override`, `content`, ...).
import Observation
public struct PushRuleEntry: Hashable, Sendable, Identifiable {
    /// Server-side ruleset kind (`override`, `content`, `room`, `sender`, `underride`).
    public var kind: String
    /// The rule itself.
    public var rule: PushRule

    public init(kind: String, rule: PushRule) {
        self.kind = kind
        self.rule = rule
    }

    public var id: String { "\(kind)/\(rule.ruleId)" }
}

/// Observable push-rule management.
@Observable @MainActor
public final class ObservablePushRules {
    /// All global rules flattened across kinds, sorted by `id`.
    public private(set) var rules: [PushRuleEntry]
    /// True while a `load()` request is in flight.
    public private(set) var isLoading: Bool

    private let push: PushClient

    init(push: PushClient) {
        self.push = push
        self.rules = []
        self.isLoading = false
    }

    /// Load all rules from the server.
    public func load() async throws {
        isLoading = true
        defer { isLoading = false }
        let ruleset = try await push.getPushRules()
        rules = ruleset.global.flatMap { kind, list in
            list.map { PushRuleEntry(kind: kind, rule: $0) }
        }.sorted { $0.id < $1.id }
    }

    /// Enable/disable a rule (server + local state).
    public func setEnabled(_ entry: PushRuleEntry, enabled: Bool) async throws {
        try await push.setPushRuleEnabled(
            kind: entry.kind, ruleId: entry.rule.ruleId, enabled: enabled)
        if let index = rules.firstIndex(where: { $0.id == entry.id }) {
            rules[index].rule = PushRule(
                ruleId: entry.rule.ruleId,
                isDefault: entry.rule.isDefault,
                enabled: enabled,
                conditions: entry.rule.conditions,
                actions: entry.rule.actions,
                pattern: entry.rule.pattern
            )
        }
    }

    /// Delete a rule (server + local state).
    public func delete(_ entry: PushRuleEntry) async throws {
        try await push.deletePushRule(kind: entry.kind, ruleId: entry.rule.ruleId)
        rules.removeAll { $0.id == entry.id }
    }
}
