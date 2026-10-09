import Foundation
import MatrixKit

/// Shared event and delta builders for store/writer suites.
/// Suites needing a different shape keep their own local builder.

/// A minimal `m.room.message` event for timelines.
public func snapshotMessage(
    _ body: String,
    id: String = "$e",
    sender: String = "@alice:example.com",
    ts: Int = 1_700_000_000_000
) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: id),
        sender: UserId(unchecked: sender),
        originServerTs: ts,
        content: ["msgtype": .string("m.text"), "body": .string(body)]
    )
}

/// A `m.room.message` from someone else (counts toward unread).
public func unreadMessage(_ id: String, ts: Int) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: ts,
        content: ["body": .string(id)])
}

/// A `m.room.message` from the local user (never counts toward unread).
public func ownMessage(_ id: String, ts: Int) -> MessageEvent {
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

/// An `m.replace` edit (folds into its target, never counts toward unread).
public func editMessage(_ id: String, target: String, ts: Int) -> MessageEvent {
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

/// A state event with an explicit state key.
public func stateEvent(
    type: String,
    stateKey: String = "",
    sender: String = "@alice:x",
    id: String = "$s",
    ts: Int = 1_700_000_000_000,
    content: [String: AnyCodable] = [:]
) -> MessageEvent {
    MessageEvent(
        type: type,
        eventId: EventId(unchecked: id),
        sender: UserId(unchecked: sender),
        stateKey: stateKey,
        originServerTs: ts,
        content: content)
}

/// An `m.room.member` state event for a user.
public func memberStateEvent(
    _ userId: String,
    membership: String,
    displayname: String? = nil,
    id: String = "$m",
    ts: Int = 1_700_000_000_000
) -> MessageEvent {
    var content: [String: AnyCodable] = ["membership": .string(membership)]
    if let displayname {
        content["displayname"] = .string(displayname)
    }
    return stateEvent(
        type: "m.room.member", stateKey: userId, id: id, ts: ts,
        content: content)
}

/// An `m.room.redaction` targeting another event.
public func redactionEvent(
    _ id: String, target: String, ts: Int = 1_700_000_000_001
) -> MessageEvent {
    MessageEvent(
        type: "m.room.redaction",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        redacts: EventId(unchecked: "$\(target)"),
        originServerTs: ts,
        content: [:])
}

/// An `m.reaction` annotation targeting another event.
public func reactionEvent(
    _ id: String = "reaction", target: String = "target",
    ts: Int = 1_700_000_000_000
) -> MessageEvent {
    MessageEvent(
        type: "m.reaction",
        eventId: EventId(unchecked: "$\(id)"),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: ts,
        content: ["m.relates_to": .object([
            "event_id": .string("$\(target)"),
            "rel_type": .string("m.annotation"),
            "key": .string("👍"),
        ])])
}

/// A `m.fully_read` room account-data delta for one event.
public func fullyReadDelta(_ eventId: String) -> JoinedRoomDelta {
    JoinedRoomDelta(accountData: [
        BasicEvent(
            type: "m.fully_read",
            content: ["event_id": .string("$\(eventId)")])
    ])
}

/// An `m.receipt` ephemeral delta with our own read timestamp.
public func receiptDelta(
    userId: String, eventId: String, ts: Int, threaded: Bool = false
) -> JoinedRoomDelta {
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

/// A sync delta carrying one joined room's timeline.
public func joinedTimelineDelta(
    _ events: [MessageEvent],
    roomId: String = "!room:x",
    nextBatch: String = "s1",
    unreadCount: Int = 0
) -> SyncDelta {
    SyncDelta(
        nextBatch: BatchToken(nextBatch),
        joined: [
            RoomId(unchecked: roomId): JoinedRoomDelta(
                timeline: events, unreadCount: unreadCount)
        ])
}
