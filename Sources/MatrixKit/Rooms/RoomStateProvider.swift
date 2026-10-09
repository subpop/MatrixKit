/// Cached per-room state for API clients that enrich network responses
/// with local state (space hierarchy caching, search result names).
/// A nil summary means the room is unknown; callers fall back to the
/// network, exactly as with a cache miss.
public struct RoomStateSummary: Hashable, Sendable {
    public var membership: Membership?
    public var name: String?
    public var avatarURL: String?
    public var isSpace: Bool
    public var spaceChildren: Set<RoomId>
    public var powerLevels: [String: AnyCodable]?
    public var hierarchyChildren: [SpaceChild]
    public var hierarchyDirectChildren: [SpaceChildEdge]

    public init(
        membership: Membership? = nil,
        name: String? = nil,
        avatarURL: String? = nil,
        isSpace: Bool = false,
        spaceChildren: Set<RoomId> = [],
        powerLevels: [String: AnyCodable]? = nil,
        hierarchyChildren: [SpaceChild] = [],
        hierarchyDirectChildren: [SpaceChildEdge] = []
    ) {
        self.membership = membership
        self.name = name
        self.avatarURL = avatarURL
        self.isSpace = isSpace
        self.spaceChildren = spaceChildren
        self.powerLevels = powerLevels
        self.hierarchyChildren = hierarchyChildren
        self.hierarchyDirectChildren = hierarchyDirectChildren
    }
}

/// Room-state reads for API clients. Implemented by the normalized
/// store adapter (and any other local-state source); every read is
/// best-effort enrichment over an authoritative network source, so
/// callers treat misses as cache misses.
public protocol RoomStateProvider: Sendable {
    /// Cached state for a room, or nil when unknown.
    func roomState(_ roomId: RoomId) async -> RoomStateSummary?
    /// Adopt fetched hierarchy rows for a space (overwrites), creating
    /// the entry when unknown.
    func setHierarchy(
        _ children: [SpaceChild],
        directChildren: [SpaceChildEdge],
        nextBatch: BatchToken?,
        for spaceId: RoomId
    ) async throws
    /// Joined rooms flagged as spaces.
    func spaceRoomIds() async -> [RoomId]
    /// Membership details for one user, if known.
    func member(_ roomId: RoomId, userId: UserId) async -> MemberContent?
}
