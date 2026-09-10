/// Sync API models (`GET /sync` response).

/// Top-level `GET /sync` response body.
public struct SyncResponse: Hashable, Sendable, Codable {
    /// Cursor for the next sync (`since`). Always present.
    public var nextBatch: String
    /// Per-room updates. Nil when nothing changed.
    public var rooms: SyncRooms?
    /// Presence updates, if requested by the filter.
    public var presence: PresenceChunk?
    /// Top-level account-data updates.
    public var accountData: AccountDataChunk?
    /// Pending to-device messages (E2EE — consumed by sync crypto hooks).
    public var toDevice: ToDeviceChunk?
    /// Device list changes (E2EE — consumed by sync crypto hooks).
    public var deviceLists: DeviceLists?
    /// Remaining one-time-key counts by algorithm (E2EE).
    public var deviceOneTimeKeysCount: [String: Int]?
    /// Unused fallback-key types (E2EE).
    public var deviceUnusedFallbackKeyTypes: [String]?

    public init(
        nextBatch: String,
        rooms: SyncRooms? = nil,
        presence: PresenceChunk? = nil,
        accountData: AccountDataChunk? = nil,
        toDevice: ToDeviceChunk? = nil,
        deviceLists: DeviceLists? = nil,
        deviceOneTimeKeysCount: [String: Int]? = nil,
        deviceUnusedFallbackKeyTypes: [String]? = nil
    ) {
        self.nextBatch = nextBatch
        self.rooms = rooms
        self.presence = presence
        self.accountData = accountData
        self.toDevice = toDevice
        self.deviceLists = deviceLists
        self.deviceOneTimeKeysCount = deviceOneTimeKeysCount
        self.deviceUnusedFallbackKeyTypes = deviceUnusedFallbackKeyTypes
    }

    private enum CodingKeys: String, CodingKey {
        case nextBatch = "next_batch"
        case rooms
        case presence
        case accountData = "account_data"
        case toDevice = "to_device"
        case deviceLists = "device_lists"
        case deviceOneTimeKeysCount = "device_one_time_keys_count"
        case deviceUnusedFallbackKeyTypes = "device_unused_fallback_key_types"
    }
}

/// The `rooms` section of a sync response.
///
/// Servers omit empty sections, so each key falls back to `[:]`.
public struct SyncRooms: Hashable, Sendable, Codable {
    /// Joined rooms with updates, keyed by room ID.
    public var join: [String: JoinedRoomSync]
    /// Invites, keyed by room ID.
    public var invite: [String: InvitedRoomSync]
    /// Left rooms, keyed by room ID.
    public var leave: [String: LeftRoomSync]
    /// Knocked rooms, keyed by room ID.
    public var knock: [String: KnockedRoomSync]

    public init(
        join: [String: JoinedRoomSync] = [:],
        invite: [String: InvitedRoomSync] = [:],
        leave: [String: LeftRoomSync] = [:],
        knock: [String: KnockedRoomSync] = [:]
    ) {
        self.join = join
        self.invite = invite
        self.leave = leave
        self.knock = knock
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.join = try container.decodeIfPresent([String: JoinedRoomSync].self, forKey: .join) ?? [:]
        self.invite = try container.decodeIfPresent([String: InvitedRoomSync].self, forKey: .invite) ?? [:]
        self.leave = try container.decodeIfPresent([String: LeftRoomSync].self, forKey: .leave) ?? [:]
        self.knock = try container.decodeIfPresent([String: KnockedRoomSync].self, forKey: .knock) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case join
        case invite
        case leave
        case knock
    }
}

/// Sync data for a joined room.
public struct JoinedRoomSync: Hashable, Sendable, Codable {
    /// New timeline events.
    public var timeline: TimelineChunk?
    /// New state events.
    public var state: StateChunk?
    /// Ephemeral events (typing, receipts).
    public var ephemeral: EphemeralChunk?
    /// Room-scoped account data.
    public var accountData: AccountDataChunk?
    /// Unread counts.
    public var unreadNotifications: UnreadNotifications?
    /// Heroes and member counts for name fallback.
    public var summary: RoomSummary?

    public init(
        timeline: TimelineChunk? = nil,
        state: StateChunk? = nil,
        ephemeral: EphemeralChunk? = nil,
        accountData: AccountDataChunk? = nil,
        unreadNotifications: UnreadNotifications? = nil,
        summary: RoomSummary? = nil
    ) {
        self.timeline = timeline
        self.state = state
        self.ephemeral = ephemeral
        self.accountData = accountData
        self.unreadNotifications = unreadNotifications
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case timeline
        case state
        case ephemeral
        case accountData = "account_data"
        case unreadNotifications = "unread_notifications"
        case summary
    }
}

/// Sync data for an invited room (stripped state only).
public struct InvitedRoomSync: Hashable, Sendable, Codable {
    /// Stripped invite state (inviter, room name, …).
    public var inviteState: InviteState

    public init(inviteState: InviteState) {
        self.inviteState = inviteState
    }

    private enum CodingKeys: String, CodingKey {
        case inviteState = "invite_state"
    }
}

/// Sync data for a left room.
public struct LeftRoomSync: Hashable, Sendable, Codable {
    /// Final timeline events (leave event, …).
    public var timeline: TimelineChunk?
    /// State at leave time.
    public var state: StateChunk?
    /// Room-scoped account data.
    public var accountData: AccountDataChunk?

    public init(
        timeline: TimelineChunk? = nil,
        state: StateChunk? = nil,
        accountData: AccountDataChunk? = nil
    ) {
        self.timeline = timeline
        self.state = state
        self.accountData = accountData
    }

    private enum CodingKeys: String, CodingKey {
        case timeline
        case state
        case accountData = "account_data"
    }
}

/// Sync data for a knocked room (stripped state only).
public struct KnockedRoomSync: Hashable, Sendable, Codable {
    /// Stripped knock state.
    public var knockState: InviteState

    public init(knockState: InviteState) {
        self.knockState = knockState
    }

    private enum CodingKeys: String, CodingKey {
        case knockState = "knock_state"
    }
}

/// A room timeline chunk from sync. Servers may omit `events` when empty.
public struct TimelineChunk: Hashable, Sendable, Codable {
    /// Timeline events, oldest first.
    public var events: [MessageEvent]
    /// True when the window starts after a gap — replace, don't append.
    public var limited: Bool?
    /// Pagination cursor for older history.
    public var prevBatch: String?

    public init(events: [MessageEvent] = [], limited: Bool? = nil, prevBatch: String? = nil) {
        self.events = events
        self.limited = limited
        self.prevBatch = prevBatch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([MessageEvent].self, forKey: .events) ?? []
        self.limited = try container.decodeIfPresent(Bool.self, forKey: .limited)
        self.prevBatch = try container.decodeIfPresent(String.self, forKey: .prevBatch)
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case limited
        case prevBatch = "prev_batch"
    }
}

/// A state chunk from sync.
public struct StateChunk: Hashable, Sendable, Codable {
    /// State events in this chunk.
    public var events: [MessageEvent]

    public init(events: [MessageEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([MessageEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }
}

/// A wire event without a stable event ID: ephemeral (`m.typing`,
/// `m.receipt`), presence, account-data, and to-device events.
///
/// Unlike `MessageEvent`, these never appear in timelines — servers omit
/// `event_id`, and account-data/ephemeral events also omit `sender` and
/// `origin_server_ts` — so every field but `type` is optional.
public struct BasicEvent: Hashable, Sendable, Codable {
    /// Event type (`m.typing`, `m.receipt`, …). The only required field.
    public var type: String
    /// Sender, when present (absent on account-data/ephemeral events).
    public var sender: UserId?
    /// Event payload.
    public var content: [String: AnyCodable]
    /// Server-supplied metadata, when present.
    public var unsigned: [String: AnyCodable]?

    public init(
        type: String,
        sender: UserId? = nil,
        content: [String: AnyCodable] = [:],
        unsigned: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.sender = sender
        self.content = content
        self.unsigned = unsigned
    }
}

/// An ephemeral-events chunk (`m.typing`, `m.receipt`, ...).
public struct EphemeralChunk: Hashable, Sendable, Codable {
    /// Ephemeral events (`m.typing`, `m.receipt`, …).
    public var events: [BasicEvent]

    public init(events: [BasicEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([BasicEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }
}

/// Stripped state for invites/knocks.
public struct InviteState: Hashable, Sendable, Codable {
    /// Stripped state events describing the invite/knock.
    public var events: [StrippedStateEvent]

    public init(events: [StrippedStateEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([StrippedStateEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }
}

/// A stripped state event (no `event_id`, limited fields).
public struct StrippedStateEvent: Hashable, Sendable, Codable {
    /// Event type (typically `m.room.member` for invites).
    public var type: String
    /// State key (the subject MXID for member events).
    public var stateKey: String
    /// Who sent the invite.
    public var sender: UserId
    /// Stripped content (membership, display name, …).
    public var content: [String: AnyCodable]

    public init(type: String, stateKey: String, sender: UserId, content: [String: AnyCodable]) {
        self.type = type
        self.stateKey = stateKey
        self.sender = sender
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case stateKey = "state_key"
        case sender
        case content
    }
}

/// Unread notification counts for a room.
public struct UnreadNotifications: Hashable, Sendable, Codable {
    /// Total unread notifications (server-computed).
    public var notificationCount: Int
    /// Highlighted (mention/keyword) notifications.
    public var highlightCount: Int

    public init(notificationCount: Int = 0, highlightCount: Int = 0) {
        self.notificationCount = notificationCount
        self.highlightCount = highlightCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.notificationCount = try container.decodeIfPresent(Int.self, forKey: .notificationCount) ?? 0
        self.highlightCount = try container.decodeIfPresent(Int.self, forKey: .highlightCount) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case notificationCount = "notification_count"
        case highlightCount = "highlight_count"
    }
}

/// Room summary (heroes, member counts) from sync.
public struct RoomSummary: Hashable, Sendable, Codable {
    /// Candidate members for display-name fallback.
    public var heroes: [UserId]?
    /// Joined member count.
    public var joinedMemberCount: Int?
    /// Invited member count.
    public var invitedMemberCount: Int?

    public init(
        heroes: [UserId]? = nil,
        joinedMemberCount: Int? = nil,
        invitedMemberCount: Int? = nil
    ) {
        self.heroes = heroes
        self.joinedMemberCount = joinedMemberCount
        self.invitedMemberCount = invitedMemberCount
    }

    private enum CodingKeys: String, CodingKey {
        case heroes = "m.heroes"
        case joinedMemberCount = "m.joined_member_count"
        case invitedMemberCount = "m.invited_member_count"
    }
}

/// Presence updates from sync.
public struct PresenceChunk: Hashable, Sendable, Codable {
    /// Presence updates.
    public var events: [BasicEvent]

    public init(events: [BasicEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([BasicEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }
}

/// Account-data updates from sync.
public struct AccountDataChunk: Hashable, Sendable, Codable {
    /// Account-data events.
    public var events: [BasicEvent]

    public init(events: [BasicEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decodeIfPresent([BasicEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }
}

/// To-device messages from sync. `SyncClient` hands these to its crypto
/// hooks (`m.room_key` events route into `RoomCrypto`); the store itself
/// never persists them.
public struct ToDeviceChunk: Hashable, Sendable, Codable {
    /// Pending to-device messages.
    public var events: [BasicEvent]
    /// Cursor acknowledging receipt (send back as `since` next time).
    public var nextBatch: String?

    public init(events: [BasicEvent] = [], nextBatch: String? = nil) {
        self.events = events
        self.nextBatch = nextBatch
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case nextBatch = "next_batch"
    }
}

/// Device list deltas from sync. `SyncClient` hands these to its crypto
/// hooks (stale entries invalidate the `OlmConnector` device cache).
public struct DeviceLists: Hashable, Sendable, Codable {
    /// Users whose device lists changed (re-query keys).
    public var changed: [UserId]?
    /// Users who left all shared rooms (drop their keys).
    public var left: [UserId]?

    public init(changed: [UserId]? = nil, left: [UserId]? = nil) {
        self.changed = changed
        self.left = left
    }
}

/// A sync filter (`POST /user/{userId}/filter` / inline `filter` param).
public struct SyncFilter: Hashable, Sendable, Codable {
    /// Room-scoped filtering (timelines, state, ephemeral).
    public var room: RoomFilter?
    /// Presence filtering.
    public var presence: EventFilter?
    /// Top-level account-data filtering.
    public var accountData: EventFilter?
    /// Restrict returned events to these JSON fields.
    public var eventFields: [String]?
    /// Event format (`client` or `federation`).
    public var eventFormat: String?

    public init(
        room: RoomFilter? = nil,
        presence: EventFilter? = nil,
        accountData: EventFilter? = nil,
        eventFields: [String]? = nil,
        eventFormat: String? = nil
    ) {
        self.room = room
        self.presence = presence
        self.accountData = accountData
        self.eventFields = eventFields
        self.eventFormat = eventFormat
    }

    private enum CodingKeys: String, CodingKey {
        case room
        case presence
        case accountData = "account_data"
        case eventFields = "event_fields"
        case eventFormat = "event_format"
    }
}

extension SyncFilter {
    /// Lean filter for initial syncs on large homeservers: small timeline,
    /// lazy-loaded membership (only members in the timeline), no redundant
    /// member state. Shrinks matrix.org-style initial syncs from tens of
    /// MiB to a fraction of that.
    public static var leanInitial: SyncFilter {
        SyncFilter(
            room: RoomFilter(
                timeline: RoomEventFilter(
                    limit: 50, lazyLoadMembers: true,
                    includeRedundantMembers: false),
                state: StateFilter(
                    lazyLoadMembers: true,
                    includeRedundantMembers: false)
            )
        )
    }
}

/// Room-scoped sync filter.
public struct RoomFilter: Hashable, Sendable, Codable {
    /// Only these rooms.
    public var rooms: [RoomId]?
    /// Exclude these rooms.
    public var notRooms: [RoomId]?
    /// Timeline filtering (limits, lazy members, …).
    public var timeline: RoomEventFilter?
    /// State filtering.
    public var state: StateFilter?
    /// Ephemeral filtering.
    public var ephemeral: RoomEventFilter?
    /// Room account-data filtering.
    public var accountData: RoomEventFilter?
    /// Include left rooms in the response.
    public var includeLeave: Bool?

    public init(
        rooms: [RoomId]? = nil,
        notRooms: [RoomId]? = nil,
        timeline: RoomEventFilter? = nil,
        state: StateFilter? = nil,
        ephemeral: RoomEventFilter? = nil,
        accountData: RoomEventFilter? = nil,
        includeLeave: Bool? = nil
    ) {
        self.rooms = rooms
        self.notRooms = notRooms
        self.timeline = timeline
        self.state = state
        self.ephemeral = ephemeral
        self.accountData = accountData
        self.includeLeave = includeLeave
    }

    private enum CodingKeys: String, CodingKey {
        case rooms
        case notRooms = "not_rooms"
        case timeline
        case state
        case ephemeral
        case accountData = "account_data"
        case includeLeave = "include_leave"
    }
}

/// Generic event filter (presence, account data).
public struct EventFilter: Hashable, Sendable, Codable {
    /// Max events to return.
    public var limit: Int?
    /// Only these event types.
    public var types: [String]?
    /// Exclude these event types.
    public var notTypes: [String]?
    /// Only events from these senders.
    public var senders: [UserId]?
    /// Exclude events from these senders.
    public var notSenders: [UserId]?

    public init(
        limit: Int? = nil,
        types: [String]? = nil,
        notTypes: [String]? = nil,
        senders: [UserId]? = nil,
        notSenders: [UserId]? = nil
    ) {
        self.limit = limit
        self.types = types
        self.notTypes = notTypes
        self.senders = senders
        self.notSenders = notSenders
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case types
        case notTypes = "not_types"
        case senders
        case notSenders = "not_senders"
    }
}

/// Room timeline/ephemeral event filter.
public struct RoomEventFilter: Hashable, Sendable, Codable {
    /// Max events to return.
    public var limit: Int?
    /// Only these event types.
    public var types: [String]?
    /// Exclude these event types.
    public var notTypes: [String]?
    /// Only events from these senders.
    public var senders: [UserId]?
    /// Exclude events from these senders.
    public var notSenders: [UserId]?
    /// Only include member events for timeline participants (big bandwidth win).
    public var lazyLoadMembers: Bool?
    /// Include member events already seen (redundant with lazy loading).
    public var includeRedundantMembers: Bool?

    public init(
        limit: Int? = nil,
        types: [String]? = nil,
        notTypes: [String]? = nil,
        senders: [UserId]? = nil,
        notSenders: [UserId]? = nil,
        lazyLoadMembers: Bool? = nil,
        includeRedundantMembers: Bool? = nil
    ) {
        self.limit = limit
        self.types = types
        self.notTypes = notTypes
        self.senders = senders
        self.notSenders = notSenders
        self.lazyLoadMembers = lazyLoadMembers
        self.includeRedundantMembers = includeRedundantMembers
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case types
        case notTypes = "not_types"
        case senders
        case notSenders = "not_senders"
        case lazyLoadMembers = "lazy_load_members"
        case includeRedundantMembers = "include_redundant_members"
    }
}

/// Room state filter.
public struct StateFilter: Hashable, Sendable, Codable {
    /// Max state events to return.
    public var limit: Int?
    /// Only these state event types.
    public var types: [String]?
    /// Exclude these state event types.
    public var notTypes: [String]?
    /// Only state from these senders.
    public var senders: [UserId]?
    /// Exclude state from these senders.
    public var notSenders: [UserId]?
    /// Only include member events for timeline participants.
    public var lazyLoadMembers: Bool?
    /// Include member events already seen.
    public var includeRedundantMembers: Bool?

    public init(
        limit: Int? = nil,
        types: [String]? = nil,
        notTypes: [String]? = nil,
        senders: [UserId]? = nil,
        notSenders: [UserId]? = nil,
        lazyLoadMembers: Bool? = nil,
        includeRedundantMembers: Bool? = nil
    ) {
        self.limit = limit
        self.types = types
        self.notTypes = notTypes
        self.senders = senders
        self.notSenders = notSenders
        self.lazyLoadMembers = lazyLoadMembers
        self.includeRedundantMembers = includeRedundantMembers
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case types
        case notTypes = "not_types"
        case senders
        case notSenders = "not_senders"
        case lazyLoadMembers = "lazy_load_members"
        case includeRedundantMembers = "include_redundant_members"
    }
}
