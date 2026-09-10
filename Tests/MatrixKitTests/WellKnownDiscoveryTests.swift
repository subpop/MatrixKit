import Foundation
import Testing

@testable import MatrixKit

/// `.well-known/matrix/client` discovery: adopt a valid delegated
/// `m.homeserver.base_url` (validated with `GET /versions`), fall back to
/// the declared URL on any failure. Hermetic via the `fetch` seam.
@Suite("WellKnownDiscovery")
struct WellKnownDiscoveryTests {
    private func fetch(
        _ bodies: [String: String]
    ) -> (@Sendable (URL) async throws -> Data) {
        { url in
            guard let body = bodies[url.absoluteString] else {
                throw MatrixError.unexpectedStatus(404, body: "not found")
            }
            return Data(body.utf8)
        }
    }

    private var versions: String {
        #"{"versions":["v1.0","v1.13"],"unstable_features":{}}"#
    }

    @Test("Delegated base_url is adopted when /versions validates")
    func adoptsDelegatedHomeserver() async {
        let declared = URL(string: "https://example.com")!
        let bodies = [
            "https://example.com/.well-known/matrix/client":
                #"{"m.homeserver":{"base_url":"https://matrix.example.com"}}"#,
            "https://matrix.example.com/_matrix/client/versions": versions,
        ]
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch(bodies))
        #expect(resolved.absoluteString == "https://matrix.example.com")
    }

    @Test("Missing well-known falls back to declared URL")
    func missingWellKnownFallsBack() async {
        let declared = URL(string: "https://example.com")!
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch([:]))
        #expect(resolved == declared)
    }

    @Test("Malformed well-known body falls back to declared URL")
    func malformedWellKnownFallsBack() async {
        let declared = URL(string: "https://example.com")!
        let bodies = [
            "https://example.com/.well-known/matrix/client": "not json"
        ]
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch(bodies))
        #expect(resolved == declared)
    }

    @Test("Non-https base_url falls back to declared URL")
    func httpBaseURLFallsBack() async {
        let declared = URL(string: "https://example.com")!
        let bodies = [
            "https://example.com/.well-known/matrix/client":
                #"{"m.homeserver":{"base_url":"http://matrix.example.com"}}"#,
            "http://matrix.example.com/_matrix/client/versions": versions,
        ]
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch(bodies))
        #expect(resolved == declared)
    }

    @Test("Failed /versions validation falls back to declared URL")
    func failedValidationFallsBack() async {
        let declared = URL(string: "https://example.com")!
        let bodies = [
            "https://example.com/.well-known/matrix/client":
                #"{"m.homeserver":{"base_url":"https://matrix.example.com"}}"#
        ]
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch(bodies))
        #expect(resolved == declared)
    }

    @Test("Declared URL with a path skips discovery")
    func pathSkipsDiscovery() async {
        let declared = URL(string: "https://example.com/custom")!
        nonisolated(unsafe) var fetched: [URL] = []
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared,
            fetch: { url in
                fetched.append(url)
                throw MatrixError.unexpectedStatus(404, body: "not found")
            })
        #expect(resolved == declared)
        #expect(fetched.isEmpty)
    }

    @Test("http loopback base_url is adopted")
    func loopbackAdopted() async {
        let declared = URL(string: "http://localhost:8008")!
        let bodies = [
            "http://localhost:8008/.well-known/matrix/client":
                #"{"m.homeserver":{"base_url":"http://localhost:8008"}}"#,
            "http://localhost:8008/_matrix/client/versions": versions,
        ]
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: declared, fetch: fetch(bodies))
        #expect(resolved.absoluteString == "http://localhost:8008")
    }
}
