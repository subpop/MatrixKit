import Testing

@testable import MatrixKit

/// Pure space-graph traversal (``SpacesClient/ancestorPath`` and
/// ``SpacesClient/descendantIds``) over a caller-supplied
/// parent-to-children map. No harness: the walks never touch the
/// network.
@Suite("SpaceGraph")
struct SpaceGraphTests {
    // MARK: - Tables

    struct AncestorCase: Sendable {
        var id: String
        var target: String
        var children: [RoomId: Set<RoomId>]
        var rootedIn: Set<RoomId>
        var expected: [RoomId]
    }

    private static func ids(_ values: String...) -> Set<RoomId> {
        Set(values.map { RoomId(unchecked: $0) })
    }

    private static func id(_ value: String) -> RoomId {
        RoomId(unchecked: value)
    }

    nonisolated static let ancestorCases: [AncestorCase] = [
        AncestorCase(
            id: "deep chain walks transitively root-first",
            target: "!backend:example.com",
            children: [
                id("!work:example.com"): ids("!engineering:example.com"),
                id("!engineering:example.com"): ids("!backend:example.com"),
            ],
            rootedIn: [],
            expected: [id("!work:example.com"), id("!engineering:example.com")]),
        AncestorCase(
            id: "top-level space has no ancestors",
            target: "!work:example.com",
            children: [
                id("!work:example.com"): ids("!engineering:example.com"),
                id("!engineering:example.com"): ids("!backend:example.com"),
            ],
            rootedIn: [],
            expected: []),
        AncestorCase(
            id: "target absent from the graph has unknown ancestry",
            target: "!lost:example.com",
            children: [
                id("!work:example.com"): ids("!engineering:example.com"),
            ],
            rootedIn: [],
            expected: []),
        AncestorCase(
            id: "rooted chain wins over the other parent chain",
            target: "!backend:example.com",
            children: [
                id("!work:example.com"): ids("!eng:example.com"),
                id("!eng:example.com"): ids("!backend:example.com"),
                id("!personal:example.com"): ids("!side:example.com"),
                id("!side:example.com"): ids("!backend:example.com"),
            ],
            rootedIn: [id("!work:example.com")],
            expected: [id("!work:example.com"), id("!eng:example.com")]),
        AncestorCase(
            id: "alternate root picks the other chain",
            target: "!backend:example.com",
            children: [
                id("!work:example.com"): ids("!eng:example.com"),
                id("!engineering:example.com"): ids("!backend:example.com"),
                id("!personal:example.com"): ids("!side:example.com"),
                id("!side:example.com"): ids("!backend:example.com"),
            ],
            rootedIn: [id("!personal:example.com")],
            expected: [id("!personal:example.com"), id("!side:example.com")]),
        AncestorCase(
            id: "no rooted chain: shortest parentless chain wins",
            target: "!deep:example.com",
            children: [
                id("!a:example.com"): ids("!deep:example.com"),
                id("!z:example.com"): ids("!deep:example.com"),
                id("!base:example.com"): ids("!z:example.com"),
            ],
            rootedIn: [],
            expected: [id("!a:example.com")]),
        AncestorCase(
            id: "equal depth ties break by ID order",
            target: "!deep:example.com",
            children: [
                id("!a:example.com"): ids("!deep:example.com"),
                id("!z:example.com"): ids("!deep:example.com"),
            ],
            rootedIn: [],
            expected: [id("!a:example.com")]),
        AncestorCase(
            id: "mutual child edges terminate empty",
            target: "!a:example.com",
            children: [
                id("!a:example.com"): ids("!b:example.com"),
                id("!b:example.com"): ids("!a:example.com"),
            ],
            rootedIn: [],
            expected: []),
        AncestorCase(
            id: "self loop terminates empty",
            target: "!a:example.com",
            children: [
                id("!a:example.com"): ids("!a:example.com"),
            ],
            rootedIn: [],
            expected: []),
    ]

    struct DescendantCase: Sendable {
        var id: String
        var target: String
        var children: [RoomId: Set<RoomId>]
        var expected: Set<RoomId>
    }

    nonisolated static let descendantCases: [DescendantCase] = [
        DescendantCase(
            id: "closure spans multiple hops",
            target: "!fedora:example.com",
            children: [
                id("!fedora:example.com"): ids("!teams:example.com"),
                id("!teams:example.com"): ids("!room:example.com"),
            ],
            expected: ids("!teams:example.com", "!room:example.com")),
        DescendantCase(
            id: "cycles are safe and the space itself never appears",
            target: "!a:example.com",
            children: [
                id("!a:example.com"): ids("!b:example.com"),
                id("!b:example.com"): ids("!a:example.com"),
            ],
            expected: ids("!b:example.com")),
        DescendantCase(
            id: "unknown target yields an empty set",
            target: "!empty:example.com",
            children: [
                id("!a:example.com"): ids("!b:example.com"),
            ],
            expected: []),
    ]

    // MARK: - Tests

    @Test("ancestor walks", arguments: ancestorCases)
    func ancestorWalks(_ row: AncestorCase) {
        let path = SpacesClient.ancestorPath(
            of: RoomId(unchecked: row.target),
            children: row.children,
            rootedIn: row.rootedIn)
        #expect(path == row.expected, "\(row.id)")
    }

    @Test("descendant closures", arguments: descendantCases)
    func descendantClosures(_ row: DescendantCase) {
        let found = SpacesClient.descendantIds(
            of: RoomId(unchecked: row.target), children: row.children)
        #expect(found == row.expected, "\(row.id)")
    }
}
