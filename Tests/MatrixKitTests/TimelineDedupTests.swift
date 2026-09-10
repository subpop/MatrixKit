import Foundation
import Testing

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
    @Test("applyJoined appends new events")
    func appendsNew() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("b")]))
        #expect(await room.timeline.map(\.eventId.value) == ["$a", "$b"])
    }

    @Test("applyJoined drops events already in the window")
    func dropsWindowOverlap() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [dedupMessage("a"), dedupMessage("b")]))
        #expect(await room.timeline.map(\.eventId.value) == ["$a", "$b"])
    }

    @Test("applyJoined dedupes repeats within one delta")
    func dropsDeltaRepeats() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [dedupMessage("a"), dedupMessage("a")]))
        #expect(await room.timeline.map(\.eventId.value) == ["$a"])
    }

    @Test("Limited sync still replaces the window")
    func limitedResets() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [dedupMessage("b")], timelineLimited: true))
        #expect(await room.timeline.map(\.eventId.value) == ["$b"])
    }

    @Test("Limited sync drops repeats within the replacement window")
    func limitedDedupes() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        await room.applyJoined(
            JoinedRoomDelta(
                timeline: [dedupMessage("a"), dedupMessage("b"), dedupMessage("b")],
                timelineLimited: true))
        #expect(await room.timeline.map(\.eventId.value) == ["$a", "$b"])
    }

    @Test("applyLeft drops events already in the window")
    func leftDedupes() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [dedupMessage("a")]))
        await room.applyLeft(
            LeftRoomDelta(timeline: [dedupMessage("a"), dedupMessage("b"), dedupMessage("b")]))
        #expect(await room.timeline.map(\.eventId.value) == ["$a", "$b"])
    }

    @Test("restore drops repeats persisted in a snapshot")
    func restoreDedupes() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.restore(RoomSnapshot(
            roomId: RoomId(unchecked: "!r:x"),
            timeline: [dedupMessage("a"), dedupMessage("a"), dedupMessage("b")]))
        #expect(await room.timeline.map(\.eventId.value) == ["$a", "$b"])
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
}
