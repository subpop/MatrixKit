import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Transport compliance suite: token-refresh retries, homeserver
/// resolution over the network, and decoding diagnostics.
///
/// Exercised: `MatrixTransport.send` retry paths, `resolveHomeserver`,
/// `decodeDetail`.
@Suite("TransportCompliance")
struct TransportComplianceTests {
    @Test("Unknown token retries once with a fresh token")
    func tokenRefreshRetry() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (auth, session, transport) = await harness.authClient()
            // Mint the rotated token up front; the refresher hands it out
            // when the first attempt dies with M_UNKNOWN_TOKEN.
            let (fresh, _) = await world.mintTokens(
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            await transport.setTokenRefresher { fresh }
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v3/account/whoami",
                response: .matrixError(
                    code: "M_UNKNOWN_TOKEN", message: "expired", status: 401))
            let who = try await auth.whoAmI()
            #expect(who.userId == UserId(unchecked: "@alice:test"))
            // The session still holds the old token; only the retry used
            // the fresh one.
            #expect(await session.accessToken == "harness-token-alice")
            let requests = await harness.requests.filter {
                $0.path == "/_matrix/client/v3/account/whoami"
            }
            #expect(requests.count == 2)
        }
    }

    @Test("Stale refresher surfaces the original unknown-token error")
    func tokenRefreshStale() async throws {
        try await withHarness { harness in
            let (auth, _, transport) = await harness.authClient()
            await transport.setTokenRefresher { "harness-token-alice" }
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v3/account/whoami",
                response: .matrixError(
                    code: "M_UNKNOWN_TOKEN", message: "expired", status: 401))
            await #expect(throws: MatrixError.unknownToken(softLogout: nil)) {
                try await auth.whoAmI()
            }
        }
    }

    @Test("Soft-logout hint survives error mapping", arguments: [true, false])
    func softLogoutHint(soft: Bool) async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient()
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v3/account/whoami",
                response: .raw(
                    #"{"errcode":"M_UNKNOWN_TOKEN","error":"gone","soft_logout":\#(soft)}"#,
                    status: 401))
            do {
                _ = try await auth.whoAmI()
                Issue.record("expected throw")
            } catch let error as MatrixError {
                #expect(error == .unknownToken(softLogout: soft))
            }
        }
    }

    @Test("Homeserver resolution adopts, validates, and falls back")
    func resolveHomeserver() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            // Well-known points at the harness itself: adopted.
            #expect(await MatrixTransport.resolveHomeserver(declared: baseURL) == baseURL)
            // Missing document falls back.
            await harness.setOverride(
                method: "GET", path: "/.well-known/matrix/client",
                response: .matrixError(code: "M_NOT_FOUND", message: "nope", status: 404))
            #expect(await MatrixTransport.resolveHomeserver(declared: baseURL) == baseURL)
        }
    }

    @Test("Decoding failures name the key and path", arguments: [
        (#"{"access_token":"t","device_id":"D"}"#, "missing key 'user_id'"),
        (#"{"user_id":"@a:b","access_token":null,"device_id":"D"}"#, "missing value"),
        (#"{"user_id":42,"access_token":"t","device_id":"D"}"#, "type mismatch"),
    ])
    func decodeDetail(json: String, expected: String) async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "POST", path: "/_matrix/client/v3/login",
                response: .raw(json, status: 200))
            let (auth, _, _) = await harness.authClient(token: "")
            do {
                try await auth.login(user: "alice", password: "secret")
                Issue.record("expected decodingError")
            } catch MatrixError.decodingError(let message) {
                #expect(message.contains(expected))
                #expect(message.contains("/_matrix/client/v3/login"))
            }
        }
    }

    @Test("Byte uploads retry once with a fresh token")
    func sendBytesRetry() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (media, _, transport) = await harness.mediaClient()
            let (fresh, _) = await world.mintTokens(
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            await transport.setTokenRefresher { fresh }
            await harness.setOverride(
                method: "POST", path: "/_matrix/media/v3/upload",
                response: .matrixError(
                    code: "M_UNKNOWN_TOKEN", message: "expired", status: 401))
            let uri = try await media.upload(Data("pixels".utf8), mimeType: "image/png")
            #expect(uri.value.hasPrefix("mxc://test/m"))
            let uploads = await harness.requests.filter {
                $0.path == "/_matrix/media/v3/upload"
            }
            #expect(uploads.count == 2)
        }
    }

    @Test("Discovery validation failures fall back", arguments: [true, false])
    func resolveFallbacks(invalidBase: Bool) async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            if invalidBase {
                await harness.setOverride(
                    method: "GET", path: "/.well-known/matrix/client",
                    response: .raw(
                        #"{"m.homeserver":{"base_url":"not-a-url"}}"#,
                        status: 200))
            } else {
                await harness.setOverride(
                    method: "GET", path: "/_matrix/client/versions",
                    response: .matrixError(
                        code: "M_NOT_FOUND", message: "nope", status: 404))
            }
            #expect(await MatrixTransport.resolveHomeserver(declared: baseURL) == baseURL)
        }
    }

    @Test("URL assembly rejects relative paths")
    func invalidURL() throws {
        #expect(throws: MatrixError.self) {
            try MatrixTransport.makeURLString(
                base: "https://matrix.example", path: "no-leading-slash", query: nil)
        }
    }

    /// One endpoint-classification case: the request path (or absolute
    /// URL) plus the expected `http.kind` tag, if any.
    struct EndpointKindCase: Sendable {
        var path: String
        var kind: MatrixTransport.HTTPLogKind?
    }

    @Test("Endpoint classification tags known classes", arguments: [
        EndpointKindCase(
            path: "/_matrix/client/v3/sendToDevice/m.room.encrypted/txn1",
            kind: .toDevice),
        EndpointKindCase(path: "/_matrix/client/v3/keys/query", kind: .keys),
        EndpointKindCase(path: "/_matrix/client/v3/keys/upload", kind: .keys),
        EndpointKindCase(path: "/_matrix/client/v3/keys/claim", kind: .keys),
        EndpointKindCase(
            path: "/_matrix/client/v3/keys/device_signing/upload", kind: .keys),
        EndpointKindCase(
            path: "/_matrix/client/v3/room_keys/version", kind: .keys),
        EndpointKindCase(path: "/_matrix/client/v3/sync", kind: .sync),
        EndpointKindCase(
            path: "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync",
            kind: .sync),
        EndpointKindCase(path: "/_matrix/media/v3/upload", kind: .media),
        EndpointKindCase(
            path: "/_matrix/client/v1/media/download/abc", kind: .media),
        EndpointKindCase(path: "/_matrix/client/v3/login", kind: .auth),
        EndpointKindCase(path: "/_matrix/client/v3/logout", kind: .auth),
        EndpointKindCase(path: "/_matrix/client/v3/refresh", kind: .auth),
        EndpointKindCase(
            path: "/_matrix/client/v3/register/available", kind: .auth),
        EndpointKindCase(path: "/.well-known/matrix/client", kind: .auth),
        EndpointKindCase(
            path: "/_matrix/client/versions", kind: .auth),
        EndpointKindCase(
            path: "/_matrix/client/v3/user/@a:b/openid/request_token",
            kind: .auth),
        EndpointKindCase(
            path: "https://issuer.example/token", kind: nil),
        EndpointKindCase(
            path: "/_matrix/client/v3/rooms/!x:y/send/m.room.message/t1",
            kind: nil),
        EndpointKindCase(
            path: "/_matrix/client/v3/user/@a:b/account_data/m.direct",
            kind: nil),
    ])
    func endpointKinds(_ row: EndpointKindCase) {
        #expect(MatrixTransport.endpointKind(for: row.path) == row.kind)
    }
}
