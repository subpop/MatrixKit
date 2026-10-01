import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Auth compliance suite — the reference pattern for harness-backed,
/// table-driven component tests.
///
/// Exercised registry endpoints (`Tools/spec-registry/SPEC_VERSION`):
/// `POST /login`, `GET /login`, `POST /register`,
/// `GET /register/available`, `POST /account/deactivate`,
/// `POST /refresh`, `POST /logout`, `POST /logout/all`,
/// `GET /account/whoami`, `GET /versions`.
@Suite("AuthCompliance")
struct AuthComplianceTests {
    // MARK: - Tables

    struct LoginPasswordCase: Sendable {
        var id: String
        var user: String
        var password: String
        var succeeds: Bool
    }

    static let passwordCases: [LoginPasswordCase] = [
        LoginPasswordCase(id: "seeded user", user: "alice", password: "secret", succeeds: true),
        LoginPasswordCase(id: "qualified mxid", user: "@alice:test", password: "secret", succeeds: true),
        LoginPasswordCase(id: "wrong password", user: "alice", password: "wrong", succeeds: false),
        LoginPasswordCase(id: "unknown user", user: "mallory", password: "secret", succeeds: false),
        LoginPasswordCase(id: "empty password", user: "alice", password: "", succeeds: false),
    ]

    struct AvailabilityCase: Sendable {
        var username: String
        var available: Bool
    }

    /// Auth-guarded operations callable with no credentials. Every row
    /// must throw `.notAuthenticated` before any request leaves the SDK.
    enum GuardedCall: String, Sendable, CaseIterable {
        case deactivate
        case refresh
        case logout
        case logoutAll
        case whoami
        case capabilities
        case devices
        case device
        case deleteDevice
        case renameDevice
        case openIDToken
    }

    struct ErrorMappingCase: Sendable {
        var id: String
        var status: Int
        var body: String
        var expected: ExpectedError
    }

    enum ExpectedError: Sendable {
        case rateLimited
        case unknownToken
        case serverError(code: String)
        case decodingError
        case unexpectedStatus(code: Int)
    }

    static let errorCases: [ErrorMappingCase] = [
        ErrorMappingCase(
            id: "429 with retry hint",
            status: 429,
            body: #"{"errcode":"M_LIMIT_EXCEEDED","error":"slow down","retry_after_ms":1500}"#,
            expected: .rateLimited
        ),
        ErrorMappingCase(
            id: "429 without retry hint",
            status: 429,
            body: #"{"errcode":"M_LIMIT_EXCEEDED","error":"slow down"}"#,
            expected: .rateLimited
        ),
        ErrorMappingCase(
            id: "401 unknown token",
            status: 401,
            body: #"{"errcode":"M_UNKNOWN_TOKEN","error":"token dead"}"#,
            expected: .unknownToken
        ),
        ErrorMappingCase(
            id: "403 forbidden",
            status: 403,
            body: #"{"errcode":"M_FORBIDDEN","error":"nope"}"#,
            expected: .serverError(code: "M_FORBIDDEN")
        ),
        ErrorMappingCase(
            id: "200 malformed json",
            status: 200,
            body: #"{"user_id":42}"#,
            expected: .decodingError
        ),
        ErrorMappingCase(
            id: "500 html body",
            status: 500,
            body: "<html>bad gateway</html>",
            expected: .unexpectedStatus(code: 500)
        ),
    ]

    // MARK: - Login

    @Test("Password login succeeds or maps M_FORBIDDEN", arguments: passwordCases)
    func loginPassword(_ c: LoginPasswordCase) async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient(token: "")
            if c.succeeds {
                try await auth.login(user: c.user, password: c.password)
                let token = await session.accessToken
                #expect(!token.isEmpty)
                #expect(token.hasPrefix("harness-token-"))
                let who = try await auth.whoAmI()
                #expect(who.userId == UserId(unchecked: "@alice:test"))
            } else {
                await #expect(throws: MatrixError.serverError(code: "M_FORBIDDEN", message: "Invalid username or password", retryAfter: nil)) {
                    try await auth.login(user: c.user, password: c.password)
                }
            }
        }
    }

    @Test("Token login accepts the SSO token, rejects the rest", arguments: [true, false])
    func loginToken(valid: Bool) async throws {
        try await withHarness { harness in
            let world = await harness.world
            let ssoToken = await world.ssoLoginToken
            let (auth, session, _) = await harness.authClient(token: "")
            if valid {
                try await auth.loginWithToken(ssoToken)
                #expect(!(await session.accessToken).isEmpty)
            } else {
                await #expect(throws: MatrixError.serverError(code: "M_FORBIDDEN", message: "Invalid login token", retryAfter: nil)) {
                    try await auth.loginWithToken("bogus-token")
                }
            }
        }
    }

    @Test("Login sends a spec-shaped password request")
    func loginRequestShape() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient(token: "")
            try await auth.login(user: "alice", password: "secret", initialDeviceDisplayName: "Phone")
            let requests = await harness.requests
            #expect(requests.count == 1)
            let sent = try #require(requests.first)
            #expect(sent.method == "POST")
            #expect(sent.path == "/_matrix/client/v3/login")
            #expect(!sent.hadBearer)
            let body = try JSONDecoder().decode(LoginRequest.self, from: sent.body)
            #expect(body.type == "m.login.password")
            #expect(body.identifier?.user == "alice")
            #expect(body.password == "secret")
            #expect(body.initialDeviceDisplayName == "Phone")
        }
    }

    // MARK: - Registration (UIAA round-trip)

    @Test("Register challenges UIAA, then completes", arguments: [true, false])
    func registerUIAA(inhibitLogin: Bool) async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient(token: "")
            var challenge: UIAAChallenge?
            do {
                _ = try await auth.register(username: "bob", password: "pw", inhibitLogin: inhibitLogin)
                Issue.record("register without auth must throw UIAA")
            } catch let error as MatrixError {
                guard case .uiaa(let c) = error else {
                    Issue.record("expected UIAA, got \(error)")
                            return
                }
                challenge = c
            }
            let sessionId = try #require(challenge?.session)
            #expect(challenge?.offersStage("m.login.dummy") == true)
            let response = try await auth.register(
                username: "bob", password: "pw", inhibitLogin: inhibitLogin,
                auth: UIAAuth(type: "m.login.dummy", session: sessionId))
            #expect(response.userId == UserId(unchecked: "@bob:test"))
            if inhibitLogin {
                #expect(response.accessToken == nil)
                #expect(await session.accessToken == "")
            } else {
                #expect(!(response.accessToken ?? "").isEmpty)
                #expect(await session.accessToken == response.accessToken)
            }
        }
    }

    @Test("Register availability reflects taken names", arguments: [
        AvailabilityCase(username: "alice", available: false),
        AvailabilityCase(username: "some-fresh-name", available: true),
    ])
    func registerAvailable(_ c: AvailabilityCase) async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient(token: "")
            let available = try await auth.registerAvailable(username: c.username)
            #expect(available == c.available)
        }
    }

    // MARK: - Discovery

    @Test("Login flows and server versions decode")
    func discovery() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient(token: "")
            let flows = try await auth.loginFlows()
            #expect(flows.flows.map(\.type).contains("m.login.password"))
            let versions = try await auth.serverVersions()
            #expect(versions.supportsVersion(.v1_13))
        }
    }

    // MARK: - Refresh & logout

    @Test("Refresh rotates the access token")
    func refresh() async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient(token: "")
            try await auth.login(user: "alice", password: "secret")
            let before = await session.accessToken
            #expect(!(await session.refreshToken ?? "").isEmpty)
            try await auth.refresh()
            let after = await session.accessToken
            #expect(after != before)
            #expect(!after.isEmpty)
        }
    }

    @Test("Concurrent refreshes share one rotation")
    func concurrentRefreshSingleFlight() async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient(token: "")
            try await auth.login(user: "alice", password: "secret")
            async let first: Void = auth.refresh()
            async let second: Void = auth.refresh()
            async let third: Void = auth.refresh()
            try await first
            try await second
            try await third
            let refreshes = await harness.requests.filter {
                $0.method == "POST" && $0.path == "/_matrix/client/v3/refresh"
            }
            #expect(refreshes.count == 1)
            #expect(!(await session.accessToken).isEmpty)
        }
    }

    @Test("Logout and logout-all invalidate the session", arguments: [true, false])
    func logout(all: Bool) async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient(token: "")
            try await auth.login(user: "alice", password: "secret")
            #expect(await session.isValid)
            if all {
                try await auth.logoutAll()
            } else {
                try await auth.logout()
            }
            #expect(!(await session.isValid))
            await #expect(throws: MatrixError.notAuthenticated) {
                try await auth.logout()
            }
        }
    }

    @Test("Deactivate invalidates the session")
    func deactivate() async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient()
            let response = try await auth.deactivateAccount()
            #expect(response.idServerUnbindResult == "success")
            #expect(!(await session.isValid))
        }
    }

    // MARK: - Auth guards (offline — no request may leave the SDK)

    @Test("Unauthenticated calls throw before networking", arguments: GuardedCall.allCases)
    func authGuards(_ call: GuardedCall) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let auth = AuthClient(transport: transport, session: session)
        let device = DeviceId("D")
        switch call {
        case .deactivate:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.deactivateAccount() }
        case .refresh:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.refresh() }
        case .logout:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.logout() }
        case .logoutAll:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.logoutAll() }
        case .whoami:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.whoAmI() }
        case .capabilities:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.capabilities() }
        case .devices:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.devices() }
        case .device:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.device(device) }
        case .deleteDevice:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.deleteDevice(device) }
        case .renameDevice:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await auth.renameDevice(device, displayName: "X")
            }
        case .openIDToken:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.openIDToken() }
        }
        try? await transport.shutdown()
    }

    // MARK: - Error mapping (override-driven)

    @Test("Transport maps status bodies onto MatrixError", arguments: errorCases)
    func errorMapping(_ c: ErrorMappingCase) async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "POST", path: "/_matrix/client/v3/login",
                response: .raw(c.body, status: c.status))
            let (auth, _, _) = await harness.authClient(token: "")
            do {
                try await auth.login(user: "alice", password: "secret")
                Issue.record("expected throw for \(c.id)")
            } catch let error as MatrixError {
                #expect(matches(error, c.expected), "wrong mapping for \(c.id): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func matches(_ error: MatrixError, _ expected: ExpectedError) -> Bool {
        switch (error, expected) {
        case (.rateLimited, .rateLimited): return true
        case (.unknownToken, .unknownToken): return true
        case (.serverError(let code, _, _), .serverError(let want)): return code == want
        case (.decodingError, .decodingError): return true
        case (.unexpectedStatus(let code, _), .unexpectedStatus(let want)): return code == want
        default: return false
        }
    }

    @Test("OIDC sessions refresh through the token endpoint")
    func oidcRefresh() async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient()
            let baseURL = await harness.baseURL
            await session.update(
                accessToken: "old-access", refreshToken: "oidc-refresh",
                expiresInMs: nil)
            await session.updateOIDC(
                clientId: "harness-client",
                tokenEndpoint: "\(baseURL.absoluteString)/issuer/token")
            #expect(await session.isOIDC)
            try await auth.refresh()
            #expect((await session.accessToken).hasPrefix("oidc-access-"))
            // Missing OIDC metadata falls back to legacy refresh, which
            // needs a refresh token the session lacks.
            let (plain, plainSession, _) = await harness.authClient(token: "")
            await #expect(throws: MatrixError.notAuthenticated) {
                try await plain.refresh()
            }
            _ = plainSession
            _ = plain
        }
    }

    @Test("OIDC discovery surfaces metadata or nil")
    func oidcDiscover() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient()
            let metadata = try await auth.discoverOIDC()
            #expect(metadata?.issuer.hasSuffix("/issuer") == true)
        }
    }

    @Test("Rejected OIDC refresh token maps to unknown token")
    func oidcRefreshRejected() async throws {
        try await withHarness { harness in
            let (auth, session, _) = await harness.authClient()
            let baseURL = await harness.baseURL
            await session.update(
                accessToken: "old-access", refreshToken: "bogus",
                expiresInMs: nil)
            await session.updateOIDC(
                clientId: "harness-client",
                tokenEndpoint: "\(baseURL.absoluteString)/issuer/token")
            await #expect(throws: MatrixError.unknownToken(softLogout: nil)) {
                try await auth.refresh()
            }
        }
    }
}
