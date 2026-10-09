import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Search compliance suite: server-side message search with room and
/// sender filters, profile resolution, and empty results.
///
/// Exercised registry endpoints: `POST /_matrix/client/v3/search`.
@Suite("SearchCompliance")
struct SearchComplianceTests {
    @Test("Search matches bodies across rooms")
    func matches() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", body: "hello matrix")
            await world.stageMessage(roomId: "!b:test", body: "goodbye matrix")
            await world.stageMessage(roomId: "!b:test", body: "unrelated")
            let (search, _, _) = await harness.searchClient()
            let (results, _, total) = try await search.search(term: "matrix")
            #expect(results.count == 2)
            #expect(total == 2)
            #expect(results.allSatisfy { $0.body.localizedStandardContains("matrix") })
            #expect(results.first?.senderDisplayName == "Alice")
            let rooms = Set(results.map(\.roomId.value))
            #expect(rooms == ["!a:test", "!b:test"])
        }
    }

    @Test("Room and sender filters narrow results")
    func filters() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", sender: "@alice:test", body: "shared word")
            await world.stageMessage(roomId: "!b:test", sender: "@bob:test", body: "shared word")
            let (search, _, _) = await harness.searchClient()
            let roomFiltered = try await search.search(
                term: "shared",
                filter: MessageSearchFilter(roomIds: [RoomId(unchecked: "!a:test")]))
            #expect(roomFiltered.results.map(\.roomId.value) == ["!a:test"])
            let senderFiltered = try await search.search(
                term: "shared",
                filter: MessageSearchFilter(senderIds: [UserId(unchecked: "@bob:test")]))
            #expect(senderFiltered.results.map { $0.sender.value } == ["@bob:test"])
            let empty = try await search.search(term: "no-such-term-xyz")
            #expect(empty.results.isEmpty)
            #expect(empty.totalCount == 0)
        }
    }

    @Test("Search rejects invalid sessions without network")
    func searchGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let search = SearchClient(
            transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await search.search(term: "hi")
        }
        try? await transport.shutdown()
    }
}
