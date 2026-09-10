/// User-Interactive Authentication (UIAA, spec §13): the 401 challenge /
/// response dance endpoints use when an operation needs human approval
/// (cross-signing reset, password change, device deletion, ...).
///
/// A 401 response carries the challenge (`flows` of acceptable `stages` +
/// a `session` ID). The client completes stages out-of-band or inline,
/// then retries the request with an `auth` dict naming the completed
/// stage and the session.

/// One UIAA flow: an ordered list of stage types, any of which the client
/// may complete (single-stage flows are typical).
public struct UIAFlow: Hashable, Sendable, Codable {
    public var stages: [String]

    public init(stages: [String]) {
        self.stages = stages
    }
}

/// A 401 UIAA challenge body. `flows` is required so random error bodies
/// never decode as a challenge.
public struct UIAAChallenge: Hashable, Sendable, Codable {
    public var flows: [UIAFlow]
    public var session: String?
    public var params: [String: AnyCodable]?
    public var message: String?

    public init(
        flows: [UIAFlow],
        session: String? = nil,
        params: [String: AnyCodable]? = nil,
        message: String? = nil
    ) {
        self.flows = flows
        self.session = session
        self.params = params
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case flows
        case session
        case params
        case message = "msg"
    }

    /// UIAA stage that wipes the existing cross-signing identity and
    /// accepts the new keys. Destructive — confirm with the user first.
    public static let resetStage = "org.matrix.cross_signing_reset"
    /// UIAA stage completed by approving at an account-management URL.
    public static let oauthStage = "m.oauth"

    /// Whether any offered flow contains the given stage type.
    public func offersStage(_ stage: String) -> Bool {
        flows.contains { $0.stages.contains(stage) }
    }

    /// The per-stage approval URL from `params` (used by `m.oauth` and
    /// `org.matrix.cross_signing_reset` stages), if the server gave one.
    public func approvalURL(for stage: String) -> String? {
        params?[stage]?["url"]?.stringValue
    }
}

/// The `auth` dict attached to a retried request: the completed stage
/// plus the UIAA session being continued.
public struct UIAAuth: Hashable, Sendable, Codable {
    public var type: String
    public var session: String?

    public init(type: String, session: String? = nil) {
        self.type = type
        self.session = session
    }
}
