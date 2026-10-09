#if canImport(SwiftData)
import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit
@testable import MatrixKitSwiftData

/// Typed store reads: event decoding, edge-direction helpers, and
/// JSON-blob accessors over `SDRoom` rows.
@Suite("StoreReads")
struct StoreReadsTests {
    // MARK: - Tables

    struct EdgeCase: Sendable {
        var id: String
        var owner: String
        var peer: String
        var kind: SDEdgeKind
    }

    nonisolated static let graphEdges: [EdgeCase] = [
        EdgeCase(id: "child", owner: "!space:x", peer: "!room:x", kind: .child),
        EdgeCase(id: "parent", owner: "!room:x", peer: "!space:x", kind: .parent),
        EdgeCase(id: "canonical", owner: "!room:x", peer: "!space:x", kind: .canonicalParent),
    ]

    // MARK: - Event decoding

    @Test("Row decodes to its event")
    func messageEventRoundTrip() throws {
        let content = try JSONEncoder().encode([
            "msgtype": AnyCodable.string("m.text"),
            "body": AnyCodable.string("hello"),
        ])
        let row = SDRoomEvent(
            roomId: "!room:x", eventId: "$e:x", ts: 1_000,
            type: "m.room.message", sender: "@alice:x",
            content: content, isMessageLike: true)
        let event = try #require(row.messageEvent())
        #expect(event.eventId.value == "$e:x")
        #expect(event.messageContent?.body == "hello")
    }

    @Test("Corrupt payload decodes to nil")
    func messageEventCorrupt() {
        let row = SDRoomEvent(
            roomId: "!room:x", eventId: "$e:x", ts: 1_000,
            type: "m.room.message", sender: "@alice:x",
            content: Data("not-json".utf8))
        #expect(row.messageEvent() == nil)
    }

    // MARK: - Edge directions

    @Test("Parents resolve through child and parent edges", arguments: graphEdges)
    func parents(_ row: EdgeCase) {
        let edge = SDRoomEdge(ownerRoomId: row.owner, peerRoomId: row.peer, kind: row.kind)
        #expect(SDRoomEdge.parents(of: "!room:x", in: [edge]) == ["!space:x"])
        #expect(SDRoomEdge.parents(of: "!space:x", in: [edge]) == [])
    }

    @Test("Children resolve through child and parent edges", arguments: graphEdges)
    func children(_ row: EdgeCase) {
        let edge = SDRoomEdge(ownerRoomId: row.owner, peerRoomId: row.peer, kind: row.kind)
        #expect(SDRoomEdge.children(of: "!space:x", in: [edge]) == ["!room:x"])
        #expect(SDRoomEdge.children(of: "!room:x", in: [edge]) == [])
    }

    @Test("Descendants span hops and survive cycles")
    func descendants() {
        let edges = [
            SDRoomEdge(ownerRoomId: "!a:x", peerRoomId: "!b:x", kind: .child),
            SDRoomEdge(ownerRoomId: "!b:x", peerRoomId: "!c:x", kind: .child),
            SDRoomEdge(ownerRoomId: "!c:x", peerRoomId: "!a:x", kind: .child),
        ]
        #expect(SDRoomEdge.descendants(of: "!a:x", in: edges) == ["!b:x", "!c:x"])
        #expect(SDRoomEdge.descendants(of: "!ghost:x", in: edges) == [])
        #expect(SDRoomEdge.descendants(of: "!a:x", in: []) == [])
    }

    // MARK: - Blob accessors

    @Test("Hierarchy, pins, and aliases decode")
    func blobDecodes() throws {
        let room = SDRoom(roomId: "!space:x", membership: "join")
        room.hierarchyChildren = try JSONEncoder().encode([
            SpaceChild(roomId: RoomId(unchecked: "!room:x"))
        ])
        room.hierarchyDirectChildren = try JSONEncoder().encode([
            SpaceChildEdge(roomId: RoomId(unchecked: "!room:x"))
        ])
        room.pinnedEventIds = try JSONEncoder().encode(["$a:x"])
        room.altAliases = try JSONEncoder().encode(["#b:x"])
        #expect(room.decodedHierarchyChildren().map(\.roomId.value) == ["!room:x"])
        #expect(room.decodedHierarchyDirectChildren().map(\.roomId.value) == ["!room:x"])
        #expect(room.decodedPinnedEventIds() == ["$a:x"])
        #expect(room.decodedAltAliases() == ["#b:x"])
    }

    @Test("Missing and corrupt blobs read empty")
    func blobFallbacks() {
        let missing = SDRoom(roomId: "!a:x", membership: "join")
        #expect(missing.decodedHierarchyChildren().isEmpty)
        #expect(missing.decodedHierarchyDirectChildren().isEmpty)
        #expect(missing.decodedPinnedEventIds().isEmpty)
        #expect(missing.decodedAltAliases().isEmpty)
        let corrupt = SDRoom(roomId: "!b:x", membership: "join")
        corrupt.hierarchyChildren = Data("nope".utf8)
        corrupt.pinnedEventIds = Data("nope".utf8)
        #expect(corrupt.decodedHierarchyChildren().isEmpty)
        #expect(corrupt.decodedPinnedEventIds().isEmpty)
    }
}
#endif
