import Foundation

/// OIDC (MSC3861) authentication models: RFC 8414 metadata, RFC 7591
/// registration, RFC 8628 device flow, and token responses.

/// Authorization-server metadata (`GET /_matrix/client/v1/auth_metadata`,
/// RFC 8414). Absent (404 `M_UNRECOGNIZED`) on legacy servers.
public struct AuthMetadata: Hashable, Sendable, Codable {
    /// Issuer identifier (the MAS account host).
    public var issuer: String
    /// Browser authorization endpoint (code flow).
    public var authorizationEndpoint: String
    /// Token endpoint (code exchange, device polling, refresh).
    public var tokenEndpoint: String
    /// Dynamic client registration endpoint (RFC 7591), if advertised.
    public var registrationEndpoint: String?
    /// Token revocation endpoint (RFC 7009), if advertised.
    public var revocationEndpoint: String?
    /// Device authorization endpoint (RFC 8628, spec v1.18+), if advertised.
    public var deviceAuthorizationEndpoint: String?
    /// PKCE challenge methods the server accepts (want `S256`).
    public var codeChallengeMethodsSupported: [String]?
    /// Grant types the server accepts.
    public var grantTypesSupported: [String]?
    /// User-facing account management page.
    public var accountManagementURI: String?

    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String? = nil,
        revocationEndpoint: String? = nil,
        deviceAuthorizationEndpoint: String? = nil,
        codeChallengeMethodsSupported: [String]? = nil,
        grantTypesSupported: [String]? = nil,
        accountManagementURI: String? = nil
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.grantTypesSupported = grantTypesSupported
        self.accountManagementURI = accountManagementURI
    }

    /// Whether the RFC 8628 device flow can be used.
    public var supportsDeviceFlow: Bool {
        deviceAuthorizationEndpoint != nil
    }

    /// Whether PKCE `S256` challenges are accepted.
    public var supportsS256: Bool {
        codeChallengeMethodsSupported?.contains("S256") ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case deviceAuthorizationEndpoint = "device_authorization_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case grantTypesSupported = "grant_types_supported"
        case accountManagementURI = "account_management_uri"
    }
}

/// Token response shared by all grants (code, device, refresh).
/// `expiresIn` is in **seconds** (OAuth convention, unlike Matrix ms).
public struct OIDCTokenResponse: Hashable, Sendable, Codable {
    /// Bearer token for Client-Server API calls.
    public var accessToken: String
    /// Always `Bearer` for Matrix.
    public var tokenType: String
    /// Access-token lifetime in seconds, if advertised.
    public var expiresIn: Int?
    /// Refresh token for the refresh grant, if issued.
    public var refreshToken: String?
    /// Granted scopes (echo of the request).
    public var scope: String?
    /// Device ID the server allocated from the requested scope.
    public var deviceId: String?

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int? = nil,
        refreshToken: String? = nil,
        scope: String? = nil,
        deviceId: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.deviceId = deviceId
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case deviceId = "device_id"
    }
}

/// Dynamic client registration request (RFC 7591). Matrix clients are
/// public: no secret is issued, so `tokenEndpointAuthMethod` is `none`.
public struct OIDCRegistrationRequest: Hashable, Sendable, Codable {
    /// Human-readable client name shown on the consent screen.
    public var clientName: String
    /// Client home page, if any.
    public var clientURI: String?
    /// Client logo shown on the consent screen, if any.
    public var logoURI: String?
    /// Redirect URIs (required by RFC 7591; unused by the device flow).
    public var redirectURIs: [String]
    /// Must be `none` for public Matrix clients.
    public var tokenEndpointAuthMethod: String
    /// Matrix uses the authorization-code response only.
    public var responseTypes: [String]
    /// Grants this client will use (code, refresh, device-code).
    public var grantTypes: [String]
    /// `native` for installed/CLI apps.
    public var applicationType: String

    public init(
        clientName: String,
        clientURI: String? = nil,
        logoURI: String? = nil,
        redirectURIs: [String] = [],
        tokenEndpointAuthMethod: String = "none",
        responseTypes: [String] = ["code"],
        grantTypes: [String] = ["authorization_code", "refresh_token"],
        applicationType: String = "native"
    ) {
        self.clientName = clientName
        self.clientURI = clientURI
        self.logoURI = logoURI
        self.redirectURIs = redirectURIs
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.responseTypes = responseTypes
        self.grantTypes = grantTypes
        self.applicationType = applicationType
    }

    private enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case clientURI = "client_uri"
        case logoURI = "logo_uri"
        case redirectURIs = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case responseTypes = "response_types"
        case grantTypes = "grant_types"
        case applicationType = "application_type"
    }
}

/// Dynamic client registration response (RFC 7591). Only `clientId` is
/// needed afterwards; the rest is echoed metadata.
public struct OIDCRegistrationResponse: Hashable, Sendable, Codable {
    /// Assigned client identifier, sent with every token request.
    public var clientId: String

    public init(clientId: String) {
        self.clientId = clientId
    }

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
    }
}

/// Device authorization response (RFC 8628 §3.2). Show `userCode` plus
/// `verificationURIComplete` (falling back to `verificationURI`) and poll.
public struct DeviceAuthorizationResponse: Hashable, Sendable, Codable {
    /// Device code for polling (never shown to the user).
    public var deviceCode: String
    /// Short code the user types at the verification URI.
    public var userCode: String
    /// Page where the user authorizes the device.
    public var verificationURI: String
    /// Same page with the code pre-filled, when provided.
    public var verificationURIComplete: String?
    /// Device-code lifetime in seconds (polling deadline).
    public var expiresIn: Int
    /// Minimum seconds between token polls.
    public var interval: Int?

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: String,
        verificationURIComplete: String? = nil,
        expiresIn: Int,
        interval: Int? = nil
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// OAuth error body (RFC 6749 §5.2). Surfaced as
/// `MatrixError.serverError(code: error, …)` so callers match on stable
/// codes: `authorization_pending`, `slow_down`, `access_denied`,
/// `expired_token`, `invalid_grant`.
public struct OIDCErrorResponse: Hashable, Sendable, Codable {
    /// Machine-readable code (see above).
    public var error: String
    /// Human-readable detail, if provided.
    public var errorDescription: String?

    public init(error: String, errorDescription: String? = nil) {
        self.error = error
        self.errorDescription = errorDescription
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Matrix scope tokens (MSC2967): full API access plus a client-chosen
/// device ID the server allocates to the session.
public enum OIDCScope {
    /// Full Client-Server API access.
    public static let apiFull = "urn:matrix:client:api:*"

    /// Device-allocation scope for `deviceId`.
    public static func device(_ deviceId: String) -> String {
        "urn:matrix:client:device:\(deviceId)"
    }

    /// Scope string for login (API access + device allocation).
    public static func scopeString(deviceId: String) -> String {
        "\(apiFull) \(device(deviceId))"
    }
}

/// Persisted OIDC session for zero-interaction restore. Tokens live here
/// (file store is the CLI helper — apps should prefer the Keychain).
public struct OIDCAccount: Hashable, Sendable, Codable {
    /// Homeserver the account belongs to.
    public var homeserver: URL
    /// MXID from `whoami` after login.
    public var userId: UserId
    /// Device ID allocated via the login scope.
    public var deviceId: DeviceId
    /// RFC 7591 client identifier (needed for refresh/revoke).
    public var clientId: String
    /// Token endpoint (needed for refresh).
    public var tokenEndpoint: String
    /// Current bearer token.
    public var accessToken: String
    /// Refresh token, when issued.
    public var refreshToken: String?
    /// Access-token lifetime in seconds, when advertised.
    public var expiresInSeconds: Int?

    public init(
        homeserver: URL,
        userId: UserId,
        deviceId: DeviceId,
        clientId: String,
        tokenEndpoint: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresInSeconds: Int? = nil
    ) {
        self.homeserver = homeserver
        self.userId = userId
        self.deviceId = deviceId
        self.clientId = clientId
        self.tokenEndpoint = tokenEndpoint
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresInSeconds = expiresInSeconds
    }
}
