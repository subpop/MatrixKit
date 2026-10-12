#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// `MatrixStoreWriter`: incremental delta application onto the normalized
/// store. Mirrors the `RoomActor` fold (state, dedupe, redactions,
/// echoes, markers, unread precompute) without the snapshot layer.
@Suite("MatrixStoreWriter")
@MainActor
struct MatrixStoreWriterTests {
    // MARK: - Tables

    struct StateFoldCase: Sendable {
        var id: String
    }

    nonisolated static let stateFoldCases: [StateFoldCase] = [
        StateFoldCase(id: "name"),
        StateFoldCase(id: "topic"),
        StateFoldCase(id: "member-join"),
        StateFoldCase(id: "member-leave-keeps-profile"),
        StateFoldCase(id: "space-child"),
        StateFoldCase(id: "space-parent-canonical"),
        StateFoldCase(id: "encryption"),
        StateFoldCase(id: "tombstone"),
        StateFoldCase(id: "create-space"),
    ]

    struct MembershipCase: Sendable {
        var id: String
        var membership: String
        var inviter: String?
    }

    nonisolated static let membershipCases: [MembershipCase] = [
        MembershipCase(id: "join", membership: "join", inviter: nil),
        MembershipCase(id: "invite", membership: "invite", inviter: "@alice:x"),
        MembershipCase(id: "leave", membership: "leave", inviter: nil),
        MembershipCase(id: "knock", membership: "knock", inviter: nil),
    ]

    struct UnreadCase: Sendable {
        var id: String
        /// Expected badge count after two peer messages + one own/edit
        /// newer than the marker.
        var effective: Int
        var firstUnread: String?
    }

    nonisolated static let unreadCases: [UnreadCase] = [
        UnreadCase(id: "peer", effective: 2, firstUnread: "$b"),
        UnreadCase(id: "own", effective: 1, firstUnread: "$b"),
        UnreadCase(id: "edit", effective: 1, firstUnread: "$b"),
    ]

    // MARK: - Helpers

    private func writer() throws -> (MatrixStoreWriter, ModelContainer) {
        let container = try MatrixStore.makeInMemory()
        return (MatrixStoreWriter(modelContainer: container), container)
    }

    private func room(
        _ container: ModelContainer, _ roomId: String
    ) throws -> SDRoom {
        let context = ModelContext(container)
        let id = roomId
        return try #require(try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first)
    }

    /// Builds a `Date` from a millisecond `originServerTs`-style value, the
    /// inverse of `trimEvents`' cutoff conversion.
    private func date(ms: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private func stateDelta(_ id: String) -> JoinedRoomDelta {
        switch id {
        case "name":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.name", content: ["name": .string("General")])
            ])
        case "topic":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.topic",
                    content: ["topic": .string("All talk")])
            ])
        case "member-join":
            return JoinedRoomDelta(state: [
                memberStateEvent(
                    "@alice:x", membership: "join", displayname: "Alice")
            ])
        case "member-leave-keeps-profile":
            return JoinedRoomDelta(state: [
                memberStateEvent(
                    "@alice:x", membership: "join", displayname: "Alice",
                    id: "$m1"),
                memberStateEvent(
                    "@alice:x", membership: "leave", id: "$m2"),
            ])
        case "space-child":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.space.child", stateKey: "!room:x",
                    content: ["via": .string("x")])
            ])
        case "space-parent-canonical":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.space.parent", stateKey: "!space:x",
                    content: ["canonical": .bool(true)])
            ])
        case "encryption":
            return JoinedRoomDelta(state: [
                stateEvent(type: "m.room.encryption", content: [:])
            ])
        case "tombstone":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.tombstone",
                    content: ["replacement_room": .string("!new:x")])
            ])
        case "create-space":
            return JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.create",
                    content: ["type": .string("m.space")])
            ])
        default:
            return JoinedRoomDelta()
        }
    }

    // MARK: - Tests

    @Test("State events fold onto room and member rows", arguments: stateFoldCases)
    func stateFolding(_ row: StateFoldCase) async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [
                RoomId(unchecked: "!room:x"): stateDelta(row.id)
            ]))

        let room = try self.room(container, "!room:x")
        let context = ModelContext(container)
        switch row.id {
        case "name":
            #expect(room.name == "General")
        case "topic":
            #expect(room.topic == "All talk")
        case "member-join":
            let key = "!room:x|@alice:x"
            let member = try #require(try context.fetch(
                FetchDescriptor<SDRoomMember>(
                    predicate: #Predicate { $0.key == key })).first)
            #expect(member.displayname == "Alice")
            #expect(member.membership == "join")
        case "member-leave-keeps-profile":
            let key = "!room:x|@alice:x"
            let member = try #require(try context.fetch(
                FetchDescriptor<SDRoomMember>(
                    predicate: #Predicate { $0.key == key })).first)
            #expect(member.membership == "leave")
            #expect(member.displayname == "Alice")
        case "space-child":
            let edges = try context.fetch(FetchDescriptor<SDRoomEdge>())
            #expect(edges.map(\.key) == ["!room:x|child|!room:x"])
        case "space-parent-canonical":
            let edges = try context.fetch(FetchDescriptor<SDRoomEdge>())
            let keys = Set(edges.map(\.key))
            #expect(keys.contains("!room:x|parent|!space:x"))
            #expect(keys.contains("!room:x|canonicalParent|!space:x"))
        case "encryption":
            #expect(room.isEncrypted)
        case "tombstone":
            #expect(room.successorRoomId == "!new:x")
        case "create-space":
            #expect(room.isSpace)
        default:
            Issue.record("unhandled row \(row.id)")
        }
    }

    @Test("Overlapping sync windows keep unique event IDs")
    func dedupe() async throws {
        let (writer, _) = try writer()
        let delta = joinedTimelineDelta(
            [unreadMessage("a", ts: 1), unreadMessage("a", ts: 1)],
            unreadCount: 1)
        try await writer.apply(delta)
        // Re-applying the same window inserts nothing new.
        try await writer.apply(delta)
        let events = try await writer.storedEvents(
            roomId: RoomId(unchecked: "!room:x"))
        #expect(events.map(\.eventId) == [EventId(unchecked: "$a")])
    }

    struct WindowDedupCase: Sendable {
        var id: String
        var seed: [String]
        var second: [String]
        var limited: Bool
        var viaLeft: Bool
        var expected: [String]
    }

    nonisolated static let windowDedupCases: [WindowDedupCase] = [
        WindowDedupCase(
            id: "append", seed: ["a"], second: ["b"], limited: false,
            viaLeft: false, expected: ["$a", "$b"]),
        WindowDedupCase(
            id: "overlap", seed: ["a"], second: ["a", "b"], limited: false,
            viaLeft: false, expected: ["$a", "$b"]),
        WindowDedupCase(
            id: "intra-batch", seed: [], second: ["a", "a"], limited: false,
            viaLeft: false, expected: ["$a"]),
        // Full history merges: `limited` only governs the cursor, never
        // deletes rows (unlike the old windowed store).
        WindowDedupCase(
            id: "limited-merges", seed: ["a"], second: ["b"], limited: true,
            viaLeft: false, expected: ["$a", "$b"]),
        WindowDedupCase(
            id: "limited-dedupes", seed: ["a"], second: ["a", "b", "b"],
            limited: true, viaLeft: false, expected: ["$a", "$b"]),
        WindowDedupCase(
            id: "leave", seed: ["a"], second: ["a", "b", "b"], limited: false,
            viaLeft: true, expected: ["$a", "$b"]),
    ]

    @Test("Dedup keeps first-seen order across apply paths", arguments: windowDedupCases)
    func windowDedupe(_ row: WindowDedupCase) async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        func message(_ id: String) -> MessageEvent {
            unreadMessage(id, ts: 1)
        }
        try await writer.apply(joinedTimelineDelta(
            row.seed.map(message), nextBatch: "s1"))
        let incoming = row.second.map(message)
        if row.viaLeft {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s2"),
                left: [roomId: LeftRoomDelta(timeline: incoming)]))
        } else {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s2"),
                joined: [roomId: JoinedRoomDelta(
                    timeline: incoming, timelineLimited: row.limited)]))
        }
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == row.expected)
    }

    @Test("Limited syncs merge and adopt the cursor")
    func limitedMerge() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("a", ts: 1)], nextBatch: "s1"))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [
                RoomId(unchecked: "!room:x"): JoinedRoomDelta(
                    timeline: [unreadMessage("b", ts: 2)],
                    timelineLimited: true,
                    prevBatch: BatchToken("p2"))
            ]))
        // Full history is kept: nothing is deleted on `limited`.
        let events = try await writer.storedEvents(
            roomId: RoomId(unchecked: "!room:x"))
        #expect(events.map(\.eventId.value) == ["$a", "$b"])
        #expect(try self.room(container, "!room:x").prevBatch == "p2")
    }

    @Test("Redactions stamp and prune their targets")
    func redactionFold() async throws {
        let (writer, _) = try writer()
        try await writer.apply(joinedTimelineDelta(
            [snapshotMessage("hello", id: "$a")]))
        try await writer.apply(joinedTimelineDelta([redactionEvent("r", target: "a")]))
        let events = try await writer.storedEvents(
            roomId: RoomId(unchecked: "!room:x"))
        let target = try #require(events.first { $0.eventId.value == "$a" })
        #expect(target.content.isEmpty)
        #expect(target.unsigned?["redacted_because"] != nil)
    }

    @Test("Membership deltas set membership and inviter", arguments: membershipCases)
    func membership(_ row: MembershipCase) async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        switch row.membership {
        case "invite":
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                invited: [
                    roomId: InvitedRoomDelta(
                        events: [
                            StrippedStateEvent(
                                type: "m.room.member", stateKey: "@me:x",
                                sender: UserId(
                                    unchecked: row.inviter ?? "@alice:x"),
                                content: [
                                    "membership": .string("invite"),
                                    "displayname": .string("Alice"),
                                ])
                        ],
                        inviter: row.inviter.map(UserId.init(unchecked:)))
                ]))
        case "leave":
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                left: [roomId: LeftRoomDelta()]))
        case "knock":
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s1"),
                knocked: [roomId: KnockedRoomDelta()]))
        default:
            try await writer.apply(joinedTimelineDelta([]))
        }
        let stored = try self.room(container, "!room:x")
        #expect(stored.membership == row.membership)
        #expect(stored.inviterId == row.inviter)
    }

    @Test("Unread precompute skips own messages and edits", arguments: unreadCases)
    func unread(_ row: UnreadCase) async throws {
        let (writer, container) = try writer()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("a", ts: 1), unreadMessage("b", ts: 2)],
            unreadCount: 1))
        let extra: MessageEvent
        switch row.id {
        case "own":
            extra = ownMessage("c", ts: 3)
        case "edit":
            extra = editMessage("c", target: "a", ts: 3)
        default:
            extra = unreadMessage("c", ts: 3)
        }
        try await writer.apply(joinedTimelineDelta([extra], nextBatch: "s2"))
        try await writer.setFullyRead(
            roomId: RoomId(unchecked: "!room:x"),
            eventId: EventId(unchecked: "$a"))
        // Marker resolves to ts=1 in-window; only newer peer messages count.
        let stored = try self.room(container, "!room:x")
        #expect(stored.effectiveUnread == row.effective)
        #expect(stored.firstUnreadEventId == row.firstUnread)
    }

    @Test("Receipts advance the marker; fully-read resolves in-window")
    func markers() async throws {
        let (writer, container) = try writer()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("a", ts: 10), unreadMessage("b", ts: 20)]))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [
                RoomId(unchecked: "!room:x"): receiptDelta(
                    userId: "@me:x", eventId: "b", ts: 15)
            ]))
        #expect(try self.room(container, "!room:x").readMarkerTs == 15)
        // A stale receipt never moves the marker backwards.
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s3"),
            joined: [
                RoomId(unchecked: "!room:x"): receiptDelta(
                    userId: "@me:x", eventId: "a", ts: 5)
            ]))
        #expect(try self.room(container, "!room:x").readMarkerTs == 15)

        // Fully-read resolves its timestamp from the stored window.
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s4"),
            joined: [RoomId(unchecked: "!room:x"): fullyReadDelta("b")]))
        let stored = try self.room(container, "!room:x")
        #expect(stored.fullyRead == "$b")
        #expect(stored.readMarkerTs == 20)
        // Marker present in-window: nothing left to resolve.
        #expect(try await writer.markersNeedingResolution().isEmpty)
    }

    @Test("Unknown fully-read markers need resolution")
    func markerResolution() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [roomId: fullyReadDelta("old")]))
        #expect(
            try await writer.markersNeedingResolution().map(\.marker)
                == [EventId(unchecked: "$old")])
        // Stale resolutions (marker moved on) are ignored.
        try await writer.adoptResolvedMarkerTs(
            EventId(unchecked: "$other"), roomId: roomId, ts: 99)
        #expect(
            try await writer.markersNeedingResolution().map(\.marker)
                == [EventId(unchecked: "$old")])
        try await writer.adoptResolvedMarkerTs(
            EventId(unchecked: "$old"), roomId: roomId, ts: 7)
        #expect(try await writer.markersNeedingResolution().isEmpty)
    }

    @Test("Staged echoes confirm, fail, and suppress")
    func echoes() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let echo = snapshotMessage("echo", id: "$echo", sender: "@me:x")
        let txn = TransactionId("t1")
        try await writer.stageEcho(echo, roomId: roomId, transactionId: txn)
        #expect(try await writer.echoTransactionId(
            for: EventId(unchecked: "$echo")) == txn)
        // Sync confirms the send: the echo row is replaced.
        var confirmed = snapshotMessage("echo", id: "$srv", sender: "@me:x")
        confirmed.unsigned = ["transaction_id": .string("t1")]
        try await writer.apply(joinedTimelineDelta([confirmed]))
        var events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$srv"])

        // Failed sends stay visible with their reason.
        let echo2 = snapshotMessage("echo2", id: "$echo2", sender: "@me:x")
        try await writer.stageEcho(
            echo2, roomId: roomId, transactionId: TransactionId("t2"))
        try await writer.failEcho(
            transactionId: TransactionId("t2"), reason: "offline")
        events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value).contains("$echo2"))

        // Cancelled sends never resurface as zombies.
        let echo3 = snapshotMessage("echo3", id: "$echo3", sender: "@me:x")
        try await writer.stageEcho(
            echo3, roomId: roomId, transactionId: TransactionId("t3"))
        #expect(try await writer.cancelEcho(
            transactionId: TransactionId("t3")))
        await writer.suppressTransaction(TransactionId("t3"))
        var zombie = snapshotMessage("echo3", id: "$zombie", sender: "@me:x")
        zombie.unsigned = ["transaction_id": .string("t3")]
        try await writer.apply(joinedTimelineDelta([zombie]))
        events = try await writer.storedEvents(roomId: roomId)
        #expect(!events.map(\.eventId.value).contains("$zombie"))
    }

    @Test("m.direct account data pushes the direct flag")
    func directFlags() async throws {
        let (writer, container) = try writer()
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        try await writer.apply(joinedTimelineDelta([]))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            accountData: [
                BasicEvent(
                    type: "m.direct",
                    content: ["@me:x": .array([.string("!room:x")])])
            ]))
        #expect(try self.room(container, "!room:x").isDirect)
    }

    @Test("Sync and sliding cursors never thrash")
    func cursors() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta([], nextBatch: "s1"))
        var context = ModelContext(container)
        var meta = try #require(try context.fetch(
            FetchDescriptor<SDStoreMeta>()).first)
        #expect(meta.syncToken == "s1")
        #expect(meta.slidingPos == nil)
        try await writer.applySliding(joinedTimelineDelta([], nextBatch: "p9"))
        context = ModelContext(container)
        meta = try #require(try context.fetch(
            FetchDescriptor<SDStoreMeta>()).first)
        #expect(meta.syncToken == "s1")
        #expect(meta.slidingPos == "p9")
    }

    @Test("Pagination inserts history and advances the cursor")
    func pagination() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("b", ts: 20)], nextBatch: "s1"))
        try await writer.prependHistory(
            [unreadMessage("a", ts: 10), unreadMessage("b", ts: 20)],
            roomId: RoomId(unchecked: "!room:x"),
            prevBatch: BatchToken("p0"))
        let events = try await writer.storedEvents(
            roomId: RoomId(unchecked: "!room:x"))
        #expect(events.map(\.eventId.value) == ["$a", "$b"])
        let stored = try self.room(container, "!room:x")
        #expect(stored.prevBatch == "p0")
        #expect(stored.latestMessageTs == 20)
    }

    @Test("Ordinary syncs never clobber a pagination cursor")
    func syncKeepsPaginationCursor() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("a", ts: 1)], nextBatch: "s1"))
        try await writer.prependHistory(
            [], roomId: roomId, prevBatch: BatchToken("p0"))
        // An ordinary delta carrying a live-window cursor must not move
        // the pagination cursor backwards into the live window.
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [unreadMessage("b", ts: 2)],
                prevBatch: BatchToken("p9"))]))
        #expect(try self.room(container, "!room:x").prevBatch == "p0")
        // A gapped (`limited`) window re-anchors the cursor.
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s3"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [unreadMessage("c", ts: 3)],
                timelineLimited: true,
                prevBatch: BatchToken("p2"))]))
        #expect(try self.room(container, "!room:x").prevBatch == "p2")
    }

    @Test("Hierarchy rows persist on the space")
    func hierarchy() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta([]))
        try await writer.setHierarchy(
            [SpaceChild(
                roomId: RoomId(unchecked: "!room:x"), name: "General",
                memberCount: 42, roomType: .room, isJoined: true,
                joinRule: .restricted)],
            directChildren: [
                SpaceChildEdge(
                    roomId: RoomId(unchecked: "!room:x"), via: ["x"])
            ],
            nextBatch: BatchToken("t1"),
            for: RoomId(unchecked: "!room:x"))
        let stored = try self.room(container, "!room:x")
        #expect(stored.hierarchyNextBatch == "t1")
        #expect(stored.hierarchyChildren != nil)
        #expect(stored.hierarchyDirectChildren != nil)
    }

    @Test("Poll starts are message-like; votes and ends are not")
    func pollMessageLikeFlags() async throws {
        let (writer, container) = try writer()
        let pollBlock: [String: AnyCodable] = [
            "kind": .string("m.poll.disclosed"),
            "max_selections": .int(1),
            "answers": .array([]),
            "question": .object(["org.matrix.msc1767.text": .string("Lunch?")]),
        ]
        try await writer.apply(joinedTimelineDelta([
            MessageEvent(
                type: "m.poll.start", eventId: EventId(unchecked: "$poll"),
                sender: UserId(unchecked: "@alice:x"), originServerTs: 1_000,
                content: ["m.poll.start": .object(pollBlock)]),
            MessageEvent(
                type: "org.matrix.msc3381.poll.start",
                eventId: EventId(unchecked: "$poll-unstable"),
                sender: UserId(unchecked: "@alice:x"), originServerTs: 2_000,
                content: ["org.matrix.msc3381.poll.start": .object(pollBlock)]),
            MessageEvent(
                type: "m.poll.response", eventId: EventId(unchecked: "$vote"),
                sender: UserId(unchecked: "@bob:x"), originServerTs: 3_000,
                content: [:]),
            MessageEvent(
                type: "m.poll.end", eventId: EventId(unchecked: "$end"),
                sender: UserId(unchecked: "@alice:x"), originServerTs: 4_000,
                content: [:]),
        ]))
        let id = "!room:x"
        let rows = try ModelContext(container).fetch(FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.roomId == id }))
        let flags = Dictionary(uniqueKeysWithValues: rows.map { ($0.eventId, $0.isMessageLike) })
        #expect(flags["$poll"] == true)
        #expect(flags["$poll-unstable"] == true)
        #expect(flags["$vote"] == false)
        #expect(flags["$end"] == false)
    }

    // MARK: - Ported fold behaviors

    @Test("Redaction never overwrites a server-supplied stamp")
    func preservesServerStamp() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        var stamped = reactionEvent()
        stamped.unsigned = ["redacted_because": .object([
            "event_id": .string("$server"),
        ])]
        try await writer.apply(joinedTimelineDelta([stamped]))
        try await writer.apply(joinedTimelineDelta([redactionEvent("redaction", target: "reaction")]))
        let stored = try await writer.storedEvents(roomId: roomId)
        #expect(
            stored[0].unsigned?["redacted_because"]?.objectValue?["event_id"]?.stringValue
                == "$server")
    }

    @Test("Redactions of unknown events are ignored")
    func ignoresUnknownTargets() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta([reactionEvent()]))
        try await writer.apply(
            joinedTimelineDelta([redactionEvent("r", target: "elsewhere")]))
        let stored = try await writer.storedEvents(roomId: roomId)
        #expect(stored.first?.isRedacted == false)
    }

    @Test("Redaction prunes member content to membership only")
    func foldPrunesMemberContent() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta([
            memberStateEvent(
                "@alice:x", membership: "join", displayname: "Alice",
                id: "$member", ts: 1_700_000_000_000),
        ]))
        try await writer.apply(
            joinedTimelineDelta([redactionEvent("r", target: "member")]))
        let stored = try await writer.storedEvents(roomId: roomId)
        #expect(stored.count == 2)
        let target = try #require(stored.first { $0.eventId.value == "$member" })
        #expect(target.content["membership"]?.stringValue == "join")
        #expect(target.content["displayname"] == nil)
    }

    @Test("Suppression spares events with other transaction IDs")
    func suppressionIsSelective() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        await writer.suppressTransaction(TransactionId("t1"))
        var other = snapshotMessage("hi", id: "$other", sender: "@alice:x")
        other.unsigned = ["transaction_id": .string("t2")]
        try await writer.apply(joinedTimelineDelta([other]))
        let stored = try await writer.storedEvents(roomId: roomId)
        #expect(stored.map(\.eventId.value) == ["$other"])
    }

    struct TimelineAvatarCase: Sendable {
        var timelineURL: String?
        var stateURL: String?
        var limited: Bool
        var expected: String?
    }

    nonisolated static let timelineAvatarCases: [TimelineAvatarCase] = [
        TimelineAvatarCase(
            timelineURL: "mxc://x/avatar", stateURL: nil, limited: false,
            expected: "mxc://x/avatar"),
        TimelineAvatarCase(
            timelineURL: "mxc://x/new", stateURL: "mxc://x/old",
            limited: false, expected: "mxc://x/new"),
        TimelineAvatarCase(
            timelineURL: "mxc://x/new", stateURL: nil, limited: true,
            expected: "mxc://x/new"),
    ]

    private func avatarEvent(url: String?) -> MessageEvent {
        var content: [String: AnyCodable] = [:]
        if let url { content["url"] = .string(url) }
        return stateEvent(
            type: "m.room.avatar", id: "$avatar", content: content)
    }

    @Test("Timeline-carried avatar state applies", arguments: timelineAvatarCases)
    func timelineAvatar(_ row: TimelineAvatarCase) async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(
                timeline: row.timelineURL.map { [avatarEvent(url: $0)] } ?? [],
                timelineLimited: row.limited,
                state: row.stateURL.map { [avatarEvent(url: $0)] } ?? [])]))
        #expect(try self.room(container, "!room:x").avatarURL == row.expected)
    }

    @Test("Left rooms apply timeline-carried state")
    func leftAppliesTimelineState() async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            left: [RoomId(unchecked: "!room:x"): LeftRoomDelta(
                timeline: [
                    stateEvent(
                        type: "m.room.name", id: "$name",
                        content: ["name": .string("Left Name")])
                ])]))
        #expect(try self.room(container, "!room:x").name == "Left Name")
    }

    @Test("Plain timeline messages do not touch room state")
    func messagesDoNotTouchState() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta([
            snapshotMessage("hi", id: "$m", sender: "@alice:x"),
        ]))
        let stored = try self.room(container, "!room:x")
        #expect(stored.avatarURL == nil)
        #expect(stored.name == nil)
    }

    @Test("Out-of-band avatar URLs are adopted")
    func adoptAvatar() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta([]))
        try await writer.adoptAvatarURL(
            try? MXCURI("mxc://x/healed"),
            roomId: RoomId(unchecked: "!room:x"))
        #expect(
            try self.room(container, "!room:x").avatarURL == "mxc://x/healed")
    }

    @Test("Room state tracks alias, pins, tombstone, and space type")
    func roomDetailState() async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.canonical_alias",
                    content: [
                        "alias": .string("#room:x"),
                        "alt_aliases": .array([.string("#alt:x")]),
                    ]),
                stateEvent(
                    type: "m.room.pinned_events",
                    content: ["pinned": .array([.string("$p:x")])]),
                stateEvent(
                    type: "m.room.tombstone",
                    content: ["replacement_room": .string("!next:x")]),
                stateEvent(
                    type: "m.room.create",
                    content: ["type": .string("m.space")]),
            ])]))
        let context = ModelContext(container)
        let id = "!room:x"
        let row = try #require(try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first)
        #expect(row.canonicalAlias == "#room:x")
        #expect(row.successorRoomId == "!next:x")
        #expect(row.isSpace)
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode([String].self, from: row.altAliases ?? Data())
                == ["#alt:x"])
        #expect(
            try decoder.decode([String].self, from: row.pinnedEventIds ?? Data())
                == ["$p:x"])
    }

    @Test("Favourite flag follows room tags", arguments: [true, false])
    func favourite(favourite: Bool) async throws {
        let (writer, container) = try writer()
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(accountData: [
                BasicEvent(type: "m.tag", content: [
                    "tags": .object(favourite ? ["m.favourite": .object([:])] : [:]),
                ]),
            ])]))
        #expect(try self.room(container, "!room:x").isFavourite == favourite)
    }

    @Test("Space child edges clear on empty content")
    func spaceEdgeClearing() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [roomId: JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.space.child", stateKey: "!child:x",
                    content: ["via": .array([.string("x")])]),
            ])]))
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<SDRoomEdge>()).count == 1)
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [roomId: JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.space.child", stateKey: "!child:x", content: [:]),
            ])]))
        #expect(try context.fetch(FetchDescriptor<SDRoomEdge>()).isEmpty)
    }

    @Test("Canonical parents track the canonical flag")
    func canonicalParents() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        func parent(_ id: String, canonical: Bool?) -> MessageEvent {
            var content: [String: AnyCodable] = ["via": .array([.string("x")])]
            if let canonical { content["canonical"] = .bool(canonical) }
            return stateEvent(
                type: "m.space.parent", stateKey: id, content: content)
        }
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [roomId: JoinedRoomDelta(state: [
                parent("!a:x", canonical: true),
                parent("!z:x", canonical: true),
                parent("!m:x", canonical: nil),
            ])]))
        let context = ModelContext(container)
        let edgeKind = SDEdgeKind.canonicalParent.rawValue
        var canonical = try context.fetch(
            FetchDescriptor<SDRoomEdge>(
                predicate: #Predicate { $0.kind == edgeKind }))
        #expect(Set(canonical.map(\.peerRoomId)) == ["!a:x", "!z:x"])
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [roomId: JoinedRoomDelta(state: [
                parent("!z:x", canonical: false),
            ])]))
        canonical = try context.fetch(
            FetchDescriptor<SDRoomEdge>(
                predicate: #Predicate { $0.kind == edgeKind }))
        #expect(canonical.map(\.peerRoomId) == ["!a:x"])
    }

    @Test("Stripped create events flag invite and knock spaces")
    func strippedSpace() async throws {
        let (writer, container) = try writer()
        func create(space: Bool) -> StrippedStateEvent {
            StrippedStateEvent(
                type: "m.room.create", stateKey: "",
                sender: UserId(unchecked: "@alice:x"),
                content: space ? ["type": .string("m.space")] : [:])
        }
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            invited: [RoomId(unchecked: "!s:x"): InvitedRoomDelta(
                events: [create(space: true)],
                inviter: UserId(unchecked: "@alice:x"))]))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            knocked: [RoomId(unchecked: "!k:x"): KnockedRoomDelta(
                events: [create(space: false)])]))
        #expect(try self.room(container, "!s:x").isSpace)
        #expect(!(try self.room(container, "!k:x").isSpace))
    }

    @Test("Message previews skip non-message events")
    func messagePreview() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta(
            [
                stateEvent(
                    type: "m.room.name", id: "$n", ts: 1,
                    content: ["name": .string("General")]),
                snapshotMessage("hi", id: "$m", sender: "@alice:x"),
                reactionEvent("e", target: "m", ts: 1_700_000_000_001),
            ],
            nextBatch: "s1"))
        let stored = try self.room(container, "!room:x")
        #expect(stored.latestMessageTs == 1_700_000_000_001)
        let messages = try await writer.storedEvents(roomId: roomId)
        let preview = messages.last {
            $0.type == "m.room.message" || $0.type == "m.sticker"
        }
        #expect(preview?.eventId.value == "$m")
    }

    @Test("isDirect is spec-only: members alone never imply a DM")
    func directSpecOnly() async throws {
        let (writer, container) = try writer()
        try await writer.setLocalUser(UserId(unchecked: "@alice:x"))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!pair:x"): JoinedRoomDelta(state: [
                memberStateEvent("@alice:x", membership: "join", id: "$m1"),
                memberStateEvent("@bob:x", membership: "join", id: "$m2"),
            ])]))
        #expect(!(try self.room(container, "!pair:x").isDirect))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            accountData: [BasicEvent(type: "m.direct", content: [
                "@alice:x": .array([.string("!pair:x")]),
            ])]))
        #expect(try self.room(container, "!pair:x").isDirect)
    }

    @Test("Out-of-band members adopt without clobbering sync state")
    func adoptMember() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta([]))
        let user = UserId(unchecked: "@gray:x")
        try await writer.adoptMember(
            user,
            content: MemberContent(
                membership: .join, displayname: "Grayshade",
                avatarUrl: "mxc://x/gray"),
            roomId: roomId)
        let context = ModelContext(container)
        let key = "!room:x|@gray:x"
        var row = try #require(try context.fetch(
            FetchDescriptor<SDRoomMember>(
                predicate: #Predicate { $0.key == key })).first)
        #expect(row.displayname == "Grayshade")
        // A second adopt keeps the sync-known entry authoritative.
        try await writer.adoptMember(
            user,
            content: MemberContent(membership: .join, displayname: "Other"),
            roomId: roomId)
        row = try #require(try context.fetch(
            FetchDescriptor<SDRoomMember>(
                predicate: #Predicate { $0.key == key })).first)
        #expect(row.displayname == "Grayshade")
    }

    @Test("Bulk merges adopt unknowns and fill only missing fields")
    func mergeMemberProfiles() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(joinedTimelineDelta([]))
        let alice = UserId(unchecked: "@alice:x")
        try await writer.adoptMember(
            alice,
            content: MemberContent(membership: .join, displayname: "Known"),
            roomId: roomId)
        try await writer.mergeMemberProfiles(
            [
                // Unknown user: adopted outright, membership included.
                UserId(unchecked: "@new:x"): MemberContent(
                    membership: .join, displayname: "New",
                    avatarUrl: "mxc://x/new"),
                // Known user: missing avatar filled, stored name and
                // sync-authoritative membership kept.
                alice: MemberContent(
                    membership: .leave, displayname: "Other",
                    avatarUrl: "mxc://x/a"),
            ],
            roomId: roomId)
        let context = ModelContext(container)
        func row(_ user: String) throws -> SDRoomMember? {
            let key = "!room:x|\(user)"
            return try context.fetch(
                FetchDescriptor<SDRoomMember>(
                    predicate: #Predicate { $0.key == key })).first
        }
        let adopted = try #require(try row("@new:x"))
        #expect(adopted.membership == Membership.join.rawValue)
        #expect(adopted.displayname == "New")
        #expect(adopted.avatarUrl == "mxc://x/new")
        let kept = try #require(try row("@alice:x"))
        #expect(kept.membership == Membership.join.rawValue)
        #expect(kept.displayname == "Known")
        #expect(kept.avatarUrl == "mxc://x/a")
    }

    @Test("Encryption state tracks m.room.encryption")
    func encryptionFlag() async throws {
        let (writer, container) = try writer()
        try await writer.apply(joinedTimelineDelta([]))
        #expect(!(try self.room(container, "!room:x").isEncrypted))
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [RoomId(unchecked: "!room:x"): JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.encryption",
                    content: ["algorithm": .string("m.megolm.v1.aes-sha2")]),
            ])]))
        #expect(try self.room(container, "!room:x").isEncrypted)
    }

    @Test("Ciphertext rows round-trip through decrypt-and-replace")
    func ciphertextRefresh() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let cipher = MessageEvent(
            type: "m.room.encrypted",
            eventId: EventId(unchecked: "$c"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 5,
            content: ["ciphertext": .string("AAAA")])
        try await writer.apply(joinedTimelineDelta([cipher]))
        #expect(
            try await writer.encryptedEvents(roomId: roomId).map(\.eventId.value)
                == ["$c"])
        var plain = cipher
        plain.type = "m.room.message"
        plain.content = ["msgtype": .string("m.text"), "body": .string("hi")]
        try await writer.replaceEvent(plain, roomId: roomId)
        #expect(try await writer.encryptedEvents(roomId: roomId).isEmpty)
        let stored = try await writer.storedEvents(roomId: roomId)
        #expect(stored.first?.messageContent?.body == "hi")
    }

    // MARK: - Event trimming

    @Test("Basic cutoff deletes only rows older than it")
    func trimBasicCutoff() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let old = [unreadMessage("a", ts: 10), unreadMessage("b", ts: 20)]
        let new = [
            unreadMessage("c", ts: 100), unreadMessage("d", ts: 110),
            unreadMessage("e", ts: 120), unreadMessage("f", ts: 130),
        ]
        try await writer.apply(joinedTimelineDelta(old + new, nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$c", "$d", "$e", "$f"])
    }

    @Test("Floor keeps the newest minimum messages when all are older than cutoff")
    func trimFloorKeepsNewest() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 30), unreadMessage("d", ts: 40),
            unreadMessage("e", ts: 50),
        ]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 1000), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$c", "$d", "$e"])
    }

    @Test("Interleaved non-message events follow the message floor")
    func trimInterleaved() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 30), unreadMessage("d", ts: 40),
            unreadMessage("e", ts: 50),
        ]
        // Between "c" and "d": survives alongside the kept messages.
        let keptReaction = reactionEvent("r1", target: "c", ts: 35)
        // Older than the floor ("c" at ts 30): deleted with the rest.
        let droppedReaction = reactionEvent("r2", target: "a", ts: 15)
        try await writer.apply(joinedTimelineDelta(
            messages + [keptReaction, droppedReaction], nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 1000), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$c", "$r1", "$d", "$e"])
    }

    @Test("Rooms under the message floor are left untouched")
    func trimUnderFloor() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [unreadMessage("a", ts: 10), unreadMessage("b", ts: 20)]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 1000), keepingLatestMessages: 3)
        #expect(changed.isEmpty)
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$a", "$b"])
    }

    @Test("Membership churn doesn't count toward the message floor")
    func trimMembershipChurn() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let members = (1...5).map {
            memberStateEvent(
                "@user\($0):x", membership: "join", id: "$m\($0)", ts: $0)
        }
        let fewMessages = [unreadMessage("a", ts: 6), unreadMessage("b", ts: 7)]
        try await writer.apply(joinedTimelineDelta(
            members + fewMessages, nextBatch: "s1"))
        // Fewer than `minimum` messages: the room (and its old state
        // churn) is skipped entirely, even though it has plenty of rows.
        var changed = try await writer.trimEvents(
            olderThan: date(ms: 1000), keepingLatestMessages: 3)
        #expect(changed.isEmpty)
        var events = try await writer.storedEvents(roomId: roomId)
        #expect(events.count == members.count + fewMessages.count)

        // A third message reaches `minimum`; state older than the
        // resulting floor is now deleted.
        try await writer.apply(joinedTimelineDelta(
            [unreadMessage("c", ts: 8)], nextBatch: "s2"))
        changed = try await writer.trimEvents(
            olderThan: date(ms: 1000), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$a", "$b", "$c"])
    }

    @Test("Pending and failed echoes survive regardless of age")
    func trimEchoesSurvive() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("old", ts: 5),
            unreadMessage("a", ts: 100), unreadMessage("b", ts: 110),
            unreadMessage("c", ts: 120),
        ]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        try await writer.stageEcho(
            snapshotMessage("pending", id: "$pending", ts: 10),
            roomId: roomId, transactionId: TransactionId("t1"))
        try await writer.stageEcho(
            snapshotMessage("failed", id: "$failed", ts: 20),
            roomId: roomId, transactionId: TransactionId("t2"))
        try await writer.failEcho(
            transactionId: TransactionId("t2"), reason: "offline")

        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(
            Set(events.map(\.eventId.value))
                == ["$pending", "$failed", "$a", "$b", "$c"])
    }

    @Test("Trimming sets the gap anchor when prevBatch can no longer reach the new frontier")
    func trimSetsAnchor() async throws {
        let (writer, container) = try writer()
        // Event IDs are globally unique, so the two rooms need disjoint
        // IDs even though their shapes are identical.
        func messages(_ suffix: String) -> [MessageEvent] {
            [
                unreadMessage("a\(suffix)", ts: 10), unreadMessage("b\(suffix)", ts: 20),
                unreadMessage("c\(suffix)", ts: 100), unreadMessage("d\(suffix)", ts: 110),
                unreadMessage("e\(suffix)", ts: 120),
            ]
        }
        // Unknown cursor: prevBatchTs was never recorded.
        try await writer.apply(joinedTimelineDelta(
            messages("1"), roomId: "!unknown:x", nextBatch: "s1"))
        // Known cursor, but anchored older than the new frontier.
        try await writer.apply(joinedTimelineDelta(
            messages("2"), roomId: "!stale:x", nextBatch: "s1"))
        try await writer.prependHistory(
            [stateEvent(type: "m.room.name", id: "$old-state", ts: 5)],
            roomId: RoomId(unchecked: "!stale:x"), prevBatch: BatchToken("p0"))

        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(
            Set(changed)
                == [RoomId(unchecked: "!unknown:x"), RoomId(unchecked: "!stale:x")])
        #expect(try self.room(container, "!unknown:x").historyGapEventId == "$c1")
        #expect(try self.room(container, "!stale:x").historyGapEventId == "$c2")
    }

    @Test("A fresh prevBatch anchor is left alone")
    func trimLeavesFreshAnchor() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 100), unreadMessage("d", ts: 110),
            unreadMessage("e", ts: 120),
        ]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        try await writer.prependHistory(
            [stateEvent(type: "m.room.topic", id: "$anchor-marker", ts: 60)],
            roomId: roomId, prevBatch: BatchToken("p0"))
        #expect(try self.room(container, "!room:x").prevBatchTs == 60)

        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let stored = try self.room(container, "!room:x")
        #expect(stored.historyGapEventId == nil)
        #expect(stored.prevBatch == "p0")
    }

    @Test("prependHistory, resolveHistoryGap, and a limited apply each clear the anchor")
    func trimAnchorClearing() async throws {
        let (writer, container) = try writer()
        // Event IDs are globally unique, so each room needs its own set.
        func seedGap(_ roomId: String, suffix: String) async throws {
            try await writer.apply(joinedTimelineDelta(
                [
                    unreadMessage("a\(suffix)", ts: 10), unreadMessage("b\(suffix)", ts: 20),
                    unreadMessage("c\(suffix)", ts: 100), unreadMessage("d\(suffix)", ts: 110),
                    unreadMessage("e\(suffix)", ts: 120),
                ], roomId: roomId, nextBatch: "s1"))
            _ = try await writer.trimEvents(
                olderThan: date(ms: 50), keepingLatestMessages: 3)
            #expect(
                try self.room(container, roomId).historyGapEventId == "$c\(suffix)")
        }

        try await seedGap("!prepend:x", suffix: "1")
        try await writer.prependHistory(
            [unreadMessage("c1", ts: 100)],
            roomId: RoomId(unchecked: "!prepend:x"), prevBatch: BatchToken("p1"))
        #expect(try self.room(container, "!prepend:x").historyGapEventId == nil)

        try await seedGap("!context:x", suffix: "2")
        try await writer.resolveHistoryGap(
            [unreadMessage("c2", ts: 100)],
            roomId: RoomId(unchecked: "!context:x"), prevBatch: BatchToken("p1"))
        #expect(try self.room(container, "!context:x").historyGapEventId == nil)

        try await seedGap("!limited:x", suffix: "3")
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s2"),
            joined: [RoomId(unchecked: "!limited:x"): JoinedRoomDelta(
                timeline: [unreadMessage("f", ts: 130)],
                timelineLimited: true,
                prevBatch: BatchToken("p2"))]))
        #expect(try self.room(container, "!limited:x").historyGapEventId == nil)
    }

    @Test("prevBatchTs records the oldest event at the pagination boundary")
    func prevBatchTsRecorded() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s1"),
            joined: [roomId: JoinedRoomDelta(
                timeline: [unreadMessage("a", ts: 10), unreadMessage("b", ts: 20)],
                prevBatch: BatchToken("p0"))]))
        #expect(try self.room(container, "!room:x").prevBatchTs == 10)

        try await writer.prependHistory(
            [unreadMessage("z", ts: 1)], roomId: roomId, prevBatch: BatchToken("p-1"))
        #expect(try self.room(container, "!room:x").prevBatchTs == 1)
    }

    @Test("A second trim with the same cutoff is a no-op")
    func trimIdempotent() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 100), unreadMessage("d", ts: 110),
            unreadMessage("e", ts: 120),
        ]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        let first = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(first == [roomId])
        let second = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(second.isEmpty)
    }

    @Test("A busy room with enough recent messages is trimmed at the cutoff alone")
    func trimBusyRoomUsesCutoff() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 100), unreadMessage("d", ts: 110),
            unreadMessage("e", ts: 120), unreadMessage("f", ts: 130),
        ]
        // Older than the floor ("d" at 110) but newer than the cutoff:
        // the cutoff governs, so it survives.
        let reaction = reactionEvent("r1", target: "c", ts: 60)
        try await writer.apply(joinedTimelineDelta(
            messages + [reaction], nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(changed == [roomId])
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.map(\.eventId.value) == ["$r1", "$c", "$d", "$e", "$f"])
    }

    @Test("A trim with nothing older than the cutoff returns no rooms")
    func trimNothingOld() async throws {
        let (writer, _) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        let messages = (1...5).map { unreadMessage("m\($0)", ts: 100 + $0) }
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        let changed = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        #expect(changed.isEmpty)
        let events = try await writer.storedEvents(roomId: roomId)
        #expect(events.count == 5)
    }

    @Test("Trimming recomputes unread counts from the surviving rows")
    func trimRecomputesUnread() async throws {
        let (writer, container) = try writer()
        let roomId = RoomId(unchecked: "!room:x")
        try await writer.setLocalUser(UserId(unchecked: "@me:x"))
        let messages = [
            unreadMessage("a", ts: 10), unreadMessage("b", ts: 20),
            unreadMessage("c", ts: 100), unreadMessage("d", ts: 110),
            unreadMessage("e", ts: 120),
        ]
        try await writer.apply(joinedTimelineDelta(messages, nextBatch: "s1"))
        try await writer.setFullyRead(
            roomId: roomId, eventId: EventId(unchecked: "$a"))
        // Before trimming: four peer messages newer than the marker.
        #expect(try self.room(container, "!room:x").effectiveUnread == 4)
        #expect(try self.room(container, "!room:x").firstUnreadEventId == "$b")

        _ = try await writer.trimEvents(
            olderThan: date(ms: 50), keepingLatestMessages: 3)
        let stored = try self.room(container, "!room:x")
        // "a" and "b" are gone; the new first-unread is the oldest survivor.
        #expect(stored.effectiveUnread == 3)
        #expect(stored.firstUnreadEventId == "$c")
    }
}
#endif
