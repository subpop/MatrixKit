#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// Client-side unread rules, ported from the `RoomActor` suite to the
/// writer's precompute (`effectiveUnread` / `firstUnreadEventId` on the
/// room row). Same behaviors: server fallback, marker windowing,
/// receipt max-merge, edit/own-message exclusion, resolution healing.
@Suite("Client-side unread")
@MainActor
struct ClientUnreadTests {
    private func stores() throws -> (MatrixStoreWriter, ModelContainer) {
        let container = try MatrixStore.makeInMemory()
        return (MatrixStoreWriter(modelContainer: container), container)
    }

    private func row(
        _ container: ModelContainer, _ roomId: String = "!r:x"
    ) throws -> SDRoom {
        let context = ModelContext(container)
        let id = roomId
        return try #require(try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first)
    }

    private func applyTimeline(
        _ writer: MatrixStoreWriter, _ events: [MessageEvent],
        unreadCount: Int = 0
    ) async throws {
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): JoinedRoomDelta(
                timeline: events, unreadCount: unreadCount)]))
    }

    @Test("no marker falls back to the server count")
    func noMarkerServerFallback() async throws {
        let (writer, container) = try stores()
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ],
            unreadCount: 5)
        let stored = try row(container)
        #expect(stored.readMarkerTs == nil)
        #expect(stored.fullyRead == nil)
        #expect(stored.effectiveUnread == 5)
        // The raw server field is preserved for tests/diagnostics.
        #expect(stored.unread == 5)
    }

    @Test("fully-read marker counts only newer messages")
    func fullyReadInWindow() async throws {
        let (writer, container) = try stores()
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): fullyReadDelta("b")]))
        let stored = try row(container)
        #expect(stored.effectiveUnread == 1)
        #expect(stored.firstUnreadEventId == "$c")
    }

    @Test("marker older than the window counts the whole window")
    func fullyReadOlderThanWindow() async throws {
        let (writer, container) = try stores()
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): fullyReadDelta("old")]))
        let stored = try row(container)
        #expect(stored.effectiveUnread == 2)
        #expect(stored.firstUnreadEventId == "$a")
    }

    @Test("own read receipt positions the marker")
    func ownReceipt() async throws {
        let (writer, container) = try stores()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [
                RoomId(unchecked: "!r:x"): receiptDelta(
                    userId: "@me:x", eventId: "b", ts: 2)
            ]))
        #expect(try row(container).effectiveUnread == 1)
    }

    @Test("threaded receipts are skipped")
    func threadedReceiptSkipped() async throws {
        let (writer, container) = try stores()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(writer, [unreadMessage("a", ts: 1)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [
                RoomId(unchecked: "!r:x"): receiptDelta(
                    userId: "@me:x", eventId: "a", ts: 1, threaded: true)
            ]))
        let stored = try row(container)
        #expect(stored.readMarkerTs == nil)
        #expect(stored.effectiveUnread == 0)
    }

    @Test("read marker never regresses")
    func markerMonotonic() async throws {
        let (writer, container) = try stores()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ])
        let roomId = RoomId(unchecked: "!r:x")
        for receipt in [
            receiptDelta(userId: "@me:x", eventId: "c", ts: 3),
            receiptDelta(userId: "@me:x", eventId: "a", ts: 1),
        ] {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s"), joined: [roomId: receipt]))
        }
        #expect(try row(container).effectiveUnread == 0)
    }

    @Test("effective count takes the max of server and client")
    func effectiveTakesMax() async throws {
        let (writer, container) = try stores()
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ],
            unreadCount: 5)
        var markerDelta = fullyReadDelta("b")
        markerDelta.unreadCount = 5
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): markerDelta]))
        #expect(try row(container).effectiveUnread == 5)
    }

    @Test("local mark-read clears the client count")
    func localMarkRead() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("old")]))
        #expect(try row(container).effectiveUnread == 2)
        try await writer.setFullyRead(
            roomId: roomId, eventId: EventId(unchecked: "$b"))
        #expect(try row(container).effectiveUnread == 0)
    }

    @Test("marker outside the window flags for single-event resolution")
    func needsResolutionOutsideWindow() async throws {
        let (writer, _) = try stores()
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): fullyReadDelta("old")]))
        #expect(
            try await writer.markersNeedingResolution().map(\.marker)
                == [EventId(unchecked: "$old")])
    }

    @Test("marker inside the window needs no resolution")
    func noResolutionInsideWindow() async throws {
        let (writer, _) = try stores()
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): fullyReadDelta("a")]))
        #expect(try await writer.markersNeedingResolution().isEmpty)
    }

    @Test("resolved marker timestamp clears phantom unreads")
    func resolvedMarkerAdoption() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        // Stale receipt pins the marker at ts=1; the fully-read event is
        // older than the window, so sync adoption can't resolve it.
        for delta in [
            receiptDelta(userId: "@me:x", eventId: "a", ts: 1),
            fullyReadDelta("old"),
        ] {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s"), joined: [roomId: delta]))
        }
        #expect(try row(container).effectiveUnread == 1)
        try await writer.adoptResolvedMarkerTs(
            EventId(unchecked: "$old"), roomId: roomId, ts: 2)
        #expect(try await writer.markersNeedingResolution().isEmpty)
        #expect(try row(container).effectiveUnread == 0)
    }

    @Test("edits newer than the marker do not count as unread")
    func editsExcludedFromUnread() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("b")]))
        #expect(try row(container).effectiveUnread == 0)
        // An edit of an older message arrives with a fresh timestamp.
        try await applyTimeline(writer, [editMessage("edit1", target: "a", ts: 3)])
        #expect(try row(container).effectiveUnread == 0)
        // A genuine new message still counts.
        try await applyTimeline(writer, [unreadMessage("c", ts: 4)])
        #expect(try row(container).effectiveUnread == 1)
    }

    @Test("resolved marker never regresses and ignores stale fetches")
    func resolvedMarkerMonotonic() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        for delta in [
            receiptDelta(userId: "@me:x", eventId: "b", ts: 2),
            fullyReadDelta("old"),
        ] {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s"), joined: [roomId: delta]))
        }
        // Fetch for a superseded marker ID is ignored.
        try await writer.adoptResolvedMarkerTs(
            EventId(unchecked: "$stale"), roomId: roomId, ts: 99)
        #expect(try row(container).readMarkerTs == 2)
        // Older timestamp does not regress the marker.
        try await writer.adoptResolvedMarkerTs(
            EventId(unchecked: "$old"), roomId: roomId, ts: 1)
        #expect(try row(container).readMarkerTs == 2)
        #expect(try row(container).effectiveUnread == 0)
    }

    @Test("first unread is the event after the marker")
    func firstUnreadAfterMarker() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await applyTimeline(
            writer,
            [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ])
        #expect(try row(container).firstUnreadEventId == nil)
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("b")]))
        #expect(try row(container).firstUnreadEventId == "$c")
    }

    @Test("first unread is nil when the room is fully read")
    func firstUnreadNilWhenRead() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        for delta in [fullyReadDelta("b"), fullyReadDelta("old")] {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s"), joined: [roomId: delta]))
        }
        #expect(try row(container).firstUnreadEventId == nil)
        // Local mark-read also clears it.
        try await writer.setFullyRead(
            roomId: roomId, eventId: EventId(unchecked: "$b"))
        #expect(try row(container).firstUnreadEventId == nil)
    }

    @Test("first unread is the window head when the marker predates it")
    func firstUnreadOlderThanWindow() async throws {
        let (writer, container) = try stores()
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [RoomId(unchecked: "!r:x"): fullyReadDelta("old")]))
        #expect(try row(container).firstUnreadEventId == "$a")
    }

    @Test("first unread skips edits newer than the marker")
    func firstUnreadSkipsEdits() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("b")]))
        // An edit of an older message arrives with a fresh timestamp.
        try await applyTimeline(writer, [editMessage("edit1", target: "a", ts: 3)])
        #expect(try row(container).firstUnreadEventId == nil)
        try await applyTimeline(writer, [unreadMessage("c", ts: 4)])
        #expect(try row(container).firstUnreadEventId == "$c")
    }

    @Test("own messages newer than the marker do not count as unread")
    func ownMessagesExcludedFromUnread() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("b")]))
        #expect(try row(container).effectiveUnread == 0)
        // Our own message (e.g. sent from another device) arrives with a
        // fresh timestamp but must not move the count or divider.
        try await applyTimeline(writer, [ownMessage("c", ts: 3)])
        #expect(try row(container).effectiveUnread == 0)
        #expect(try row(container).firstUnreadEventId == nil)
        // A genuine new message still counts.
        try await applyTimeline(writer, [unreadMessage("d", ts: 4)])
        #expect(try row(container).effectiveUnread == 1)
        #expect(try row(container).firstUnreadEventId == "$d")
    }

    @Test("send echo and its confirm never flash unread")
    func ownEchoAndConfirmNeverUnread() async throws {
        let (writer, container) = try stores()
        let roomId = RoomId(unchecked: "!r:x")
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await applyTimeline(
            writer,
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [roomId: fullyReadDelta("b")]))
        // Stage our echo: client timestamp, local ID.
        let echo = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "local:t1"),
            sender: UserId(unchecked: "@me:x"),
            originServerTs: 3,
            content: [
                "msgtype": .string("m.text"),
                "body": .string("hi"),
            ],
            unsigned: ["transaction_id": .string("t1")])
        try await writer.stageEcho(
            echo, roomId: roomId, transactionId: TransactionId("t1"))
        #expect(try row(container).effectiveUnread == 0)
        #expect(try row(container).firstUnreadEventId == nil)
        // Sync confirms with a server-assigned timestamp newer than the
        // echo. This previously re-lit the divider and badge until the
        // debounced mark-read caught up.
        try await applyTimeline(writer, [ownMessage("real", ts: 4)])
        #expect(try row(container).effectiveUnread == 0)
        #expect(try row(container).firstUnreadEventId == nil)
    }
}
#endif
