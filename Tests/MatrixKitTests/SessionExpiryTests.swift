import Foundation
import Testing

@testable import MatrixKit

/// Session expiry bookkeeping: the absolute `expiresAt` derived from
/// each token update's advertised lifetime, and its presence in the
/// atomic credentials snapshot apps persist.
@Suite("SessionExpiry")
struct SessionExpiryTests {
    // MARK: - Tables

    struct LifetimeCase: Sendable {
        var id: String
        var expiresInMs: Int?
        var expectsExpiry: Bool
    }

    nonisolated static let lifetimeCases: [LifetimeCase] = [
        LifetimeCase(id: "advertised lifetime", expiresInMs: 300_000, expectsExpiry: true),
        LifetimeCase(id: "omitted lifetime", expiresInMs: nil, expectsExpiry: false),
        LifetimeCase(id: "zero lifetime", expiresInMs: 0, expectsExpiry: true),
    ]

    private func makeSession() -> Session {
        Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: "t0")
    }

    @Test("Token updates derive the absolute expiry", arguments: Self.lifetimeCases)
    func updateDerivesExpiry(_ row: LifetimeCase) async throws {
        let session = makeSession()
        let before = Date()
        await session.update(accessToken: "t1", expiresInMs: row.expiresInMs)
        let after = Date()
        let snapshot = await session.credentials
        guard let lifetime = row.expiresInMs else {
            #expect(snapshot.expiresAt == nil)
            return
        }
        let derived = try #require(snapshot.expiresAt)
        let expected = TimeInterval(lifetime) / 1000
        #expect(derived >= before.addingTimeInterval(expected))
        #expect(derived <= after.addingTimeInterval(expected))
    }

    @Test("A lifetime-less update clears a previous expiry")
    func updateClearsExpiry() async {
        let session = makeSession()
        await session.update(accessToken: "t1", expiresInMs: 300_000)
        #expect(await session.credentials.expiresAt != nil)
        await session.update(accessToken: "t2")
        #expect(await session.credentials.expiresAt == nil)
    }
}
