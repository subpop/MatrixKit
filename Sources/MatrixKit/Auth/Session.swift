import Foundation

/// Authenticated session credentials. An actor so token refresh is race-free.
public actor Session {
    /// The homeserver these credentials belong to.
    public let homeserver: URL
    /// The logged-in user's MXID.
    public private(set) var userId: UserId
    /// The session's device ID.
    public private(set) var deviceId: DeviceId
    /// Current access token, sent as `Bearer` auth. Empty when logged out.
    public private(set) var accessToken: String
    /// Refresh token for `POST /refresh`, when the server issues one
    /// (MSC3824 / homeservers with expiring access tokens).
    public private(set) var refreshToken: String?
    /// Access-token lifetime in milliseconds, when advertised by the server.
    public private(set) var expiresInMs: Int?
    /// RFC 7591 client ID for OIDC sessions (needed for refresh/revoke).
    /// Nil for legacy password/token logins.
    public private(set) var oidcClientId: String?
    /// OIDC token endpoint for refreshes. Nil for legacy logins.
    public private(set) var oidcTokenEndpoint: String?

    public init(
        homeserver: URL,
        userId: UserId,
        deviceId: DeviceId,
        accessToken: String,
        refreshToken: String? = nil,
        expiresInMs: Int? = nil
    ) {
        self.homeserver = homeserver
        self.userId = userId
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresInMs = expiresInMs
    }

    /// Replace tokens after login or refresh.
    public func update(
        accessToken: String,
        refreshToken: String? = nil,
        expiresInMs: Int? = nil
    ) {
        self.accessToken = accessToken
        if let refreshToken {
            self.refreshToken = refreshToken
        }
        self.expiresInMs = expiresInMs
    }

    /// Adopt the server-assigned IDs after whoami reconciliation (the
    /// login-time IDs may be empty or unqualified).
    public func updateIDs(userId: UserId, deviceId: DeviceId?) {
        self.userId = userId
        if let deviceId {
            self.deviceId = deviceId
        }
    }

    /// Drop credentials (logout). Subsequent calls throw `notAuthenticated`.
    public func invalidate() {
        self.accessToken = ""
        self.refreshToken = nil
        self.oidcClientId = nil
        self.oidcTokenEndpoint = nil
    }

    /// True when an access token is present (does not validate it server-side).
    public var isValid: Bool {
        !accessToken.isEmpty
    }

    /// True for OIDC (MSC3861) sessions, which refresh via the OIDC token
    /// endpoint instead of `POST /refresh`.
    public var isOIDC: Bool {
        oidcClientId != nil
    }

    /// Record OIDC metadata after login or restore.
    public func updateOIDC(clientId: String, tokenEndpoint: String) {
        self.oidcClientId = clientId
        self.oidcTokenEndpoint = tokenEndpoint
    }
}
