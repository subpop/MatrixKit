/// Cached per-room state for API clients such as spaces, search, and
/// permission lookup. A nil summary means the room is unknown; callers
/// may fall back to the network.
public struct RoomStateSummary: Hashable, Sendable {
    public var membership: Membership?
    public var name: String?
    public var avatarURL: String?
    public var isSpace: Bool
    public var spaceChildren: Set<RoomId>
    public var powerLevels: [String: AnyCodable]?
    public var createEventSender: UserId?
    public var createEventContent: [String: AnyCodable]?
    public var hierarchyChildren: [SpaceChild]
    public var hierarchyDirectChildren: [SpaceChildEdge]

    public init(
        membership: Membership? = nil,
        name: String? = nil,
        avatarURL: String? = nil,
        isSpace: Bool = false,
        spaceChildren: Set<RoomId> = [],
        powerLevels: [String: AnyCodable]? = nil,
        createEventSender: UserId? = nil,
        createEventContent: [String: AnyCodable]? = nil,
        hierarchyChildren: [SpaceChild] = [],
        hierarchyDirectChildren: [SpaceChildEdge] = []
    ) {
        self.membership = membership
        self.name = name
        self.avatarURL = avatarURL
        self.isSpace = isSpace
        self.spaceChildren = spaceChildren
        self.powerLevels = powerLevels
        self.createEventSender = createEventSender
        self.createEventContent = createEventContent
        self.hierarchyChildren = hierarchyChildren
        self.hierarchyDirectChildren = hierarchyDirectChildren
    }
}

/// Local room-state access for API clients. Missing summaries or fields
/// are cache misses; callers may fall back to the homeserver.
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

    /// Adopt the current permission-relevant room state after a cache miss.
    func setRoomPermissionState(
        _ roomId: RoomId,
        createEventSender: UserId,
        createEventContent: [String: AnyCodable],
        powerLevels: [String: AnyCodable]?
    ) async throws

    /// Adopt member profiles fetched from the homeserver.
    func setRoomMemberProfiles(_ members: [MemberInfo], for roomId: RoomId) async throws
}

public extension RoomStateProvider {
    func setRoomPermissionState(
        _ roomId: RoomId,
        createEventSender: UserId,
        createEventContent: [String: AnyCodable],
        powerLevels: [String: AnyCodable]?
    ) async throws {}

    func setRoomMemberProfiles(_ members: [MemberInfo], for roomId: RoomId) async throws {}
}
