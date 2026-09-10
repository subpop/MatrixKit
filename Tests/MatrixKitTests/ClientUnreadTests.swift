import Foundation
import Testing

@testable import MatrixKit

private func unreadMessage(_ id: String, ts: Int) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: ts,
        content: ["body": .string(id)])
}

private func ownMessage(_ id: String, ts: Int) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@me:x"),
        originServerTs: ts,
        content: [
            "msgtype": .string("m.text"),
            "body": .string(id),
        ])
}

private func editMessage(_ id: String, target: String, ts: Int) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: ts,
        content: [
            "msgtype": .string("m.text"),
            "body": .string("edited"),
            "m.relates_to": .object([
                "rel_type": .string("m.replace"),
                "event_id": .string("$\(target)"),
            ]),
        ])
}

private func fullyReadDelta(_ eventId: String) -> JoinedRoomDelta {
    JoinedRoomDelta(accountData: [
        BasicEvent(
            type: "m.fully_read",
            content: ["event_id": .string("$\(eventId)")])
    ])
}

private func receiptDelta(userId: String, eventId: String, ts: Int, threaded: Bool = false)
    -> JoinedRoomDelta
{
    var entry: [String: AnyCodable] = ["ts": .int(ts)]
    if threaded {
        entry["thread_id"] = .string("$thread")
    }
    return JoinedRoomDelta(ephemeral: [
        BasicEvent(
            type: "m.receipt",
            content: [
                "$\(eventId)": .object([
                    "m.read": .object([userId: .object(entry)])
                ])
            ])
    ])
}

@Suite("Client-side unread")
@MainActor
struct ClientUnreadTests {
    @Test("no marker falls back to the server count")
    func noMarkerServerFallback() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(
                timeline: [
                    unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                    unreadMessage("c", ts: 3),
                ],
                unreadCount: 5))
        #expect(await room.clientUnreadCount == nil)
        #expect(await room.effectiveUnreadCount == 5)
        // The raw server field is preserved for tests/diagnostics.
        #expect(await room.unreadCount == 5)
    }

    @Test("fully-read marker counts only newer messages")
    func fullyReadInWindow() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
        #expect(await room.clientUnreadCount == 1)
        #expect(await room.effectiveUnreadCount == 1)
    }

    @Test("marker older than the window counts the whole window")
    func fullyReadOlderThanWindow() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.clientUnreadCount == 2)
        #expect(await room.effectiveUnreadCount == 2)
    }

    @Test("own read receipt positions the marker")
    func ownReceipt() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ]))
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "b", ts: 2))
        #expect(await room.clientUnreadCount == 1)
        #expect(await room.effectiveUnreadCount == 1)
    }

    @Test("threaded receipts are skipped")
    func threadedReceiptSkipped() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [unreadMessage("a", ts: 1)]))
        await room.applyJoined(
            receiptDelta(userId: "@me:x", eventId: "a", ts: 1, threaded: true))
        #expect(await room.clientUnreadCount == nil)
        #expect(await room.effectiveUnreadCount == 0)
    }

    @Test("read marker never regresses")
    func markerMonotonic() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ]))
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "c", ts: 3))
        #expect(await room.effectiveUnreadCount == 0)
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "a", ts: 1))
        #expect(await room.effectiveUnreadCount == 0)
    }

    @Test("effective count takes the max of server and client")
    func effectiveTakesMax() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(
                timeline: [
                    unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                    unreadMessage("c", ts: 3),
                ],
                unreadCount: 5))
        var markerDelta = fullyReadDelta("b")
        markerDelta.unreadCount = 5
        await room.applyJoined(markerDelta)
        #expect(await room.clientUnreadCount == 1)
        #expect(await room.effectiveUnreadCount == 5)
    }

    @Test("local mark-read clears the client count")
    func localMarkRead() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.effectiveUnreadCount == 2)
        await room.setFullyRead(EventId(unchecked: "$b"))
        #expect(await room.effectiveUnreadCount == 0)
    }

    @Test("read marker survives a snapshot round-trip")
    func snapshotRoundTrip() async throws {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ]))
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "b", ts: 2))
        let data = try JSONEncoder().encode(await room.snapshot())
        let snapshot = try JSONDecoder().decode(RoomSnapshot.self, from: data)
        let restored = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await restored.restore(snapshot)
        #expect(await restored.clientUnreadCount == 1)
        #expect(await restored.effectiveUnreadCount == 1)
    }

    @Test("marker outside the window flags for single-event resolution")
    func needsResolutionOutsideWindow() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.needsMarkerResolution)
    }

    @Test("marker inside the window needs no resolution")
    func noResolutionInsideWindow() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("a"))
        #expect(await room.needsMarkerResolution == false)
    }

    @Test("resolved marker timestamp clears phantom unreads")
    func resolvedMarkerAdoption() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        // Stale receipt pins the marker at ts=1; the fully-read event is
        // older than the window, so sync adoption can't resolve it.
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "a", ts: 1))
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.effectiveUnreadCount == 1)
        await room.adoptResolvedMarkerTs(EventId(unchecked: "$old"), ts: 2)
        #expect(await room.needsMarkerResolution == false)
        #expect(await room.effectiveUnreadCount == 0)
    }

    @Test("edits newer than the marker do not count as unread")
    func editsExcludedFromUnread() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
        #expect(await room.effectiveUnreadCount == 0)
        // An edit of an older message arrives with a fresh timestamp.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [editMessage("edit1", target: "a", ts: 3)]))
        #expect(await room.clientUnreadCount == 0)
        #expect(await room.effectiveUnreadCount == 0)
        // A genuine new message still counts.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [unreadMessage("c", ts: 4)]))
        #expect(await room.effectiveUnreadCount == 1)
    }

    @Test("resolved marker never regresses and ignores stale fetches")
    func resolvedMarkerMonotonic() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(receiptDelta(userId: "@me:x", eventId: "b", ts: 2))
        await room.applyJoined(fullyReadDelta("old"))
        // Fetch for a superseded marker ID is ignored.
        await room.adoptResolvedMarkerTs(EventId(unchecked: "$stale"), ts: 99)
        #expect(await room.readMarkerTsMs == 2)
        // Older timestamp does not regress the marker.
        await room.adoptResolvedMarkerTs(EventId(unchecked: "$old"), ts: 1)
        #expect(await room.readMarkerTsMs == 2)
        #expect(await room.effectiveUnreadCount == 0)
    }

    @Test("first unread is the event after the marker")
    func firstUnreadAfterMarker() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
                unreadMessage("c", ts: 3),
            ]))
        #expect(await room.firstUnreadEventId == nil)
        await room.applyJoined(fullyReadDelta("b"))
        #expect(await room.firstUnreadEventId == EventId(unchecked: "$c"))
    }

    @Test("first unread is nil when the room is fully read")
    func firstUnreadNilWhenRead() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
        #expect(await room.firstUnreadEventId == nil)
        // Marker adoption is max-only: an older marker echo does not
        // regress the marker, so the room stays fully read.
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.firstUnreadEventId == nil)
        // Local mark-read also clears it.
        await room.setFullyRead(EventId(unchecked: "$b"))
        #expect(await room.firstUnreadEventId == nil)
    }

    @Test("first unread is the window head when the marker predates it")
    func firstUnreadOlderThanWindow() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("old"))
        #expect(await room.firstUnreadEventId?.value == "$a")
    }

    @Test("first unread skips edits newer than the marker")
    func firstUnreadSkipsEdits() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
        // An edit of an older message arrives with a fresh timestamp.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [editMessage("edit1", target: "a", ts: 3)]))
        #expect(await room.firstUnreadEventId == nil)
        await room.applyJoined(
            JoinedRoomDelta(timeline: [unreadMessage("c", ts: 4)]))
        #expect(await room.firstUnreadEventId?.value == "$c")
    }

    @Test("own messages newer than the marker do not count as unread")
    func ownMessagesExcludedFromUnread() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
        #expect(await room.effectiveUnreadCount == 0)
        // Our own message (e.g. sent from another device) arrives with a
        // fresh timestamp but must not move the count or divider.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [ownMessage("c", ts: 3)]))
        #expect(await room.clientUnreadCount == 0)
        #expect(await room.effectiveUnreadCount == 0)
        #expect(await room.firstUnreadEventId == nil)
        // A genuine new message still counts.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [unreadMessage("d", ts: 4)]))
        #expect(await room.clientUnreadCount == 1)
        #expect(await room.effectiveUnreadCount == 1)
        #expect(await room.firstUnreadEventId?.value == "$d")
    }

    @Test("send echo and its confirm never flash unread")
    func ownEchoAndConfirmNeverUnread() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.setLocalUser(UserId(unchecked: "@me:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                unreadMessage("a", ts: 1), unreadMessage("b", ts: 2),
            ]))
        await room.applyJoined(fullyReadDelta("b"))
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
        await room.stageEcho(echo, transactionId: TransactionId("t1"))
        #expect(await room.clientUnreadCount == 0)
        #expect(await room.effectiveUnreadCount == 0)
        #expect(await room.firstUnreadEventId == nil)
        // Sync confirms with a server-assigned timestamp newer than the
        // echo. This previously re-lit the divider and badge until the
        // debounced mark-read caught up.
        await room.applyJoined(
            JoinedRoomDelta(timeline: [ownMessage("real", ts: 4)]))
        #expect(await room.clientUnreadCount == 0)
        #expect(await room.effectiveUnreadCount == 0)
        #expect(await room.firstUnreadEventId == nil)
    }
}
