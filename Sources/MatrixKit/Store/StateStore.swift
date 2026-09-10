/// Central client-side state: rooms, sync token, account data.
///
/// All sync deltas flow through `apply(_:)`; per-room state lives in
/// `RoomActor` instances created on demand.
public actor StateStore {
    private var rooms: [RoomId: RoomActor] = [:]
    private var accountData: [String: [String: AnyCodable]] = [:]
    /// Latest sync cursor. Persist via `snapshot()` to make the next launch
    /// incremental.
    public private(set) var syncToken: BatchToken?
    /// The logged-in user, propagated to rooms for name fallbacks/receipts.
    public private(set) var localUser: UserId?

    public init() {}

    /// Set the local user and propagate to all known rooms.
    public func setLocalUser(_ userId: UserId) async {
        localUser = userId
        let rooms = rooms.values
        for room in rooms {
            await room.setLocalUser(userId)
        }
    }

    // MARK: - Rooms

    /// Fetch (creating if needed) the actor for a room.
    public func room(_ roomId: RoomId, membership: Membership = .join) -> RoomActor {
        if let existing = rooms[roomId] {
            return existing
        }
        let actor = RoomActor(roomId: roomId, membership: membership)
        rooms[roomId] = actor
        if let localUser {
            Task { await actor.setLocalUser(localUser) }
        }
        return actor
    }

    /// Whether a room actor exists for this ID.
    public func hasRoom(_ roomId: RoomId) -> Bool {
        rooms[roomId] != nil
    }

    /// The actor for a known room, or nil (never creates).
    public func existingRoom(_ roomId: RoomId) -> RoomActor? {
        rooms[roomId]
    }

    /// Actors for all joined rooms (never creates; skips invites/leaves).
    public func joinedRooms() async -> [RoomActor] {
        var out: [RoomActor] = []
        for room in rooms.values {
            guard await room.membership == .join else { continue }
            out.append(room)
        }
        return out
    }

    /// Joined room IDs flagged as spaces.
    public func spaceRoomIds() async -> [RoomId] {
        var ids: [RoomId] = []
        for (id, room) in rooms {
            guard await room.membership == .join else { continue }
            if await room.isSpace {
                ids.append(id)
            }
        }
        return ids
    }

    /// IDs of all known rooms, regardless of membership.
    public var allRoomIds: [RoomId] {
        Array(rooms.keys)
    }

    /// IDs of rooms with `.join` membership.
    public func joinedRoomIds() async -> [RoomId] {
        var result: [RoomId] = []
        for (id, room) in rooms where await room.membership == .join {
            result.append(id)
        }
        return result
    }

    /// IDs of rooms with `.invite` membership.
    public func invitedRoomIds() async -> [RoomId] {
        var result: [RoomId] = []
        for (id, room) in rooms where await room.membership == .invite {
            result.append(id)
        }
        return result
    }

    /// Adopt fetched hierarchy rows for a space (overwrites), so the
    /// detail view's next open renders from the snapshot. When the space
    /// has no actor yet (e.g. browsing an unjoined space), the actor is
    /// created with `.leave` membership so it stays out of joined lists;
    /// sync corrects membership afterwards.
    public func setHierarchy(
        _ children: [SpaceChild], directChildren: [SpaceChildEdge] = [],
        nextBatch: BatchToken?, for spaceId: RoomId
    ) async {
        let actor: RoomActor
        if let existing = existingRoom(spaceId) {
            actor = existing
        } else {
            actor = room(spaceId, membership: .leave)
        }
        await actor.setHierarchy(
            children: children, directChildren: directChildren,
            nextBatch: nextBatch)
    }

    // MARK: - Sync token & account data

    /// Advance the sync cursor (called by `apply(_:)` per delta).
    public func setSyncToken(_ token: BatchToken) {
        syncToken = token
    }

    /// Store top-level account data by event type (e.g. `m.push_rules`).
    public func setAccountData(type: String, content: [String: AnyCodable]) {
        accountData[type] = content
    }

    /// Fetch top-level account data by event type, if seen.
    public func getAccountData(type: String) -> [String: AnyCodable]? {
        accountData[type]
    }

    /// Direct-chat room IDs for a user from `m.direct` account data.
    public func directRooms(for userId: UserId) -> Set<RoomId> {
        guard let rooms = accountData["m.direct"]?[userId.value]?.arrayValue else {
            return []
        }
        return Set(rooms.compactMap { $0.stringValue.map(RoomId.init(unchecked:)) })
    }

    // MARK: - Delta application

    /// Apply a parsed sync delta: route per-room changes, store the cursor.
    public func apply(_ delta: SyncDelta) async {
        setSyncToken(delta.nextBatch)
        for (roomId, roomDelta) in delta.joined {
            await room(roomId).applyJoined(roomDelta)
        }
        for (roomId, roomDelta) in delta.invited {
            await room(roomId, membership: .invite).applyInvite(roomDelta)
        }
        for (roomId, roomDelta) in delta.left {
            await room(roomId, membership: .leave).applyLeft(roomDelta)
        }
        for (roomId, roomDelta) in delta.knocked {
            await room(roomId, membership: .knock).applyKnock(roomDelta)
        }
        for event in delta.accountData {
            setAccountData(type: event.type, content: event.content)
        }
        await pushDirectFlags()
    }

    /// Apply a sliding sync delta: route per-room changes and account data
    /// like `apply(_:)`, but leave the v2 `syncToken` untouched — the
    /// sliding `pos` cursor is connection-scoped and owned by
    /// `SlidingSyncClient`, so the two engines never thrash one cursor.
    public func applySliding(_ delta: SyncDelta) async {
        for (roomId, roomDelta) in delta.joined {
            await room(roomId).applyJoined(roomDelta)
        }
        for (roomId, roomDelta) in delta.invited {
            await room(roomId, membership: .invite).applyInvite(roomDelta)
        }
        for (roomId, roomDelta) in delta.left {
            await room(roomId, membership: .leave).applyLeft(roomDelta)
        }
        for (roomId, roomDelta) in delta.knocked {
            await room(roomId, membership: .knock).applyKnock(roomDelta)
        }
        for event in delta.accountData {
            setAccountData(type: event.type, content: event.content)
        }
        await pushDirectFlags()
    }

    /// Push `m.direct` membership into each room's direct flag.
    /// `setDirect` notifies only on change, so steady state is cheap.
    private func pushDirectFlags() async {
        guard let localUser else { return }
        let direct = directRooms(for: localUser)
        for (id, room) in rooms {
            await room.setDirect(direct.contains(id))
        }
    }

    /// Snapshot infos for all known rooms (for room lists).
    public func roomInfos() async -> [RoomInfo] {
        var infos: [RoomInfo] = []
        for room in rooms.values {
            infos.append(await room.info())
        }
        return infos
    }

    // MARK: - Snapshots

    /// Capture serializable state for the on-disk cache.
    public func snapshot() async -> StoreSnapshot {
        var roomSnapshots: [RoomSnapshot] = []
        roomSnapshots.reserveCapacity(rooms.count)
        for room in rooms.values {
            roomSnapshots.append(await room.snapshot())
        }
        return StoreSnapshot(
            syncToken: syncToken,
            localUser: localUser,
            accountData: accountData,
            rooms: roomSnapshots
        )
    }

    /// Restore state from the on-disk cache (loaded before sync converges).
    /// Rooms absent from the snapshot are left untouched.
    public func restore(_ snapshot: StoreSnapshot) async {
        guard snapshot.version == SnapshotVersion.current else { return }
        if let localUser = snapshot.localUser {
            await setLocalUser(localUser)
        }
        if let token = snapshot.syncToken {
            setSyncToken(token)
        }
        for (type, content) in snapshot.accountData {
            setAccountData(type: type, content: content)
        }
        for roomSnapshot in snapshot.rooms {
            await room(roomSnapshot.roomId, membership: roomSnapshot.membership)
                .restore(roomSnapshot)
        }
    }
}
