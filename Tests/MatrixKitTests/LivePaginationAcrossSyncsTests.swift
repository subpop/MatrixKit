import Foundation
import Testing

@testable import MatrixKit

private func cursorMessage(_ id: String) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: 1,
        content: ["body": .string(id)])
}

/// Canned `TimelinePaging` serving a fixed page per requested `from`
/// cursor. Records every requested cursor so tests can assert which
/// token each pagination round actually used.
private actor CursorPager: TimelinePaging {
    var pages: [String: PaginationChunk<MessageEvent>] = [:]
    var requestedFrom: [String?] = []

    func serve(from: String?, page: PaginationChunk<MessageEvent>) {
        pages[from ?? ""] = page
    }

    func paginate(
        _ roomId: RoomId,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent> {
        requestedFrom.append(from?.value)
        guard let page = pages[from?.value ?? ""] else { throw .notAuthenticated }
        return page
    }

    func context(
        _ roomId: RoomId,
        eventId: EventId,
        limit: Int
    ) async throws(MatrixError) -> EventContext {
        throw .notAuthenticated
    }

    func event(
        _ roomId: RoomId,
        _ eventId: EventId
    ) async throws(MatrixError) -> MessageEvent {
        throw .notAuthenticated
    }

    func relations(
        _ roomId: RoomId,
        eventId: EventId,
        relType: String,
        eventType: String?,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> RelationsResponse {
        throw .notAuthenticated
    }
}

@Suite("Live back-pagination across syncs")
@MainActor
struct LivePaginationAcrossSyncsTests {
    private func liveRoom(id: String = "!r:x") async -> RoomActor {
        let room = RoomActor(roomId: RoomId(unchecked: id))
        await room.applyJoined(JoinedRoomDelta(
            timeline: [cursorMessage("live")],
            prevBatch: BatchToken("s0")))
        return room
    }

    @Test("Sync delta does not clobber the pagination cursor")
    func syncKeepsPaginationCursor() async {
        let room = await liveRoom()
        await room.prependHistory([cursorMessage("old")], prevBatch: BatchToken("c1"))
        #expect(await room.prevBatch == BatchToken("c1"))
        await room.applyJoined(JoinedRoomDelta(
            timeline: [cursorMessage("newer")],
            prevBatch: BatchToken("s1")))
        #expect(await room.prevBatch == BatchToken("c1"))
    }

    @Test("Pagination resumes from the advanced cursor after a sync")
    func resumesFromAdvancedCursor() async throws {
        let roomId = RoomId(unchecked: "!r:x")
        let room = await liveRoom()
        let pager = CursorPager()
        // Wire order: newest-first.
        await pager.serve(
            from: "s0",
            page: PaginationChunk(
                start: "s0", end: "c1",
                chunk: [cursorMessage("live"), cursorMessage("older")]))
        await pager.serve(
            from: "c1",
            page: PaginationChunk(
                start: "c1", end: "c2",
                chunk: [cursorMessage("oldest")]))
        let timeline = Timeline(roomId: roomId, messages: pager, room: room)

        #expect(try await timeline.paginateBack() == 1)
        #expect(await timeline.events().map(\.eventId.value) == ["$older", "$live"])
        #expect(await room.prevBatch == BatchToken("c1"))

        // An incremental sync arrives between pages (receipts, typing,
        // or a new message all carry a live-edge `prev_batch`).
        await room.applyJoined(JoinedRoomDelta(
            timeline: [cursorMessage("newer")],
            prevBatch: BatchToken("s1")))

        #expect(try await timeline.paginateBack() == 1)
        #expect(await pager.requestedFrom == ["s0", "c1"])
        #expect(
            await timeline.events().map(\.eventId.value)
                == ["$oldest", "$older", "$live", "$newer"])
        #expect(await room.prevBatch == BatchToken("c2"))
    }

    @Test("Limited sync adopts the fresh cursor")
    func limitedSyncAdoptsCursor() async {
        let room = await liveRoom()
        await room.prependHistory([cursorMessage("old")], prevBatch: BatchToken("c1"))
        await room.applyJoined(JoinedRoomDelta(
            timeline: [cursorMessage("fresh")],
            timelineLimited: true,
            prevBatch: BatchToken("s9")))
        #expect(await room.prevBatch == BatchToken("s9"))
        #expect(await room.timeline.map(\.eventId.value) == ["$fresh"])
    }

    @Test("All-duplicate page with a live cursor keeps hasMore")
    func duplicatePageKeepsHasMore() async throws {
        let roomId = RoomId(unchecked: "!r:x")
        let room = await liveRoom()
        let pager = CursorPager()
        await pager.serve(
            from: "s0",
            page: PaginationChunk(
                start: "s0", end: "p0",
                chunk: [cursorMessage("live")]))
        let observable = await ObservableTimeline(
            timeline: Timeline(roomId: roomId, messages: pager, room: room),
            room: room,
            messages: pager,
            localUser: nil)
        #expect(observable.hasMore)
        try await observable.loadMore()
        #expect(observable.hasMore)
        #expect(await pager.requestedFrom == ["s0"])
    }

    @Test("Missing end token clears hasMore at true history start")
    func historyStartClearsHasMore() async throws {
        let roomId = RoomId(unchecked: "!r:x")
        let room = await liveRoom()
        let pager = CursorPager()
        // Wire order: newest-first.
        await pager.serve(
            from: "s0",
            page: PaginationChunk(
                start: "s0", end: nil,
                chunk: [cursorMessage("live"), cursorMessage("oldest")]))
        let observable = await ObservableTimeline(
            timeline: Timeline(roomId: roomId, messages: pager, room: room),
            room: room,
            messages: pager,
            localUser: nil)
        #expect(observable.hasMore)
        try await observable.loadMore()
        #expect(observable.hasMore == false)
        await observable.refresh()
        #expect(
            await observable.events.map(\.eventId.value) == ["$oldest", "$live"])
    }
}
