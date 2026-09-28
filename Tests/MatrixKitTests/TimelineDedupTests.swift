import Foundation
import Testing

import MatrixKitTesting

@testable import MatrixKit

private func dedupMessage(_ id: String) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: 1,
        content: ["body": .string(id)])
}

@Suite("Timeline dedup")
@MainActor
struct TimelineDedupTests {
    enum ApplyOp: String, Sendable {
        case join
        case left
        case restore
    }

    struct DedupCase: Sendable {
        var seed: [String]
        var second: [String]
        var limited: Bool
        var op: ApplyOp
        var expected: [String]
    }

    nonisolated static let dedupCases: [DedupCase] = [
        DedupCase(seed: ["a"], second: ["b"], limited: false, op: .join, expected: ["$a", "$b"]),
        DedupCase(seed: ["a"], second: ["a", "b"], limited: false, op: .join, expected: ["$a", "$b"]),
        DedupCase(seed: [], second: ["a", "a"], limited: false, op: .join, expected: ["$a"]),
        DedupCase(seed: ["a"], second: ["b"], limited: true, op: .join, expected: ["$b"]),
        DedupCase(seed: ["a"], second: ["a", "b", "b"], limited: true, op: .join, expected: ["$a", "$b"]),
        DedupCase(seed: ["a"], second: ["a", "b", "b"], limited: false, op: .left, expected: ["$a", "$b"]),
        DedupCase(seed: [], second: ["a", "a", "b"], limited: false, op: .restore, expected: ["$a", "$b"]),
    ]

    @Test("Dedup keeps first-seen order across apply paths", arguments: dedupCases)
    func dedup(_ c: DedupCase) async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: c.seed.map(dedupMessage)))
        switch c.op {
        case .join:
            await room.applyJoined(JoinedRoomDelta(
                timeline: c.second.map(dedupMessage), timelineLimited: c.limited))
        case .left:
            await room.applyLeft(LeftRoomDelta(timeline: c.second.map(dedupMessage)))
        case .restore:
            await room.restore(RoomSnapshot(
                roomId: RoomId(unchecked: "!r:x"),
                timeline: c.second.map(dedupMessage)))
        }
        #expect(await room.timeline.map(\.eventId.value) == c.expected)
    }

    @Test("paginateBack drops events already in the window")
    func paginateDropsOverlap() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("b")]))
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        await pager.setPage(PaginationChunk(
            start: "p1", end: nil,
            chunk: [dedupMessage("a"), dedupMessage("b")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        #expect(try await timeline.paginateBack() == 1)
        #expect(await timeline.events().map(\.eventId.value) == ["$a", "$b"])
    }
}

@Suite("Back-pagination order")
@MainActor
struct BackPaginationOrderTests {
    @Test("paginateBack reverses the newest-first page to oldest-first")
    func reversesNewestFirstPage() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("c")]))
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        // Wire order: newest-first (`b` is newer than `a`).
        await pager.setPage(PaginationChunk(
            start: "p1", end: "p0",
            chunk: [dedupMessage("b"), dedupMessage("a")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        #expect(try await timeline.paginateBack() == 2)
        #expect(await timeline.events().map(\.eventId.value) == ["$a", "$b", "$c"])
    }

    @Test("paginateBack reverses before dropping window overlap")
    func reversesBeforeDedup() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.applyJoined(JoinedRoomDelta(
            timeline: [dedupMessage("b"), dedupMessage("c")]))
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        await pager.setPage(PaginationChunk(
            start: "p1", end: nil,
            chunk: [dedupMessage("c"), dedupMessage("b"), dedupMessage("a")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        #expect(try await timeline.paginateBack() == 1)
        #expect(await timeline.events().map(\.eventId.value) == ["$a", "$b", "$c"])
    }

    @Test("Pagination flags and update streams")
    func flagsAndUpdates() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        let pager = FakePager()
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        #expect(await timeline.paginationInProgress() == false)
        #expect(await timeline.canPaginateBack() == false)
        // No cursor: paginateBack is a no-op.
        #expect(try await timeline.paginateBack() == 0)
        let updates = await timeline.updates()
        var iterator = updates.makeAsyncIterator()
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        let first = await iterator.next()
        #expect(first != nil)
    }

    @Test("Decryptor transforms paginated events")
    func decryptor() async throws {
        let roomId = RoomId(unchecked: "!room:x")
        let room = RoomActor(roomId: roomId)
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("b")]))
        await room.prependHistory([], prevBatch: BatchToken("p1"))
        let pager = FakePager()
        await pager.setPage(PaginationChunk(
            start: "p1", end: nil, chunk: [dedupMessage("a")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)
        await timeline.setDecryptor { event, _ in
            var mapped = event
            mapped.content["decrypted"] = .bool(true)
            return mapped
        }
        #expect(try await timeline.paginateBack() == 1)
        #expect(await timeline.events().first?.content["decrypted"] == .bool(true))
    }
}
