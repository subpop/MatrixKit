import Foundation
import Testing

@testable import MatrixKit

/// Decode + accessor tests for `GET /versions`
/// (`ServerVersions.supportsVersion`, `hasUnstableFeature`).
@Suite("Server versions")
struct MatrixVersionsTests {
    private func decode(_ json: String) throws -> ServerVersions {
        try JSONDecoder().decode(ServerVersions.self, from: Data(json.utf8))
    }

    private var body: String {
        #"{"versions":["v1.0","v1.13"],"unstable_features":{"org.matrix.simplified_msc3575":true,"org.example.disabled":false}}"#
    }

    @Test("Decodes versions and unstable flags")
    func decodesBody() throws {
        let versions = try decode(body)
        #expect(versions.versions == ["v1.0", "v1.13"])
        #expect(versions.unstableFeatures["org.matrix.simplified_msc3575"] == true)
    }

    @Test("Missing unstable_features decodes to empty")
    func missingFlagsDefaultEmpty() throws {
        let versions = try decode(#"{"versions":["v1.0"]}"#)
        #expect(versions.unstableFeatures.isEmpty)
        #expect(versions.hasUnstableFeature("org.matrix.simplified_msc3575") == false)
    }

    @Test("hasUnstableFeature honors the advertised value")
    func flagLookup() throws {
        let versions = try decode(body)
        #expect(versions.hasUnstableFeature("org.matrix.simplified_msc3575"))
        #expect(versions.hasUnstableFeature(UnstableFeature.simplifiedSlidingSync))
        #expect(!versions.hasUnstableFeature("org.example.disabled"))
        #expect(!versions.hasUnstableFeature("org.example.unlisted"))
    }

    @Test("supportsVersion matches advertised and older versions")
    func supportsAdvertised() throws {
        let versions = try decode(body)
        #expect(versions.supportsVersion(.v1_0))
        #expect(versions.supportsVersion(.v1_10))
        #expect(versions.supportsVersion(.v1_13))
    }

    @Test("supportsVersion rejects newer versions, accepts future unknowns")
    func supportsComparison() throws {
        let versions = try decode(body)
        #expect(!versions.supportsVersion(.v1_14))
        #expect(!versions.supportsVersion(.latestKnown))
        let future = ServerVersions(
            versions: ["v1.0", "v1.99"],
            unstableFeatures: [:])
        #expect(future.supportsVersion(.v1_10))
        #expect(future.supportsVersion(.latestKnown))
    }

    @Test("supportsVersion ignores legacy and malformed entries")
    func ignoresUnparseable() throws {
        let versions = ServerVersions(
            versions: ["r0.0.1", "not-a-version", "v1.5"],
            unstableFeatures: [:])
        #expect(versions.supportsVersion(.v1_5))
        #expect(!versions.supportsVersion(.v1_6))
        #expect(!ServerVersions(versions: [], unstableFeatures: [:]).supportsVersion(.v1_0))
    }
}

/// Offline gate tests: `MatrixClient.canUseSlidingSync` and the
/// `startSlidingSync`/`slidingSyncOnce` no-op on known-unsupported servers.
@Suite("Sliding sync support gate")
@MainActor
struct SlidingSyncGateTests {
    private func makeClient(versions: ServerVersions?) async -> (
        client: MatrixClient, transport: MatrixTransport
    ) {
        let url = URL(string: "https://example.com")!
        let transport = MatrixTransport(homeserver: url)
        let session = Session(
            homeserver: url,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "t")
        let client = await MatrixClient(
            homeserver: url, session: session, transport: transport,
            serverVersions: versions)
        return (client, transport)
    }

    @Test("Unknown versions proceed optimistically")
    func unknownProceeds() async {
        let (client, transport) = await makeClient(versions: nil)
        #expect(client.serverVersions == nil)
        #expect(client.canUseSlidingSync)
        try? await transport.shutdown()
    }

    @Test("Advertised flag proceeds")
    func advertisedProceeds() async {
        let versions = ServerVersions(
            versions: ["v1.13"],
            unstableFeatures: [UnstableFeature.simplifiedSlidingSync: true])
        let (client, transport) = await makeClient(versions: versions)
        #expect(client.canUseSlidingSync)
        try? await transport.shutdown()
    }

    @Test("Missing flag blocks the loop without network")
    func missingFlagNoops() async throws {
        let versions = ServerVersions(versions: ["v1.13"], unstableFeatures: [:])
        let (client, transport) = await makeClient(versions: versions)
        #expect(!client.canUseSlidingSync)
        try await client.startSlidingSync()
        #expect(client.slidingSyncStatus == .idle)
        try await client.slidingSyncOnce()
        #expect(client.slidingSyncStatus == .idle)
        try? await transport.shutdown()
    }
}
