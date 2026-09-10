import Foundation

/// Authentication: login, token refresh, logout, session discovery.
public actor AuthClient {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    // MARK: - Login

    /// Password login (`m.login.password`).
    public func login(
        user: String,
        password: String,
        deviceId: DeviceId? = nil,
        initialDeviceDisplayName: String? = nil
    ) async throws(MatrixError) {
        let request = LoginRequest.password(
            user: user, password: password,
            deviceId: deviceId, initialDeviceDisplayName: initialDeviceDisplayName
        )
        let response: LoginResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/login", body: request)
        await session.update(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresInMs: response.expiresInMs
        )
    }

    /// Token login (`m.login.token`) — SSO, QR login, etc.
    public func loginWithToken(_ token: String, deviceId: DeviceId? = nil) async throws(MatrixError) {
        let request = LoginRequest.token(token, deviceId: deviceId)
        let response: LoginResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/login", body: request)
        await session.update(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresInMs: response.expiresInMs
        )
    }

    // MARK: - Registration

    /// Register a new account (`POST /register`). Usually UIAA-gated: the
    /// first attempt throws `MatrixError.uiaa`; complete a stage, then
    /// retry with `auth` set. On success the session picks up the new
    /// access token (unless `inhibitLogin` was set).
    @discardableResult
    public func register(
        username: String? = nil,
        password: String? = nil,
        deviceId: DeviceId? = nil,
        initialDeviceDisplayName: String? = nil,
        inhibitLogin: Bool? = nil,
        auth: UIAAuth? = nil
    ) async throws(MatrixError) -> RegisterResponse {
        let response: RegisterResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/register",
            body: RegisterRequest(
                username: username,
                password: password,
                deviceId: deviceId,
                initialDeviceDisplayName: initialDeviceDisplayName,
                inhibitLogin: inhibitLogin,
                auth: auth)
        )
        if let accessToken = response.accessToken {
            await session.update(
                accessToken: accessToken,
                refreshToken: response.refreshToken,
                expiresInMs: response.expiresInMs
            )
        }
        return response
    }

    /// Whether a username is available (`GET /register/available`).
    public func registerAvailable(username: String) async throws(MatrixError) -> Bool {
        let response: RegisterAvailable = try await transport.send(
            .get, path: "/_matrix/client/v3/register/available",
            query: ["username": username])
        return response.available
    }

    /// Deactivate the account (`POST /account/deactivate`). UIAA-gated:
    /// retry with `auth` after a 401 challenge. Invalidates the session.
    public func deactivateAccount(
        eraseDevices: Bool? = nil, auth: UIAAuth? = nil
    ) async throws(MatrixError) -> DeactivateAccountResponse {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let response: DeactivateAccountResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/account/deactivate",
            body: DeactivateAccountRequest(erase: eraseDevices, auth: auth),
            accessToken: token)
        await session.invalidate()
        return response
    }

    // MARK: - Refresh & logout

    /// Refresh the access token (`POST /refresh`).
    public func refresh() async throws(MatrixError) {
        // OIDC sessions rotate via the token endpoint, not /refresh.
        if await session.isOIDC {
            return try await refreshOIDC()
        }
        return try await refreshLegacy()
    }

    /// Refresh the access token via the legacy `POST /refresh` endpoint.
    private func refreshLegacy() async throws(MatrixError) {
        guard let refreshToken = await session.refreshToken else {
            throw .notAuthenticated
        }
        let response: LoginResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/refresh",
            body: RefreshRequest(refreshToken: refreshToken)
        )
        await session.update(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresInMs: response.expiresInMs
        )
    }

    /// Logout, invalidating the access token server-side.
    public func logout() async throws(MatrixError) {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/logout", accessToken: token)
        await session.invalidate()
    }

    /// Logout all devices (`POST /logout/all`).
    public func logoutAll() async throws(MatrixError) {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/logout/all", accessToken: token)
        await session.invalidate()
    }

    // MARK: - OIDC (MSC3861)

    private func oidc() -> OIDCClient {
        OIDCClient(transport: transport)
    }

    /// OIDC auth metadata, or nil on legacy servers (no `auth_metadata`).
    public func discoverOIDC() async throws(MatrixError) -> AuthMetadata? {
        try await oidc().discover()
    }

    /// Full OIDC device flow: discover → register → authorize → poll →
    /// session. `onUserCode` receives `(userCode, verificationURL,
    /// expiresInSeconds)` for display; polling starts once it returns.
    /// Throws `M_OIDC_UNSUPPORTED` on legacy or device-flow-less servers.
    public func loginViaOIDCDevice(
        clientName: String,
        clientURI: String? = nil,
        logoURI: String? = nil,
        redirectURIs: [String] = ["http://localhost/"],
        onUserCode: @Sendable (String, String, Int) async -> Void
    ) async throws(MatrixError) {
        let oidc = oidc()
        guard let metadata = try await oidc.discover() else {
            throw .serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Homeserver does not advertise OIDC auth metadata",
                retryAfter: nil
            )
        }
        let clientId = try await oidc.register(
            metadata: metadata,
            clientName: clientName,
            clientURI: clientURI,
            logoURI: logoURI,
            redirectURIs: redirectURIs,
            // `response_types: ["code"]` requires the authorization_code
            // grant even for device-only clients (MAS rejects otherwise),
            // so always include it alongside the device-code grant.
            grantTypes: OIDCClient.loginGrantTypes(metadata: metadata)
        )
        let deviceId = OIDCClient.makeDeviceID()
        let auth = try await oidc.startDeviceFlow(
            metadata: metadata, clientId: clientId, deviceId: deviceId)
        await onUserCode(
            auth.userCode, auth.verificationURIComplete ?? auth.verificationURI,
            auth.expiresIn)
        let tokens = try await oidc.pollDeviceToken(
            metadata: metadata, clientId: clientId,
            deviceCode: auth.deviceCode,
            intervalSeconds: auth.interval ?? 5,
            expiresInSeconds: auth.expiresIn)
        await session.update(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresInMs: tokens.expiresIn.map { $0 * 1000 })
        await session.updateOIDC(
            clientId: clientId, tokenEndpoint: metadata.tokenEndpoint)
    }

    /// Refresh an OIDC session via its token endpoint.
    public func refreshOIDC() async throws(MatrixError) {
        guard
            let refreshToken = await session.refreshToken,
            let clientId = await session.oidcClientId,
            let endpoint = await session.oidcTokenEndpoint
        else {
            throw .notAuthenticated
        }
        let tokens = try await oidc().refresh(
            tokenEndpoint: endpoint, clientId: clientId,
            refreshToken: refreshToken)
        await session.update(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresInMs: tokens.expiresIn.map { $0 * 1000 })
    }

    /// OIDC logout: best-effort revocation of both tokens, then legacy
    /// `/logout` (best-effort), then local invalidation (always).
    public func logoutOIDC() async throws(MatrixError) {
        let oidc = oidc()
        if let metadata = try? await oidc.discover(),
            let clientId = await session.oidcClientId
        {
            let access = await session.accessToken
            if !access.isEmpty {
                try? await oidc.revoke(
                    metadata: metadata, clientId: clientId, token: access)
            }
            if let refresh = await session.refreshToken {
                try? await oidc.revoke(
                    metadata: metadata, clientId: clientId, token: refresh)
            }
        }
        try? await logout()
        await session.invalidate()
    }

    // MARK: - Discovery

    /// Flows the server supports (`GET /login`).
    public func loginFlows() async throws(MatrixError) -> LoginFlows {
        try await transport.send(.get, path: "/_matrix/client/v3/login")
    }

    /// SSO login URL (`GET /login/sso/redirect...`): open in a browser;
    /// the IdP redirects back to `redirectURL` with a `loginToken` for
    /// `loginWithToken`. No transport request — the redirect itself is
    /// the request.
    public func ssoRedirectURL(
        redirectURL: String, providerId: String? = nil
    ) async -> URL? {
        var base = session.homeserver.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var path = "/_matrix/client/v3/login/sso/redirect"
        if let providerId {
            path += "/\(providerId.pathSegmentEncoded)"
        }
        return URL(string: "\(base)\(path)?redirectUrl=\(redirectURL.queryEncoded)")
    }

    /// Who owns the current access token (`GET /account/whoami`).
    public func whoAmI() async throws(MatrixError) -> WhoAmI {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return try await transport.send(
            .get, path: "/_matrix/client/v3/account/whoami", accessToken: token)
    }

    /// Server versions (`GET /versions`). Auth is optional per the spec,
    /// but authenticated requests reveal per-user unstable features, so
    /// the session token is attached when present.
    public func serverVersions() async throws(MatrixError) -> ServerVersions {
        let token = await session.accessToken
        return try await transport.send(
            .get, path: "/_matrix/client/versions",
            accessToken: token.isEmpty ? nil : token)
    }

    /// Server capabilities (`GET /capabilities`, authenticated).
    public func capabilities() async throws(MatrixError) -> ServerCapabilities {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return try await transport.send(
            .get, path: "/_matrix/client/v3/capabilities", accessToken: token)
    }

    /// Sessions on this account (`GET /devices`), flagging the current one.
    public func devices() async throws(MatrixError) -> [DeviceInfo] {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let current = await session.deviceId
        let response: DevicesResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/devices", accessToken: token)
        return response.devices.map { entry in
            DeviceInfo(
                deviceId: entry.deviceId,
                displayName: entry.displayName,
                lastSeenIP: entry.lastSeenIP,
                lastSeenTimestamp: entry.lastSeenTimestampMs.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1000)
                },
                isCurrentDevice: entry.deviceId == current)
        }
    }

    /// Delete a session (`DELETE /devices/{deviceId}`).
    public func deleteDevice(_ deviceId: DeviceId) async throws(MatrixError) {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let _: EmptyResponse = try await transport.send(
            .delete,
            path: "/_matrix/client/v3/devices/\(deviceId.value.pathSegmentEncoded)",
            accessToken: token)
    }

    /// One session's details (`GET /devices/{deviceId}`).
    public func device(_ deviceId: DeviceId) async throws(MatrixError) -> DeviceEntry {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return try await transport.send(
            .get,
            path: "/_matrix/client/v3/devices/\(deviceId.value.pathSegmentEncoded)",
            accessToken: token)
    }

    /// Rename a session (`PUT /devices/{deviceId}`). May be UIAA-gated:
    /// retry with `auth` after a 401 challenge.
    public func renameDevice(
        _ deviceId: DeviceId, displayName: String, auth: UIAAuth? = nil
    ) async throws(MatrixError) {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/devices/\(deviceId.value.pathSegmentEncoded)",
            body: RenameDeviceRequest(displayName: displayName, auth: auth),
            accessToken: token)
    }

    // MARK: - OpenID

    /// Request an OpenID token for the current session
    /// (`POST /user/{userId}/openid/request_token` with an empty body).
    /// Consumed by MatrixRTC credential exchange (MSC4143).
    public func openIDToken() async throws(MatrixError) -> OpenIDToken {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let userId = await session.userId
        return try await transport.send(
            .post,
            path: "/_matrix/client/v3/user/\(userId.value.pathSegmentEncoded)/openid/request_token",
            body: OpenIDTokenRequest(),
            accessToken: token)
    }
}
