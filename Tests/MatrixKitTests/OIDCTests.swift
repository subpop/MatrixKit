import Foundation
import Testing

@testable import MatrixKit

private let sampleMetadataJSON = """
    {
      "issuer": "https://account.matrix.org/",
      "authorization_endpoint": "https://account.matrix.org/oauth2/auth",
      "token_endpoint": "https://account.matrix.org/oauth2/token",
      "registration_endpoint": "https://account.matrix.org/oauth2/clients/register",
      "revocation_endpoint": "https://account.matrix.org/oauth2/revoke",
      "device_authorization_endpoint": "https://account.matrix.org/oauth2/device",
      "code_challenge_methods_supported": ["S256"],
      "grant_types_supported": ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"],
      "account_management_uri": "https://account.matrix.org/manage"
    }
    """

private let sampleTokenJSON = """
    {
      "access_token": "swordfish",
      "token_type": "Bearer",
      "expires_in": 299,
      "refresh_token": "swordfish",
      "scope": "urn:matrix:client:api:* urn:matrix:client:device:AAABBBCCCDDD",
      "device_id": "AAABBBCCCDDD"
    }
    """

private let sampleDeviceJSON = """
    {
      "device_code": "GmRhmhcxhwAzkoEqiMEg_DnyEysNkuNhszIySk9eS",
      "user_code": "WDJB-MJHT",
      "verification_uri": "https://account.matrix.org/link",
      "verification_uri_complete": "https://account.matrix.org/link?user_code=WDJB-MJHT",
      "expires_in": 1800,
      "interval": 5
    }
    """

@Suite("OIDC")
struct OIDCTests {
    @Test("PKCE S256 matches the RFC 7636 test vector")
    func pkceVector() {
        // RFC 7636 Appendix B.
        let challenge = OIDCClient.codeChallengeS256(
            for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Code verifier is 43 unreserved chars")
    func verifierShape() {
        let verifier = OIDCClient.makeCodeVerifier()
        #expect(verifier.count == 43)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~"))
        #expect(verifier.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test("Device ID is 12 alphanumerics")
    func deviceIDShape() {
        let id = OIDCClient.makeDeviceID()
        #expect(id.count == 12)
        #expect(id.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains))
    }

    @Test("Auth metadata decodes with capability flags")
    func metadata() throws {
        let metadata = try JSONDecoder().decode(
            AuthMetadata.self, from: Data(sampleMetadataJSON.utf8))
        #expect(metadata.issuer == "https://account.matrix.org/")
        #expect(metadata.supportsDeviceFlow)
        #expect(metadata.supportsS256)
    }

    @Test("Token response decodes with seconds expiry")
    func token() throws {
        let tokens = try JSONDecoder().decode(
            OIDCTokenResponse.self, from: Data(sampleTokenJSON.utf8))
        #expect(tokens.accessToken == "swordfish")
        #expect(tokens.expiresIn == 299)
        #expect(tokens.refreshToken == "swordfish")
        #expect(tokens.deviceId == "AAABBBCCCDDD")
    }

    @Test("Device authorization decodes")
    func device() throws {
        let auth = try JSONDecoder().decode(
            DeviceAuthorizationResponse.self, from: Data(sampleDeviceJSON.utf8))
        #expect(auth.userCode == "WDJB-MJHT")
        #expect(auth.expiresIn == 1800)
        #expect(auth.interval == 5)
        #expect(auth.verificationURIComplete?.contains("WDJB-MJHT") == true)
    }

    @Test("Registration request uses none auth + native type")
    func registrationEncoding() throws {
        let request = OIDCRegistrationRequest(clientName: "MatrixKitCLI")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["token_endpoint_auth_method"] as? String == "none")
        #expect(json?["application_type"] as? String == "native")
    }

    @Test("Registration request carries branding URIs when set")
    func registrationBranding() throws {
        let request = OIDCRegistrationRequest(
            clientName: "Relay",
            clientURI: "https://subpop.github.io/Relay",
            logoURI: "https://subpop.github.io/Relay/logo-256.png",
            redirectURIs: ["io.github.subpop.relay:/"])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["client_uri"] as? String == "https://subpop.github.io/Relay")
        #expect(json?["logo_uri"] as? String == "https://subpop.github.io/Relay/logo-256.png")
        #expect(json?["redirect_uris"] as? [String] == ["io.github.subpop.relay:/"])

        let bare = OIDCRegistrationRequest(clientName: "Relay")
        let bareData = try JSONEncoder().encode(bare)
        let bareJSON = try JSONSerialization.jsonObject(with: bareData) as? [String: Any]
        #expect(bareJSON?["client_uri"] == nil)
        #expect(bareJSON?["logo_uri"] == nil)
    }

    @Test("Restore records OIDC metadata for later refreshes")
    func restoreOIDCMetadata() async {
        let client = await MatrixClient.restore(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: "@a:b"), deviceId: DeviceId("D"),
            accessToken: "t", refreshToken: "r",
            oidcClientId: "cid", oidcTokenEndpoint: "https://account.b/oauth2/token")
        #expect(await client.session.isOIDC == true)
        #expect(await client.session.oidcClientId == "cid")

        let legacy = await MatrixClient.restore(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: "@a:b"), deviceId: DeviceId("D"),
            accessToken: "t", refreshToken: "r")
        #expect(await legacy.session.isOIDC == false)
    }

    @Test("Scope strings use Matrix URNs")
    func scopes() {
        #expect(OIDCScope.apiFull == "urn:matrix:client:api:*")
        #expect(OIDCScope.device("ABC") == "urn:matrix:client:device:ABC")
        #expect(
            OIDCScope.scopeString(deviceId: "ABC")
                == "urn:matrix:client:api:* urn:matrix:client:device:ABC")
    }

    @Test("Authorization URL carries PKCE + scope params")
    func authorizationURL() throws {
        let metadata = try JSONDecoder().decode(
            AuthMetadata.self, from: Data(sampleMetadataJSON.utf8))
        let (url, state, verifier) = try OIDCClient.authorizationURL(
            metadata: metadata, clientId: "s6BhdRkqt3",
            redirectURI: "http://localhost:8080/callback",
            deviceId: "ABC", state: "fixed-state")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "s6BhdRkqt3")
        #expect(query["code_challenge_method"] == "S256")
        #expect(
            query["code_challenge"] == OIDCClient.codeChallengeS256(for: verifier))
        #expect(query["scope"] == OIDCScope.scopeString(deviceId: "ABC"))
        #expect(query["state"] == "fixed-state")
        #expect(state == "fixed-state")
    }

    @Test("OAuth error body decodes")
    func oauthError() throws {
        let data = Data(
            #"{"error":"authorization_pending","error_description":"waiting"}"#.utf8)
        let error = try JSONDecoder().decode(OIDCErrorResponse.self, from: data)
        #expect(error.error == "authorization_pending")
        #expect(error.errorDescription == "waiting")
    }

    @Test("Session tracks OIDC metadata and clears on invalidate")
    func sessionOIDC() async {
        let session = Session(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: "@a:b"), deviceId: DeviceId("D"),
            accessToken: "t")
        #expect(await session.isOIDC == false)
        await session.updateOIDC(
            clientId: "cid", tokenEndpoint: "https://account.b/oauth2/token")
        #expect(await session.isOIDC == true)
        #expect(await session.oidcClientId == "cid")
        await session.invalidate()
        #expect(await session.isOIDC == false)
        #expect(await session.oidcTokenEndpoint == nil)
    }

    @Test("MatrixVersion covers OIDC-era spec releases")
    func versions() {
        #expect(MatrixVersion.latestKnown == .v1_19)
        #expect(MatrixVersion.v1_19.isAtLeast(.v1_15))
        #expect(MatrixVersion.v1_15.isAtLeast(.v1_15))
        #expect(!MatrixVersion.v1_13.isAtLeast(.v1_15))
    }

    @Test("Login grants always include the code grant for MAS compatibility")
    func loginGrants() throws {
        let metadata = try JSONDecoder().decode(
            AuthMetadata.self, from: Data(sampleMetadataJSON.utf8))
        let grants = OIDCClient.loginGrantTypes(metadata: metadata)
        #expect(grants.contains("authorization_code"))
        #expect(grants.contains("refresh_token"))
        #expect(
            grants.contains("urn:ietf:params:oauth:grant-type:device_code"))
    }

    @Test("Account round-trips through the file store")
    func accountStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = OIDCAccountStore(directory: dir)
        #expect(store.load() == nil)
        let account = OIDCAccount(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: "@alice:matrix.org"),
            deviceId: DeviceId("ABC"), clientId: "cid",
            tokenEndpoint: "https://account.matrix.org/oauth2/token",
            accessToken: "at", refreshToken: "rt", expiresInSeconds: 299)
        try store.save(account)
        #expect(store.load() == account)
        try store.clear()
        #expect(store.load() == nil)
    }
}
