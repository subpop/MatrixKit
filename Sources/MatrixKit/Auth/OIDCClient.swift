import Crypto
import Foundation

/// OIDC authentication (MSC3861): metadata discovery, dynamic client
/// registration, authorization-code + PKCE, device flow, refresh, revocation.
///
/// Implemented natively on `MatrixTransport` — no OAuth library dependency.
/// OAuth error bodies are mapped to `MatrixError.serverError(code: …)` with
/// the RFC 6749 code (`authorization_pending`, `slow_down`,
/// `access_denied`, `expired_token`, `invalid_grant`), so callers match on
/// stable strings.
public actor OIDCClient {
    private let transport: MatrixTransport
    private let decoder = JSONDecoder()

    public init(transport: MatrixTransport) {
        self.transport = transport
    }

    // MARK: - Discovery & registration

    /// Fetch `/_matrix/client/v1/auth_metadata`. Returns nil on legacy
    /// servers (404 `M_UNRECOGNIZED`, or a non-JSON 404).
    public func discover() async throws(MatrixError) -> AuthMetadata? {
        do {
            return try await transport.send(
                .get, path: "/_matrix/client/v1/auth_metadata")
        } catch let error {
            switch error {
            case .serverError(let code, _, _) where code == "M_UNRECOGNIZED":
                return nil
            case .unexpectedStatus(404, _):
                return nil
            default:
                throw error
            }
        }
    }

    /// Register this client (RFC 7591). Returns the assigned `client_id`.
    ///
    /// - Parameter redirectURIs: defaults to the RFC 8252 loopback
    ///   `http://localhost/`. Strict servers (MAS) reject empty lists, so
    ///   even device-flow-only clients must send at least one.
    /// - Parameter clientURI: client homepage shown on the consent screen.
    ///   Strict servers (MAS) reject registration without one.
    /// - Parameter logoURI: client logo shown on the consent screen.
    public func register(
        metadata: AuthMetadata,
        clientName: String,
        clientURI: String? = nil,
        logoURI: String? = nil,
        redirectURIs: [String] = ["http://localhost/"],
        grantTypes: [String] = ["authorization_code", "refresh_token"]
    ) async throws(MatrixError) -> String {
        guard let endpoint = metadata.registrationEndpoint else {
            throw .serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Server did not advertise a registration endpoint",
                retryAfter: nil
            )
        }
        let request = OIDCRegistrationRequest(
            clientName: clientName, clientURI: clientURI, logoURI: logoURI,
            redirectURIs: redirectURIs, grantTypes: grantTypes
        )
        let (status, data) = try await transport.postJSON(
            url: endpoint, body: request)
        let response: OIDCRegistrationResponse = try decodeOAuth(
            status: status, data: data, what: "registration")
        return response.clientId
    }

    // MARK: - Device flow (RFC 8628, headless/CLI)

    /// Start the device flow. Show `userCode` + verification URI, then poll.
    public func startDeviceFlow(
        metadata: AuthMetadata,
        clientId: String,
        deviceId: String
    ) async throws(MatrixError) -> DeviceAuthorizationResponse {
        guard let endpoint = metadata.deviceAuthorizationEndpoint else {
            throw .serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Server did not advertise a device authorization endpoint",
                retryAfter: nil
            )
        }
        let (status, data) = try await transport.postForm(
            url: endpoint,
            form: [
                "client_id": clientId,
                "scope": OIDCScope.scopeString(deviceId: deviceId),
            ]
        )
        return try decodeOAuth(
            status: status, data: data, what: "device authorization")
    }

    /// Poll the token endpoint until the user authorizes, denies, or the
    /// device code expires. `slow_down` responses back the interval off.
    public func pollDeviceToken(
        metadata: AuthMetadata,
        clientId: String,
        deviceCode: String,
        intervalSeconds: Int,
        expiresInSeconds: Int
    ) async throws(MatrixError) -> OIDCTokenResponse {
        var interval = max(intervalSeconds, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(expiresInSeconds))
        while true {
            if Task.isCancelled {
                throw .networkError("Device authorization polling cancelled")
            }
            if Date() > deadline {
                throw .serverError(
                    code: "expired_token",
                    message: "Device code expired before authorization",
                    retryAfter: nil
                )
            }
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                throw .networkError("Device authorization polling cancelled")
            }
            let (status, data) = try await transport.postForm(
                url: metadata.tokenEndpoint,
                form: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": deviceCode,
                    "client_id": clientId,
                ]
            )
            if (200..<300).contains(status) {
                return try decodeToken(data: data)
            }
            let oauth = try decodeOAuthError(status: status, data: data)
            switch oauth.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            default:
                throw .serverError(
                    code: oauth.error,
                    message: oauth.errorDescription ?? oauth.error,
                    retryAfter: nil
                )
            }
        }
    }

    // MARK: - Code flow (browser/native apps)

    /// Exchange an authorization code for tokens (PKCE verifier required).
    public func exchangeCode(
        metadata: AuthMetadata,
        clientId: String,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws(MatrixError) -> OIDCTokenResponse {
        let (status, data) = try await transport.postForm(
            url: metadata.tokenEndpoint,
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientId,
                "code_verifier": verifier,
            ]
        )
        return try decodeOAuth(status: status, data: data, what: "code exchange")
    }

    /// Build the browser authorization URL (PKCE S256). Returns the URL plus
    /// the `state` (validate on callback) and `verifier` (for the exchange).
    public static func authorizationURL(
        metadata: AuthMetadata,
        clientId: String,
        redirectURI: String,
        deviceId: String,
        state: String? = nil
    ) throws(MatrixError) -> (url: URL, state: String, verifier: String) {
        let verifier = makeCodeVerifier()
        let resolvedState = state ?? makeState()
        var components = URLComponents(string: metadata.authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OIDCScope.scopeString(deviceId: deviceId)),
            URLQueryItem(name: "state", value: resolvedState),
            URLQueryItem(name: "code_challenge", value: codeChallengeS256(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else {
            throw .invalidURL(metadata.authorizationEndpoint)
        }
        return (url, resolvedState, verifier)
    }

    // MARK: - Refresh & revocation

    /// Refresh grant. Needs only the token endpoint + client ID.
    public func refresh(
        tokenEndpoint: String,
        clientId: String,
        refreshToken: String
    ) async throws(MatrixError) -> OIDCTokenResponse {
        let (status, data) = try await transport.postForm(
            url: tokenEndpoint,
            form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientId,
            ]
        )
        return try decodeOAuth(status: status, data: data, what: "token refresh")
    }

    /// Revoke a token (RFC 7009). Best-effort: callers ignore failures.
    /// No-op when the server advertises no revocation endpoint.
    public func revoke(
        metadata: AuthMetadata,
        clientId: String,
        token: String
    ) async throws(MatrixError) {
        guard let endpoint = metadata.revocationEndpoint else { return }
        let (status, data) = try await transport.postForm(
            url: endpoint,
            form: ["token": token, "client_id": clientId]
        )
        guard (200..<300).contains(status) else {
            let oauth = try decodeOAuthError(status: status, data: data)
            throw .serverError(
                code: oauth.error,
                message: oauth.errorDescription ?? oauth.error,
                retryAfter: nil
            )
        }
    }

    // MARK: - PKCE & device IDs

    /// Random `code_verifier` (RFC 7636 §4.1): 32 random bytes as
    /// unpadded base64url (43 chars, within the 43–128 range).
    public static func makeCodeVerifier() -> String {
        base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    /// S256 `code_challenge` for a verifier.
    public static func codeChallengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    /// Grant types for login registration: code + refresh always (MAS
    /// requires the `authorization_code` grant to accept `response_types:
    /// ["code"]`, even for device-only clients), plus the device-code grant
    /// when the server advertises its endpoint.
    public static func loginGrantTypes(metadata: AuthMetadata) -> [String] {
        var grants = ["authorization_code", "refresh_token"]
        if metadata.supportsDeviceFlow {
            grants.append("urn:ietf:params:oauth:grant-type:device_code")
        }
        return grants
    }

    /// Client-chosen device ID for the login scope (12 alphanumerics).
    public static func makeDeviceID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: - Private

    private static func makeState() -> String {
        base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func decodeOAuth<T: Decodable>(
        status: Int, data: Data, what: String
    ) throws(MatrixError) -> T {
        if (200..<300).contains(status) {
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw .decodingError("\(what): \(error.localizedDescription)")
            }
        }
        let oauth = try decodeOAuthError(status: status, data: data)
        throw .serverError(
            code: oauth.error,
            message: oauth.errorDescription ?? oauth.error,
            retryAfter: nil
        )
    }

    private func decodeToken(data: Data) throws(MatrixError) -> OIDCTokenResponse {
        do {
            return try decoder.decode(OIDCTokenResponse.self, from: data)
        } catch {
            throw .decodingError("device token: \(error.localizedDescription)")
        }
    }

    private func decodeOAuthError(
        status: Int, data: Data
    ) throws(MatrixError) -> OIDCErrorResponse {
        if let oauth = try? decoder.decode(OIDCErrorResponse.self, from: data) {
            return oauth
        }
        throw .unexpectedStatus(
            status, body: String(data: data, encoding: .utf8))
    }
}
