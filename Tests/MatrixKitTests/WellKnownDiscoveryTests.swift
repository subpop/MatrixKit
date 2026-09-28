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

    private static let versions = #"{"versions":["v1.0","v1.13"],"unstable_features":{}}"#

    struct DiscoveryCase: Sendable {
        var id: String
        var declared: String
        var bodies: [String: String]
        var expected: String
    }

    static let discoveryCases: [DiscoveryCase] = [
        DiscoveryCase(
            id: "delegated base_url adopted",
            declared: "https://example.com",
            bodies: [
                "https://example.com/.well-known/matrix/client":
                    #"{"m.homeserver":{"base_url":"https://matrix.example.com"}}"#,
                "https://matrix.example.com/_matrix/client/versions": versions,
            ],
            expected: "https://matrix.example.com"),
        DiscoveryCase(
            id: "missing well-known falls back",
            declared: "https://example.com",
            bodies: [:],
            expected: "https://example.com"),
        DiscoveryCase(
            id: "malformed body falls back",
            declared: "https://example.com",
            bodies: ["https://example.com/.well-known/matrix/client": "not json"],
            expected: "https://example.com"),
        DiscoveryCase(
            id: "non-https base_url falls back",
            declared: "https://example.com",
            bodies: [
                "https://example.com/.well-known/matrix/client":
                    #"{"m.homeserver":{"base_url":"http://matrix.example.com"}}"#,
                "http://matrix.example.com/_matrix/client/versions": versions,
            ],
            expected: "https://example.com"),
        DiscoveryCase(
            id: "failed versions validation falls back",
            declared: "https://example.com",
            bodies: [
                "https://example.com/.well-known/matrix/client":
                    #"{"m.homeserver":{"base_url":"https://matrix.example.com"}}"#
            ],
            expected: "https://example.com"),
        DiscoveryCase(
            id: "http loopback adopted",
            declared: "http://localhost:8008",
            bodies: [
                "http://localhost:8008/.well-known/matrix/client":
                    #"{"m.homeserver":{"base_url":"http://localhost:8008"}}"#,
                "http://localhost:8008/_matrix/client/versions": versions,
            ],
            expected: "http://localhost:8008"),
    ]

    @Test("Discovery adopts or falls back", arguments: discoveryCases)
    func discovery(_ c: DiscoveryCase) async {
        let resolved = await MatrixTransport.resolveHomeserver(
            declared: URL(string: c.declared)!, fetch: fetch(c.bodies))
        #expect(resolved.absoluteString == c.expected)
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
}
