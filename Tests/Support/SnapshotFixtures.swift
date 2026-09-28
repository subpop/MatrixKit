import Foundation
import MatrixKit

/// Shared snapshot-cache fixtures, moved from the per-file builders in
/// `SQLiteCacheTests` / `SwiftDataCacheTests` / `StoreSnapshotTests`.
/// Suites needing a different shape keep their own local builder.

/// A minimal `m.room.message` event for snapshot timelines.
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

/// The standard populated snapshot both cache backends round-trip:
/// one joined room ("General") with a member, a timeline event,
/// unreads, a prev-batch, account data, and a sync token.
public func populatedSnapshot(
    notificationMode: RoomNotificationMode? = nil
) -> StoreSnapshot {
    let roomId = RoomId(unchecked: "!room1:example.com")
    return StoreSnapshot(
        syncToken: "s105_106",
        localUser: UserId(unchecked: "@me:example.com"),
        accountData: ["m.push_rules": ["global": .string("yes")]],
        rooms: [
            RoomSnapshot(
                roomId: roomId,
                name: "General",
                membership: .join,
                members: [
                    UserId(unchecked: "@alice:example.com"): MemberContent(
                        membership: .join, displayname: "Alice")
                ],
                timeline: [snapshotMessage("hello")],
                unreadCount: 3,
                highlightCount: 1,
                prevBatch: "s100_101",
                notificationMode: notificationMode
            )
        ]
    )
}
