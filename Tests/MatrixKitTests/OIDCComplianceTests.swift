import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// OIDC compliance suite: discovery, registration, the device flow
/// (approve + deny), code exchange, refresh, revocation, and the full
/// `AuthClient` device login + logout — all against a loopback issuer.
///
/// Exercised registry endpoints: `GET /v1/auth_metadata` (override —
/// post-v1.13 MSC3861) plus the harness-loopback issuer paths
/// (`/issuer/{register,device,token,revoke}`, registry overrides).
@Suite("OIDCCompliance")
struct OIDCComplianceTests {
    @Test("Discovery returns loopback issuer metadata")
    func discover() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let baseURL = await harness.baseURL
            let metadata = try #require(try await oidc.discover())
            #expect(metadata.issuer == "\(baseURL.absoluteString)/issuer")
            #expect(metadata.supportsDeviceFlow)
            #expect(metadata.supportsS256)
            let clientId = try await oidc.register(metadata: metadata, clientName: "Tests")
            #expect(clientId == "harness-client")
        }
    }

    @Test("Device flow approves and returns tokens")
    func deviceFlow() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            let auth = try await oidc.startDeviceFlow(
                metadata: metadata, clientId: "harness-client", deviceId: "OIDCDEV")
            #expect(auth.userCode == "WDJB-MJHT")
            // One pending poll (~1s), then approval.
            let tokens = try await oidc.pollDeviceToken(
                metadata: metadata, clientId: "harness-client",
                deviceCode: auth.deviceCode,
                intervalSeconds: auth.interval ?? 5,
                expiresInSeconds: auth.expiresIn)
            #expect(tokens.accessToken == "oidc-access-OIDCDEV")
            #expect(tokens.refreshToken == "oidc-refresh")
            #expect(tokens.expiresIn == 299)
        }
    }

    @Test("Device flow denial surfaces access_denied")
    func deviceDenial() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            let auth = try await oidc.startDeviceFlow(
                metadata: metadata, clientId: "harness-client", deviceId: "OIDCDEV")
            await world.denyNextDeviceFlow()
            await #expect(throws: MatrixError.serverError(
                code: "access_denied", message: "access_denied", retryAfter: nil))
            {
                try await oidc.pollDeviceToken(
                    metadata: metadata, clientId: "harness-client",
                    deviceCode: auth.deviceCode,
                    intervalSeconds: 1,
                    expiresInSeconds: 30)
            }
        }
    }

    @Test("Code exchange and refresh rotate tokens")
    func exchangeAndRefresh() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            let exchanged = try await oidc.exchangeCode(
                metadata: metadata, clientId: "harness-client",
                code: "auth-code", verifier: "verifier",
                redirectURI: "http://localhost/")
            #expect(exchanged.refreshToken == "oidc-refresh")
            let refreshed = try await oidc.refresh(
                tokenEndpoint: metadata.tokenEndpoint,
                clientId: "harness-client",
                refreshToken: "oidc-refresh")
            #expect(refreshed.accessToken.hasPrefix("oidc-access-"))
            await #expect(throws: MatrixError.serverError(
                code: "invalid_grant", message: "invalid_grant", retryAfter: nil))
            {
                try await oidc.refresh(
                    tokenEndpoint: metadata.tokenEndpoint,
                    clientId: "harness-client",
                    refreshToken: "bogus")
            }
        }
    }

    @Test("Revocation records tokens")
    func revoke() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            try await oidc.revoke(
                metadata: metadata, clientId: "harness-client", token: "tok-1")
            #expect(await world.recordedRevocations() == ["tok-1"])
        }
    }

    @Test("Full device login wires the session, logout revokes it")
    @MainActor
    func deviceLoginLogout() async throws {
        actor CodeBox {
            var shown: (code: String, url: String, expires: Int)?
            func set(_ value: (String, String, Int)) {
                shown = (code: value.0, url: value.1, expires: value.2)
            }
        }
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let transport = MatrixTransport(homeserver: baseURL)
            let session = Session(
                homeserver: baseURL,
                userId: UserId(unchecked: ""),
                deviceId: DeviceId(""),
                accessToken: "")
            let auth = AuthClient(transport: transport, session: session)
            let box = CodeBox()
            try await auth.loginViaOIDCDevice(
                clientName: "Tests",
                onUserCode: { code, url, expires in
                    await box.set((code, url, expires))
                })
            let shown = await box.shown
            #expect(shown?.code == "WDJB-MJHT")
            #expect(await session.accessToken == "oidc-access-OIDCDEV")
            #expect(await session.refreshToken == "oidc-refresh")
            #expect(await session.isOIDC)
            #expect(await session.oidcClientId == "harness-client")
            // OIDC logout revokes both tokens, hits legacy logout, and
            // invalidates locally.
            try await auth.logoutOIDC()
            let world = await harness.world
            let revoked = await world.recordedRevocations()
            #expect(revoked.contains("oidc-access-OIDCDEV"))
            #expect(revoked.contains("oidc-refresh"))
            #expect(!(await session.isValid))
            try? await transport.shutdown()
        }
    }

    @Test("Browser login prepares, completes, and adopts identity")
    @MainActor
    func browserLogin() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let pending = try await MatrixClient.prepareOIDCBrowserLogin(
                homeserver: baseURL,
                clientName: "Tests",
                redirectURI: "http://localhost/callback")
            #expect(pending.authorizationURL.absoluteString.contains("response_type=code"))
            #expect(pending.authorizationURL.absoluteString.contains("code_challenge_method=S256"))
            let client = try await MatrixClient.completeOIDCBrowserLogin(
                pending, code: "auth-code", state: pending.state)
            #expect(client.isAuthenticated)
            #expect(client.userId == UserId(unchecked: "@alice:test"))
            #expect(await client.session.oidcClientId == "harness-client")
            try? await client.transport.shutdown()
        }
    }

    @Test("Browser login rejects mismatched state")
    @MainActor
    func browserStateMismatch() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let pending = try await MatrixClient.prepareOIDCBrowserLogin(
                homeserver: baseURL,
                clientName: "Tests",
                redirectURI: "http://localhost/callback")
            // Wrong state rejects (and tears down the pending transport).
            await #expect(throws: MatrixError.serverError(
                code: "M_OIDC_STATE_MISMATCH",
                message: "OIDC redirect state does not match the request",
                retryAfter: nil))
            {
                try await MatrixClient.completeOIDCBrowserLogin(
                    pending, code: "auth-code", state: "wrong-state")
            }
        }
    }

    @Test("Facade device login returns an authenticated client")
    @MainActor
    func facadeDeviceLogin() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let client = try await MatrixClient.loginViaOIDC(
                homeserver: baseURL,
                clientName: "Tests",
                onUserCode: { _, _, _ in })
            #expect(client.isAuthenticated)
            #expect(client.userId == UserId(unchecked: "@alice:test"))
            try? await client.transport.shutdown()
        }
    }

    @Test("Device poll expiry surfaces expired_token")
    func pollExpiry() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            let auth = try await oidc.startDeviceFlow(
                metadata: metadata, clientId: "harness-client", deviceId: "OIDCDEV")
            await #expect(throws: MatrixError.serverError(
                code: "expired_token", message: "Device code expired before authorization",
                retryAfter: nil))
            {
                try await oidc.pollDeviceToken(
                    metadata: metadata, clientId: "harness-client",
                    deviceCode: auth.deviceCode,
                    intervalSeconds: 1,
                    expiresInSeconds: 1)
            }
        }
    }

    @Test("Legacy servers discover as nil")
    func discoverLegacy() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/auth_metadata",
                response: .matrixError(code: "M_UNRECOGNIZED", message: "nope", status: 404))
            let first = try await oidc.discover()
            #expect(first == nil)
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/auth_metadata",
                response: .raw("not json", status: 404))
            let second = try await oidc.discover()
            #expect(second == nil)
        }
    }

    @Test("Missing endpoints throw unsupported")
    func missingEndpoints() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let bare = AuthMetadata(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1/issuer/auth",
                tokenEndpoint: "http://127.0.0.1/issuer/token")
            await #expect(throws: MatrixError.serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Server did not advertise a registration endpoint",
                retryAfter: nil))
            {
                try await oidc.register(metadata: bare, clientName: "Tests")
            }
            await #expect(throws: MatrixError.serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Server did not advertise a device authorization endpoint",
                retryAfter: nil))
            {
                try await oidc.startDeviceFlow(
                    metadata: bare, clientId: "cid", deviceId: "D")
            }
            // Revocation without an endpoint is a silent no-op.
            try await oidc.revoke(metadata: bare, clientId: "cid", token: "tok")
        }
    }

    @Test("Poll cancellation surfaces a network error")
    func pollCancel() async throws {
        try await withHarness { harness in
            let (oidc, _) = await harness.oidcClient()
            let metadata = try #require(try await oidc.discover())
            let auth = try await oidc.startDeviceFlow(
                metadata: metadata, clientId: "harness-client", deviceId: "OIDCDEV")
            let task = Task {
                try await oidc.pollDeviceToken(
                    metadata: metadata, clientId: "harness-client",
                    deviceCode: auth.deviceCode,
                    intervalSeconds: 30,
                    expiresInSeconds: 300)
            }
            task.cancel()
            await #expect(throws: MatrixError.networkError(
                "Device authorization polling cancelled"))
            {
                try await task.value
            }
        }
    }

    @Test("Unbuildable authorization URLs throw invalidURL")
    func badAuthorizationURL() {
        let metadata = AuthMetadata(
            issuer: "x",
            authorizationEndpoint: "http://[::1",
            tokenEndpoint: "http://127.0.0.1/issuer/token")
        #expect(throws: MatrixError.self) {
            try OIDCClient.authorizationURL(
                metadata: metadata, clientId: "cid",
                redirectURI: "http://localhost/", deviceId: "D")
        }
    }
}
