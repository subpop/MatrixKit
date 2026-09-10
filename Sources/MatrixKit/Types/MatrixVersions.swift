/// Matrix spec / Client-Server API versions.

/// Versions advertised by `GET /versions` and negotiated per request.
public enum MatrixVersion: String, Hashable, Sendable, Codable, CaseIterable {
    case v1_0 = "v1.0"
    case v1_1 = "v1.1"
    case v1_2 = "v1.2"
    case v1_3 = "v1.3"
    case v1_4 = "v1.4"
    case v1_5 = "v1.5"
    case v1_6 = "v1.6"
    case v1_7 = "v1.7"
    case v1_8 = "v1.8"
    case v1_9 = "v1.9"
    case v1_10 = "v1.10"
    case v1_11 = "v1.11"
    case v1_12 = "v1.12"
    case v1_13 = "v1.13"
    case v1_14 = "v1.14"
    case v1_15 = "v1.15"
    case v1_16 = "v1.16"
    case v1_17 = "v1.17"
    case v1_18 = "v1.18"
    case v1_19 = "v1.19"

    /// The minimum version MatrixKit requires from a homeserver.
    public static let minimumSupported: MatrixVersion = .v1_0

    /// The newest version MatrixKit targets.
    public static let latestKnown: MatrixVersion = .v1_19

    /// Whether this version is at least `other`.
    public func isAtLeast(_ other: MatrixVersion) -> Bool {
        allCasesOrdered.firstIndex(of: self)! >= allCasesOrdered.firstIndex(of: other)!
    }

    private var allCasesOrdered: [MatrixVersion] { MatrixVersion.allCases }
}

/// Response body of `GET /_matrix/client/versions`.
public struct ServerVersions: Hashable, Sendable, Codable {
    /// Spec versions the server supports (e.g. `["v1.0", …, "v1.13"]`).
    public var versions: [String]
    /// Unstable feature flags (`feature → enabled`) for MSC-gated behavior
    /// such as sliding sync.
    public var unstableFeatures: [String: Bool]

    public init(versions: [String], unstableFeatures: [String: Bool] = [:]) {
        self.versions = versions
        self.unstableFeatures = unstableFeatures
    }

    private enum CodingKeys: String, CodingKey {
        case versions
        case unstableFeatures = "unstable_features"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decode([String].self, forKey: .versions)
        // Absent flags mean nothing advertised (per spec, a missing
        // `unstable_features` block indicates no support).
        unstableFeatures = try container.decodeIfPresent(
            [String: Bool].self, forKey: .unstableFeatures) ?? [:]
    }

    /// Whether the advertised `versions` include at least `version`.
    /// Unknown-but-newer version strings (e.g. a future `v1.20`) satisfy
    /// older requirements; unparseable entries are ignored.
    public func supportsVersion(_ version: MatrixVersion) -> Bool {
        guard let required = Self.numericVersion(version.rawValue) else {
            return false
        }
        return versions.compactMap(Self.numericVersion(_:)).contains {
            $0 >= required
        }
    }

    /// Whether `unstable_features` advertises `name` as enabled.
    /// Missing flags (or a missing `unstable_features` block) read false.
    public func hasUnstableFeature(_ name: String) -> Bool {
        unstableFeatures[name] ?? false
    }

    /// Parse `"v1.13"` / `"r0.0.1"` into a comparable `(major, minor)`.
    private static func numericVersion(_ string: String) -> (Int, Int)? {
        var text = string
        if text.hasPrefix("v") || text.hasPrefix("r") { text.removeFirst() }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }
}

/// Well-known `unstable_features` flags MatrixKit consults.
public enum UnstableFeature {
    /// Simplified sliding sync (`POST .../unstable/org.matrix
    /// .simplified_msc3575/sync`), as served by Synapse. The spec reserves
    /// `unstable_features` for exactly this: advertising not-yet-stable
    /// behavior, never for toggling stable spec parts.
    public static let simplifiedSlidingSync = "org.matrix.simplified_msc3575"
}

/// Response body of `GET /_matrix/client/v3/capabilities`.
public struct ServerCapabilities: Hashable, Sendable, Codable {
    /// Supported room versions and the server default for new rooms.
    public var roomVersions: RoomVersionsCapability?
    /// Whether the account password may be changed.
    public var changePassword: BoolCapability?
    /// Whether the account displayname may be changed.
    public var setDisplayName: BoolCapability?
    /// Whether the account avatar may be changed.
    public var setAvatarURL: BoolCapability?
    /// Whether 3PIDs may be added/removed on the account.
    public var threePIDChanges: BoolCapability?
    /// Whether `POST /login/get_token` is available.
    public var getLoginToken: BoolCapability?

    public init(
        roomVersions: RoomVersionsCapability? = nil,
        changePassword: BoolCapability? = nil,
        setDisplayName: BoolCapability? = nil,
        setAvatarURL: BoolCapability? = nil,
        threePIDChanges: BoolCapability? = nil,
        getLoginToken: BoolCapability? = nil
    ) {
        self.roomVersions = roomVersions
        self.changePassword = changePassword
        self.setDisplayName = setDisplayName
        self.setAvatarURL = setAvatarURL
        self.threePIDChanges = threePIDChanges
        self.getLoginToken = getLoginToken
    }

    /// Whether the account password may be changed (default when
    /// unadvertised: true).
    public var canChangePassword: Bool { changePassword?.enabled ?? true }
    /// Whether the account displayname may be changed (default: true).
    public var canSetDisplayName: Bool { setDisplayName?.enabled ?? true }
    /// Whether the account avatar may be changed (default: true).
    public var canSetAvatarURL: Bool { setAvatarURL?.enabled ?? true }
    /// Whether 3PIDs may be added/removed (default: true).
    public var canChangeThreePIDs: Bool { threePIDChanges?.enabled ?? true }
    /// The server default for new rooms, if advertised.
    public var defaultRoomVersion: String? { roomVersions?.default }

    private enum OuterKeys: String, CodingKey { case capabilities }

    private enum CapabilityKeys: String, CodingKey {
        case roomVersions = "m.room_versions"
        case changePassword = "m.change_password"
        case setDisplayName = "m.set_displayname"
        case setAvatarURL = "m.set_avatar_url"
        case threePIDChanges = "m.3pid_changes"
        case getLoginToken = "m.get_login_token"
    }

    public init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        // A missing envelope means no advertised capabilities; unknown
        // `m.*` capabilities are ignored.
        guard
            let capabilities = try? outer.nestedContainer(
                keyedBy: CapabilityKeys.self, forKey: .capabilities)
        else {
            roomVersions = nil
            changePassword = nil
            setDisplayName = nil
            setAvatarURL = nil
            threePIDChanges = nil
            getLoginToken = nil
            return
        }
        roomVersions = try capabilities.decodeIfPresent(
            RoomVersionsCapability.self, forKey: .roomVersions)
        changePassword = try capabilities.decodeIfPresent(
            BoolCapability.self, forKey: .changePassword)
        setDisplayName = try capabilities.decodeIfPresent(
            BoolCapability.self, forKey: .setDisplayName)
        setAvatarURL = try capabilities.decodeIfPresent(
            BoolCapability.self, forKey: .setAvatarURL)
        threePIDChanges = try capabilities.decodeIfPresent(
            BoolCapability.self, forKey: .threePIDChanges)
        getLoginToken = try capabilities.decodeIfPresent(
            BoolCapability.self, forKey: .getLoginToken)
    }

    public func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: OuterKeys.self)
        var capabilities = outer.nestedContainer(
            keyedBy: CapabilityKeys.self, forKey: .capabilities)
        try capabilities.encodeIfPresent(roomVersions, forKey: .roomVersions)
        try capabilities.encodeIfPresent(changePassword, forKey: .changePassword)
        try capabilities.encodeIfPresent(setDisplayName, forKey: .setDisplayName)
        try capabilities.encodeIfPresent(setAvatarURL, forKey: .setAvatarURL)
        try capabilities.encodeIfPresent(threePIDChanges, forKey: .threePIDChanges)
        try capabilities.encodeIfPresent(getLoginToken, forKey: .getLoginToken)
    }
}

/// A capability toggled by an `enabled` flag
/// (`m.change_password`, `m.set_displayname`, `m.set_avatar_url`,
/// `m.3pid_changes`, `m.get_login_token`).
public struct BoolCapability: Hashable, Sendable, Codable {
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// The `m.room_versions` capability: supported room versions (`version →
/// stability label`) and the server default for new rooms.
public struct RoomVersionsCapability: Hashable, Sendable, Codable {
    public var `default`: String
    public var available: [String: String]

    public init(default defaultVersion: String, available: [String: String] = [:]) {
        self.default = defaultVersion
        self.available = available
    }
}
