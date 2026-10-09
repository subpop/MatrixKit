#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// Normalized store foundation: schema CRUD, factory predicates, cascade
/// deletes, and container file handling.
@Suite("NormalizedStore")
@MainActor
struct NormalizedStoreTests {
    // MARK: - Tables

    struct RoomListCase: Sendable {
        var id: String
        var membership: String
        var isSpace: Bool
        var expectJoined: Bool
        var expectSpace: Bool
    }

    nonisolated static let roomListCases: [RoomListCase] = [
        RoomListCase(
            id: "!joined:x", membership: "join", isSpace: false,
            expectJoined: true, expectSpace: false),
        RoomListCase(
            id: "!space:x", membership: "join", isSpace: true,
            expectJoined: true, expectSpace: true),
        RoomListCase(
            id: "!invited:x", membership: "invite", isSpace: false,
            expectJoined: false, expectSpace: false),
        RoomListCase(
            id: "!left:x", membership: "leave", isSpace: false,
            expectJoined: false, expectSpace: false),
    ]

    struct MemberCase: Sendable {
        var id: String
        var userId: String
        var membership: String
        var displayname: String?
    }

    nonisolated static let memberCases: [MemberCase] = [
        MemberCase(
            id: "profiled join", userId: "@alice:x", membership: "join",
            displayname: "Alice"),
        MemberCase(
            id: "profile-less leave", userId: "@bob:x", membership: "leave",
            displayname: nil),
        MemberCase(
            id: "invite", userId: "@carol:x", membership: "invite",
            displayname: "Carol"),
    ]

    struct EventFilterCase: Sendable {
        var id: String
        var type: String
        var isMessageLike: Bool
        var isState: Bool
    }

    nonisolated static let eventFilterCases: [EventFilterCase] = [
        EventFilterCase(
            id: "message", type: "m.room.message", isMessageLike: true,
            isState: false),
        EventFilterCase(
            id: "sticker", type: "m.sticker", isMessageLike: true,
            isState: false),
        EventFilterCase(
            id: "member state", type: "m.room.member", isMessageLike: false,
            isState: true),
        EventFilterCase(
            id: "reaction", type: "m.reaction", isMessageLike: false,
            isState: false),
    ]

    // MARK: - Helpers

    private func context() throws -> ModelContext {
        ModelContext(try MatrixStore.makeInMemory())
    }

    private func insertRoom(
        in context: ModelContext, roomId: String, membership: String = "join",
        isSpace: Bool = false, latestMessageTs: Int = 0
    ) -> SDRoom {
        let room = SDRoom(
            roomId: roomId, membership: membership,
            latestMessageTs: latestMessageTs, isSpace: isSpace)
        context.insert(room)
        return room
    }

    // MARK: - Tests

    @Test("Rooms round-trip with joined/space predicates", arguments: roomListCases)
    func roomPredicates(_ row: RoomListCase) throws {
        let context = try context()
        for seed in Self.roomListCases {
            _ = insertRoom(
                in: context, roomId: seed.id, membership: seed.membership,
                isSpace: seed.isSpace)
        }
        try context.save()

        let joined = try context.fetch(SDRoom.joinedDescriptor())
        #expect(joined.map(\.roomId).contains(row.id) == row.expectJoined)
        let spaces = try context.fetch(SDRoom.spacesDescriptor())
        #expect(spaces.map(\.roomId).contains(row.id) == row.expectSpace)
        let invited = try context.fetch(SDRoom.invitedDescriptor())
        #expect(
            invited.map(\.roomId).contains(row.id)
                == (row.membership == "invite"))
    }

    @Test("Members store queryable profile columns", arguments: memberCases)
    func members(_ row: MemberCase) throws {
        let context = try context()
        let room = insertRoom(in: context, roomId: "!room:x")
        let member = SDRoomMember(
            roomId: room.roomId, userId: row.userId,
            membership: row.membership, displayname: row.displayname)
        member.room = room
        context.insert(member)
        try context.save()

        let fetched = try context.fetch(
            SDRoomMember.membersDescriptor(roomId: "!room:x"))
        let found = try #require(
            fetched.first { $0.userId == row.userId })
        #expect(found.membership == row.membership)
        #expect(found.displayname == row.displayname)
        #expect(found.key == "!room:x|\(row.userId)")
    }

    @Test("Events keep full history in timestamp order", arguments: eventFilterCases)
    func events(_ row: EventFilterCase) throws {
        let context = try context()
        let room = insertRoom(in: context, roomId: "!room:x")
        for (index, seed) in Self.eventFilterCases.enumerated() {
            let event = SDRoomEvent(
                roomId: room.roomId, eventId: "$\(seed.id)", ts: 1000 + index,
                type: seed.type, sender: "@alice:x",
                isState: seed.isState, isMessageLike: seed.isMessageLike)
            event.room = room
            context.insert(event)
        }
        try context.save()

        let timeline = try context.fetch(
            SDRoomEvent.timelineDescriptor(roomId: "!room:x"))
        #expect(timeline.count == Self.eventFilterCases.count)
        #expect(timeline.map(\.ts) == timeline.map(\.ts).sorted())
        let messages = try context.fetch(
            SDRoomEvent.messageLikeDescriptor(roomId: "!room:x"))
        #expect(messages.map(\.eventId).contains("$" + row.id) == row.isMessageLike)
    }

    @Test("Space edges normalize the graph")
    func spaceEdges() throws {
        let context = try context()
        let space = insertRoom(
            in: context, roomId: "!space:x", isSpace: true)
        let child = insertRoom(in: context, roomId: "!room:x")
        for (kind, peer) in [
            (SDEdgeKind.child, "!room:x"),
            (SDEdgeKind.parent, "!space:x"),
            (SDEdgeKind.canonicalParent, "!space:x"),
        ] as [(SDEdgeKind, String)] {
            let owner = kind == .child ? space.roomId : child.roomId
            let edge = SDRoomEdge(
                ownerRoomId: owner, peerRoomId: peer, kind: kind)
            edge.room = kind == .child ? space : child
            context.insert(edge)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SDRoomEdge>())
        #expect(fetched.count == 3)
        let keys = Set(fetched.map(\.key))
        #expect(keys.contains("!space:x|child|!room:x"))
        #expect(keys.contains("!room:x|parent|!space:x"))
        #expect(keys.contains("!room:x|canonicalParent|!space:x"))
    }

    @Test("Meta and account data round-trip")
    func metaAndAccountData() throws {
        let context = try context()
        context.insert(SDStoreMeta(
            syncToken: "s1", slidingPos: "p1",
            localUser: "@me:x"))
        context.insert(SDAccountData(
            type: "m.push_rules", content: Data([1, 2, 3])))
        let roomData = SDRoomAccountData(
            roomId: "!room:x", type: "m.tag", content: Data([4]))
        context.insert(roomData)
        try context.save()

        let meta = try #require(try context.fetch(
            FetchDescriptor<SDStoreMeta>()).first)
        #expect(meta.syncToken == "s1")
        #expect(meta.slidingPos == "p1")
        #expect(meta.localUser == "@me:x")
        #expect(meta.version == NormalizedStoreVersion.current)
        let account = try #require(try context.fetch(
            FetchDescriptor<SDAccountData>()).first)
        #expect(account.content == Data([1, 2, 3]))
        let fetchedRoomData = try #require(try context.fetch(
            FetchDescriptor<SDRoomAccountData>()).first)
        #expect(fetchedRoomData.key == "!room:x|m.tag")
    }

    @Test("Deleting a room cascades to children")
    func cascadeDelete() throws {
        let context = try context()
        let room = insertRoom(in: context, roomId: "!room:x")
        let member = SDRoomMember(
            roomId: room.roomId, userId: "@alice:x", membership: "join")
        member.room = room
        context.insert(member)
        let event = SDRoomEvent(
            roomId: room.roomId, eventId: "$e", ts: 1,
            type: "m.room.message", sender: "@alice:x",
            isMessageLike: true)
        event.room = room
        context.insert(event)
        let edge = SDRoomEdge(
            ownerRoomId: room.roomId, peerRoomId: "!space:x",
            kind: .parent)
        edge.room = room
        context.insert(edge)
        try context.save()

        context.delete(room)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<SDRoom>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SDRoomMember>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SDRoomEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SDRoomEdge>()).isEmpty)
    }

    @Test("databaseURL uses the normalized filename")
    func databaseURL() {
        let url = MatrixStore.databaseURL(
            for: UserId(unchecked: "@alice:example.com"),
            in: URL(filePath: "/tmp/store-test"))
        #expect(url.lastPathComponent == "matrix-store.swiftdata")
        #expect(
            url.deletingLastPathComponent().lastPathComponent
                == "_alice_example_com")
    }

    @Test("makeContainer creates missing parent directories")
    func createsParentDirectories() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
            .appendingPathComponent("matrix-store.swiftdata")
        _ = try MatrixStore.makeContainer(at: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
