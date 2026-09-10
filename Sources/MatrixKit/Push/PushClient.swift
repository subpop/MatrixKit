/// Push notifications: pushers and push rules.
public actor PushClient {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Pushers

    /// List pushers (`GET /pushers`).
    public func getPushers() async throws(MatrixError) -> [Pusher] {
        let response: PushersResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/pushers",
            accessToken: try await token()
        )
        return response.pushers
    }

    /// Add/update a pusher (`POST /pushers/set`).
    public func setPusher(_ pusher: Pusher) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/pushers/set",
            body: pusher, accessToken: try await token()
        )
    }

    // MARK: - Push rules

    /// All push rules (`GET /pushrules/`).
    public func getPushRules() async throws(MatrixError) -> PushRuleset {
        try await transport.send(
            .get, path: "/_matrix/client/v3/pushrules/",
            accessToken: try await token()
        )
    }

    /// A single push rule (`GET /pushrules/{scope}/{kind}/{ruleId}`).
    public func getPushRule(scope: String = "global", kind: String, ruleId: String) async throws(MatrixError) -> PushRule {
        try await transport.send(
            .get,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Enable/disable a rule (`PUT /pushrules/{scope}/{kind}/{ruleId}/enabled`).
    public func setPushRuleEnabled(
        scope: String = "global", kind: String, ruleId: String, enabled: Bool
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)/enabled",
            body: EnabledState(enabled: enabled),
            accessToken: try await token()
        )
    }

    /// Delete a rule (`DELETE /pushrules/{scope}/{kind}/{ruleId}`).
    public func deletePushRule(scope: String = "global", kind: String, ruleId: String) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .delete,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Create or replace a room-kind rule (`PUT /pushrules/{scope}/room/{ruleId}`).
    public func setRoomPushRule(
        scope: String = "global", ruleId: String, actions: [PushAction]
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/room/\(ruleId.pathSegmentEncoded)",
            body: ["actions": actions],
            accessToken: try await token()
        )
    }

    /// Create or replace a conditional (override) rule
    /// (`PUT /pushrules/{scope}/{kind}/{ruleId}`).
    public func setConditionalPushRule(
        scope: String = "global", kind: String, ruleId: String,
        conditions: [PushCondition], actions: [PushAction]
    ) async throws(MatrixError) {
        struct Body: Encodable {
            var conditions: [PushCondition]
            var actions: [PushAction]
        }
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)",
            body: Body(conditions: conditions, actions: actions),
            accessToken: try await token()
        )
    }

    /// Create or replace a keyword (content) rule
    /// (`PUT /pushrules/{scope}/content/{ruleId}`).
    public func setKeywordPushRule(
        scope: String = "global", keyword: String, actions: [PushAction]
    ) async throws(MatrixError) {
        struct Body: Encodable {
            var pattern: String
            var actions: [PushAction]
        }
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/content/\(keyword.pathSegmentEncoded)",
            body: Body(pattern: keyword, actions: actions),
            accessToken: try await token()
        )
    }

    /// Replace a rule's actions (`PUT /pushrules/{scope}/{kind}/{ruleId}/actions`).
    public func setPushRuleActions(
        scope: String = "global", kind: String, ruleId: String, actions: [PushAction]
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)/actions",
            body: ["actions": actions],
            accessToken: try await token()
        )
    }

    /// A rule's actions (`GET /pushrules/{scope}/{kind}/{ruleId}/actions`).
    public func getPushRuleActions(
        scope: String = "global", kind: String, ruleId: String
    ) async throws(MatrixError) -> [PushAction] {
        let response: RuleActionsResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/pushrules/\(scope.pathSegmentEncoded)/\(kind.pathSegmentEncoded)/\(ruleId.pathSegmentEncoded)/actions",
            accessToken: try await token()
        )
        return response.actions
    }
}

/// A pusher (push gateway registration).
public struct Pusher: Hashable, Sendable, Codable {
    /// Push key identifying the device at the gateway.
    public var pushkey: String
    /// Pusher type (`http` or `email`).
    public var kind: String
    /// Application ID (reverse-DNS style).
    public var appId: String
    /// Human-readable application name.
    public var appDisplayName: String
    /// Human-readable device name.
    public var deviceDisplayName: String
    /// Profile tag disambiguating multiple sessions.
    public var profileTag: String?
    /// Preferred notification language (BCP 47).
    public var lang: String
    /// Gateway-specific data (e.g. `url`, `format` for HTTP pushers).
    public var data: [String: AnyCodable]?

    public init(
        pushkey: String,
        kind: String = "http",
        appId: String,
        appDisplayName: String,
        deviceDisplayName: String,
        profileTag: String? = nil,
        lang: String = "en",
        data: [String: AnyCodable]? = nil
    ) {
        self.pushkey = pushkey
        self.kind = kind
        self.appId = appId
        self.appDisplayName = appDisplayName
        self.deviceDisplayName = deviceDisplayName
        self.profileTag = profileTag
        self.lang = lang
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case pushkey
        case kind
        case appId = "app_id"
        case appDisplayName = "app_display_name"
        case deviceDisplayName = "device_display_name"
        case profileTag = "profile_tag"
        case lang
        case data
    }
}

/// `GET /pushers` response.
public struct PushersResponse: Hashable, Sendable, Codable {
    /// Registered pushers for this device.
    public var pushers: [Pusher]

    public init(pushers: [Pusher] = []) {
        self.pushers = pushers
    }
}

/// Full push ruleset (`GET /pushrules/`).
public struct PushRuleset: Hashable, Sendable, Codable {
    /// Maps rule kind (`override`, `content`, `room`, `sender`, `underride`)
    /// to the rules of that kind.
    public var global: [String: [PushRule]]

    public init(global: [String: [PushRule]] = [:]) {
        self.global = global
    }

    /// All rules flattened across kinds.
    public var allRules: [PushRule] {
        global.values.flatMap { $0 }
    }
}

/// A single push rule.
public struct PushRule: Hashable, Sendable, Codable {
    /// Rule ID (e.g. `.m.rule.contains_user_name`).
    public var ruleId: String
    /// True for server-defined rules (still toggleable, not deletable).
    public var isDefault: Bool
    /// Whether the rule currently fires.
    public var enabled: Bool
    /// Match conditions. Absent on kind-implied rules (e.g. `content`).
    public var conditions: [AnyCodable]?
    /// Actions on match (`notify`, `dont_notify`, tweaks, …).
    public var actions: [AnyCodable]
    /// Match pattern for `content` rules.
    public var pattern: String?

    public init(
        ruleId: String,
        isDefault: Bool = false,
        enabled: Bool = true,
        conditions: [AnyCodable]? = nil,
        actions: [AnyCodable] = [],
        pattern: String? = nil
    ) {
        self.ruleId = ruleId
        self.isDefault = isDefault
        self.enabled = enabled
        self.conditions = conditions
        self.actions = actions
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case ruleId = "rule_id"
        case isDefault = "default"
        case enabled
        case conditions
        case actions
        case pattern
    }
}

/// `PUT .../enabled` body.
public struct EnabledState: Hashable, Sendable, Codable {
    /// Desired enabled state.
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// One push-rule action for rule writes.
public enum PushAction: Hashable, Sendable, Codable {
    /// Notify (highlight controlled separately).
    case notify
    /// Play a sound (`value` defaults to the server default sound).
    case sound(String?)
    /// Highlight the message (`nil` marks highlighted).
    case highlight(Bool?)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let action = try? container.decode(String.self) {
            guard action == "notify" else {
                throw MatrixError.encodingError("Unknown push action: \(action)")
            }
            self = .notify
            return
        }
        let tweak = try container.decode([String: AnyCodable].self)
        switch tweak["set_tweak"]?.stringValue {
        case "sound":
            self = .sound(tweak["value"]?.stringValue)
        case "highlight":
            self = .highlight(tweak["value"]?.boolValue)
        default:
            throw MatrixError.encodingError("Unknown push action tweak")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .notify:
            try container.encode("notify")
        case .sound(let value):
            var tweak: [String: AnyCodable] = ["set_tweak": .string("sound")]
            if let value { tweak["value"] = .string(value) }
            try container.encode(tweak)
        case .highlight(let value):
            var tweak: [String: AnyCodable] = ["set_tweak": .string("highlight")]
            if let value { tweak["value"] = .bool(value) }
            try container.encode(tweak)
        }
    }
}

/// One push-rule match condition.
public struct PushCondition: Hashable, Sendable, Codable {
    /// Condition kind (`event_match`, …).
    public var kind: String
    /// Event key to match (`room_id`, …).
    public var key: String?
    /// Match pattern.
    public var pattern: String?

    public init(kind: String, key: String? = nil, pattern: String? = nil) {
        self.kind = kind
        self.key = key
        self.pattern = pattern
    }

    /// An `event_match` on `room_id`.
    public static func roomId(_ roomId: RoomId) -> PushCondition {
        PushCondition(kind: "event_match", key: "room_id", pattern: roomId.value)
    }
}

/// `GET /pushrules/{scope}/{kind}/{ruleId}/actions` response body.
public struct RuleActionsResponse: Hashable, Sendable, Codable {
    /// The rule's actions.
    public var actions: [PushAction]

    public init(actions: [PushAction] = []) {
        self.actions = actions
    }
}
