/// Authentication request/response models.

/// `POST /login` request body.
public struct LoginRequest: Hashable, Sendable, Codable {
    /// Login type (`m.login.password`, `m.login.token`, …).
    public var type: String
    /// User identifier. Preferred over legacy `user`.
    public var identifier: LoginIdentifier?
    /// Legacy user field. Prefer `identifier`.
    public var user: String?
    /// Password for `m.login.password`.
    public var password: String?
    /// Token for `m.login.token` (SSO / QR login).
    public var token: String?
    /// Requested device ID. Server generates one when omitted.
    public var deviceId: DeviceId?
    /// Human-readable device label shown in device lists.
    public var initialDeviceDisplayName: String?

    public init(
        type: String = LoginFlowType.password.rawValue,
        identifier: LoginIdentifier? = nil,
        user: String? = nil,
        password: String? = nil,
        token: String? = nil,
        deviceId: DeviceId? = nil,
        initialDeviceDisplayName: String? = nil
    ) {
        self.type = type
        self.identifier = identifier
        self.user = user
        self.password = password
        self.token = token
        self.deviceId = deviceId
        self.initialDeviceDisplayName = initialDeviceDisplayName
    }

    /// Convenience for `m.login.password` with a user identifier.
    public static func password(
        user: String,
        password: String,
        deviceId: DeviceId? = nil,
        initialDeviceDisplayName: String? = nil
    ) -> LoginRequest {
        LoginRequest(
            identifier: LoginIdentifier(type: "m.id.user", user: user),
            password: password,
            deviceId: deviceId,
            initialDeviceDisplayName: initialDeviceDisplayName
        )
    }

    /// Convenience for `m.login.token` (SSO / QR login).
    public static func token(_ token: String, deviceId: DeviceId? = nil) -> LoginRequest {
        LoginRequest(type: LoginFlowType.token.rawValue, token: token, deviceId: deviceId)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case identifier
        case user
        case password
        case token
        case deviceId = "device_id"
        case initialDeviceDisplayName = "initial_device_display_name"
    }
}

/// The `identifier` object inside a `LoginRequest`.
public struct LoginIdentifier: Hashable, Sendable, Codable {
    /// Identifier type (e.g. `m.id.user`).
    public var type: String
    /// The user, for `m.id.user` (full MXID or localpart).
    public var user: String?

    public init(type: String, user: String? = nil) {
        self.type = type
        self.user = user
    }
}

/// `POST /login` response body — the new session.
public struct LoginResponse: Hashable, Sendable, Codable {
    /// Logged-in user's fully-qualified MXID.
    public var userId: UserId
    /// Session access token for `Bearer` auth.
    public var accessToken: String
    /// Refresh token, when the server issues one.
    public var refreshToken: String?
    /// Device ID (echoed or server-generated).
    public var deviceId: DeviceId
    /// Access-token lifetime in milliseconds, when advertised.
    public var expiresInMs: Int?
    /// Server well-known (delegation hints), when provided.
    public var wellKnown: ClientWellKnown?

    public init(
        userId: UserId,
        accessToken: String,
        refreshToken: String? = nil,
        deviceId: DeviceId,
        expiresInMs: Int? = nil,
        wellKnown: ClientWellKnown? = nil
    ) {
        self.userId = userId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.expiresInMs = expiresInMs
        self.wellKnown = wellKnown
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case deviceId = "device_id"
        case expiresInMs = "expires_in_ms"
        case wellKnown = "well_known"
    }
}

/// `POST /refresh` request body.
public struct RefreshRequest: Hashable, Sendable, Codable {
    /// The refresh token from a previous login/refresh.
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

/// `GET /login` — flows the server supports.
public struct LoginFlows: Hashable, Sendable, Codable {
    /// Login flows the server supports (password, SSO, …).
    public var flows: [LoginFlow]

    public init(flows: [LoginFlow]) {
        self.flows = flows
    }
}

/// A single login flow entry.
public struct LoginFlow: Hashable, Sendable, Codable {
    /// Flow type (e.g. `m.login.password`).
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

/// `GET /account/whoami` response.
public struct WhoAmI: Hashable, Sendable, Codable {
    /// Owner of the access token.
    public var userId: UserId
    /// Token's device, when the server tracks one.
    public var deviceId: DeviceId?
    /// True for guest sessions.
    public var isGuest: Bool?

    public init(userId: UserId, deviceId: DeviceId? = nil, isGuest: Bool? = nil) {
        self.userId = userId
        self.deviceId = deviceId
        self.isGuest = isGuest
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case isGuest = "is_guest"
    }
}

/// `POST /register` request body. Registration is usually UIAA-gated:
/// the first attempt throws `MatrixError.uiaa`; complete a stage, then
/// retry with `auth` set.
public struct RegisterRequest: Hashable, Sendable, Codable {
    /// Desired user localpart (without `@`/server suffix).
    public var username: String?
    /// Account password, for password-based registration flows.
    public var password: String?
    /// Requested device ID. Server generates one when omitted.
    public var deviceId: DeviceId?
    /// Human-readable device label shown in device lists.
    public var initialDeviceDisplayName: String?
    /// Skip login: return a registration token instead of a session.
    public var inhibitLogin: Bool?
    /// Completed UIAA stage for retrying after a 401 challenge.
    public var auth: UIAAuth?

    public init(
        username: String? = nil,
        password: String? = nil,
        deviceId: DeviceId? = nil,
        initialDeviceDisplayName: String? = nil,
        inhibitLogin: Bool? = nil,
        auth: UIAAuth? = nil
    ) {
        self.username = username
        self.password = password
        self.deviceId = deviceId
        self.initialDeviceDisplayName = initialDeviceDisplayName
        self.inhibitLogin = inhibitLogin
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey {
        case username
        case password
        case deviceId = "device_id"
        case initialDeviceDisplayName = "initial_device_display_name"
        case inhibitLogin = "inhibit_login"
        case auth
    }
}

/// `POST /register` response body — the new account (and session, unless
/// `inhibit_login` was set).
public struct RegisterResponse: Hashable, Sendable, Codable {
    /// Newly registered user's fully-qualified MXID.
    public var userId: UserId
    /// Session access token (absent when login was inhibited).
    public var accessToken: String?
    /// Device ID (echoed or server-generated).
    public var deviceId: DeviceId?
    /// Access-token lifetime in milliseconds, when advertised.
    public var expiresInMs: Int?
    /// Refresh token, when the server issues one.
    public var refreshToken: String?

    public init(
        userId: UserId,
        accessToken: String? = nil,
        deviceId: DeviceId? = nil,
        expiresInMs: Int? = nil,
        refreshToken: String? = nil
    ) {
        self.userId = userId
        self.accessToken = accessToken
        self.deviceId = deviceId
        self.expiresInMs = expiresInMs
        self.refreshToken = refreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accessToken = "access_token"
        case deviceId = "device_id"
        case expiresInMs = "expires_in_ms"
        case refreshToken = "refresh_token"
    }
}

/// `GET /register/available` response body.
public struct RegisterAvailable: Hashable, Sendable, Codable {
    /// Whether the username can be registered.
    public var available: Bool

    public init(available: Bool) {
        self.available = available
    }
}

/// `POST /account/deactivate` request body. Deactivation is UIAA-gated:
/// retry with `auth` after a 401 challenge.
public struct DeactivateAccountRequest: Hashable, Sendable, Codable {
    /// Whether to erase all devices before deactivating.
    public var erase: Bool?
    /// Completed UIAA stage for retrying after a 401 challenge.
    public var auth: UIAAuth?

    public init(erase: Bool? = nil, auth: UIAAuth? = nil) {
        self.erase = erase
        self.auth = auth
    }
}

/// `POST /account/deactivate` response body.
public struct DeactivateAccountResponse: Hashable, Sendable, Codable {
    /// Identity-server unbind outcome (`success` or `no-support`).
    public var idServerUnbindResult: String?

    public init(idServerUnbindResult: String? = nil) {
        self.idServerUnbindResult = idServerUnbindResult
    }

    private enum CodingKeys: String, CodingKey {
        case idServerUnbindResult = "id_server_unbind_result"
    }
}
