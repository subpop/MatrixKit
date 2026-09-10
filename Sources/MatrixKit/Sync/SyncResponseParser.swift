import Foundation

/// Converts raw `SyncResponse` values into `SyncDelta`.
public enum SyncResponseParser {
    /// Map a decoded sync response onto per-room deltas. Total function:
    /// missing sections decode to empty defaults, never throws.
    public static func parse(_ response: SyncResponse) -> SyncDelta {
        let nextBatch = BatchToken(response.nextBatch)
        var joined: [RoomId: JoinedRoomDelta] = [:]
        var invited: [RoomId: InvitedRoomDelta] = [:]
        var left: [RoomId: LeftRoomDelta] = [:]
        var knocked: [RoomId: KnockedRoomDelta] = [:]

        for (roomIdString, sync) in response.rooms?.join ?? [:] {
            let roomId = RoomId(unchecked: roomIdString)
            joined[roomId] = JoinedRoomDelta(
                timeline: sync.timeline?.events ?? [],
                timelineLimited: sync.timeline?.limited ?? false,
                prevBatch: sync.timeline?.prevBatch.map { BatchToken($0) },
                state: sync.state?.events ?? [],
                ephemeral: sync.ephemeral?.events ?? [],
                unreadCount: sync.unreadNotifications?.notificationCount ?? 0,
                highlightCount: sync.unreadNotifications?.highlightCount ?? 0,
                heroes: sync.summary?.heroes ?? [],
                accountData: sync.accountData?.events ?? []
            )
        }
        for (roomIdString, sync) in response.rooms?.invite ?? [:] {
            let roomId = RoomId(unchecked: roomIdString)
            invited[roomId] = InvitedRoomDelta(
                events: sync.inviteState.events,
                inviter: inviteSender(from: sync.inviteState.events)
            )
        }
        for (roomIdString, sync) in response.rooms?.leave ?? [:] {
            let roomId = RoomId(unchecked: roomIdString)
            left[roomId] = LeftRoomDelta(
                timeline: sync.timeline?.events ?? [],
                state: sync.state?.events ?? [],
                accountData: sync.accountData?.events ?? []
            )
        }
        for (roomIdString, sync) in response.rooms?.knock ?? [:] {
            let roomId = RoomId(unchecked: roomIdString)
            knocked[roomId] = KnockedRoomDelta(events: sync.knockState.events)
        }

        return SyncDelta(
            nextBatch: nextBatch,
            joined: joined,
            invited: invited,
            left: left,
            knocked: knocked,
            accountData: response.accountData?.events ?? [],
            toDevice: response.toDevice?.events ?? [],
            deviceChanged: response.deviceLists?.changed ?? [],
            deviceLeft: response.deviceLists?.left ?? [],
            signedKeyCount: response.deviceOneTimeKeysCount?["signed_curve25519"]
        )
    }

    /// The sender of the `m.room.member` invite event, if present.
    private static func inviteSender(from events: [StrippedStateEvent]) -> UserId? {
        events.first {
            EventType(rawValue: $0.type) == .roomMember
                && $0.content["membership"]?.stringValue == Membership.invite.rawValue
        }?.sender
    }

    /// Encode a `SyncFilter` as the JSON string for the `filter` query param.
    public static func encodeFilter(_ filter: SyncFilter) throws(MatrixError) -> String {
        guard let data = try? JSONEncoder().encode(filter),
              let json = String(data: data, encoding: .utf8)
        else {
            throw .encodingError("Could not encode SyncFilter")
        }
        return json
    }
}
