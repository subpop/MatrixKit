/// Versioned on-disk snapshots of client state (`StateStore` + rooms).
///
/// A snapshot lets the client show rooms and timelines immediately on launch
/// while background sync converges to live state. See `DiskCache` for
/// persistence and `StateStore.snapshot()/restore(_:)` for conversion.
public struct StoreSnapshot: Hashable, Sendable, Codable {
    /// Schema version. Snapshots with a mismatched version are ignored.
    public var version: Int
    /// Sync cursor for the next incremental sync.
    public var syncToken: BatchToken?
    /// Logged-in user at snapshot time (scopes the cache to one account).
    public var localUser: UserId?
    /// Top-level account data by event type.
    public var accountData: [String: [String: AnyCodable]]
    /// Per-room state.
    public var rooms: [RoomSnapshot]

    public init(
        version: Int = SnapshotVersion.current,
        syncToken: BatchToken? = nil,
        localUser: UserId? = nil,
        accountData: [String: [String: AnyCodable]] = [:],
        rooms: [RoomSnapshot] = []
    ) {
        self.version = version
        self.syncToken = syncToken
        self.localUser = localUser
        self.accountData = accountData
        self.rooms = rooms
    }
}

/// Serializable per-room state (a trimmed `RoomActor`).
public struct RoomSnapshot: Hashable, Sendable, Codable {
    /// Timeline events kept per room (newest). Bounds snapshot size.
    public static let maxTimelineEvents = 100

    /// The room's Matrix ID.
    public var roomId: RoomId
    /// Explicit name, if known.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Membership at snapshot time.
    public var membership: Membership
    /// Known members and their details.
    public var members: [UserId: MemberContent]
    /// Newest timeline window (trimmed to `maxTimelineEvents`).
    public var timeline: [MessageEvent]
    /// Unread notification count.
    public var unreadCount: Int
    /// Highlighted notification count.
    public var highlightCount: Int
    /// Pagination cursor for older history.
    public var prevBatch: BatchToken?
    /// Latest fully-read event.
    public var fullyReadEventId: EventId?
    /// Client-side read-marker timestamp (ms since epoch), if known.
    /// Optional so snapshots written before this field decode as nil.
    public var readMarkerTsMs: Int?
    /// Effective notification mode at snapshot time, if hydrated.
    /// Optional so snapshots written before this field decode as nil.
    public var notificationMode: RoomNotificationMode?
    /// Whether the room is encrypted.
    public var isEncrypted: Bool
    /// Canonical alias, if set.
    public var canonicalAlias: String?
    /// Alternative aliases.
    public var altAliases: [String]
    /// Pinned event IDs.
    public var pinnedEventIds: [String]
    /// Successor room after an upgrade, if any.
    public var successorRoomId: String?
    /// Whether the room is a space.
    public var isSpace: Bool
    /// Whether the room is a direct chat.
    public var isDirect: Bool
    /// Whether the room carries the `m.favourite` tag.
    public var isFavourite: Bool
    /// Child rooms from `m.space.child` state.
    public var spaceChildren: [RoomId]
    /// Parent spaces from `m.space.parent` state.
    public var spaceParents: [RoomId]
    /// Parent spaces flagged canonical (`canonical: true`).
    public var canonicalParentIds: [RoomId]
    /// Raw `m.room.power_levels` content, if known. Persisted so
    /// `SpacesClient.editableSpaces()` skips the per-space `getState`
    /// network fan-out when power levels are already on disk.
    public var powerLevelsContent: [String: AnyCodable]?
    /// Last-known sync heroes for the display-name fallback.
    public var heroes: [UserId]
    /// Last-fetched hierarchy rows for this space (MSC2946), including
    /// server-reported member counts for unjoined children. Cached so a
    /// space's detail renders instantly; refreshed from the network on open.
    public var hierarchyChildren: [SpaceChild]
    /// Direct-child edges from the space's own hierarchy entry (ordering),
    /// persisted alongside the rows.
    public var hierarchyDirectChildren: [SpaceChildEdge]
    /// Cursor for the next hierarchy page, if any.
    public var hierarchyNextBatch: BatchToken?

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: MXCURI? = nil,
        membership: Membership = .join,
        members: [UserId: MemberContent] = [:],
        timeline: [MessageEvent] = [],
        unreadCount: Int = 0,
        highlightCount: Int = 0,
        prevBatch: BatchToken? = nil,
        fullyReadEventId: EventId? = nil,
        readMarkerTsMs: Int? = nil,
        notificationMode: RoomNotificationMode? = nil,
        isEncrypted: Bool = false,
        canonicalAlias: String? = nil,
        altAliases: [String] = [],
        pinnedEventIds: [String] = [],
        successorRoomId: String? = nil,
        isSpace: Bool = false,
        isDirect: Bool = false,
        isFavourite: Bool = false,
        spaceChildren: [RoomId] = [],
        spaceParents: [RoomId] = [],
        canonicalParentIds: [RoomId] = [],
        powerLevelsContent: [String: AnyCodable]? = nil,
        heroes: [UserId] = [],
        hierarchyChildren: [SpaceChild] = [],
        hierarchyDirectChildren: [SpaceChildEdge] = [],
        hierarchyNextBatch: BatchToken? = nil
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.membership = membership
        self.members = members
        // Keep only the newest window — history re-fetches via /messages.
        self.timeline = Array(timeline.suffix(Self.maxTimelineEvents))
        self.unreadCount = unreadCount
        self.highlightCount = highlightCount
        self.prevBatch = prevBatch
        self.fullyReadEventId = fullyReadEventId
        self.readMarkerTsMs = readMarkerTsMs
        self.notificationMode = notificationMode
        self.isEncrypted = isEncrypted
        self.canonicalAlias = canonicalAlias
        self.altAliases = altAliases
        self.pinnedEventIds = pinnedEventIds
        self.successorRoomId = successorRoomId
        self.isSpace = isSpace
        self.isDirect = isDirect
        self.isFavourite = isFavourite
        self.spaceChildren = spaceChildren
        self.spaceParents = spaceParents
        self.canonicalParentIds = canonicalParentIds
        self.powerLevelsContent = powerLevelsContent
        self.heroes = heroes
        self.hierarchyChildren = hierarchyChildren
        self.hierarchyDirectChildren = hierarchyDirectChildren
        self.hierarchyNextBatch = hierarchyNextBatch
    }
}

/// Snapshot schema version, shared by `StoreSnapshot` and its caches
/// (SQLite now; the old JSON file before it).
public enum SnapshotVersion {
    /// Current schema. Bump when snapshot shape changes; old snapshots are
    /// discarded (never migrated — sync rebuilds them).
    public static let current = 8
}
