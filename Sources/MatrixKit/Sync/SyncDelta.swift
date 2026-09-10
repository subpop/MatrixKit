/// Parsed sync output: diff-friendly per-room deltas.
///
/// `SyncResponseParser` converts raw `SyncResponse` values into `SyncDelta`;
/// `StateStore.apply(_:)` consumes them.
public struct SyncDelta: Hashable, Sendable {
    /// Pagination cursor for the next sync (`since`). Persist this to make
    /// the next launch an incremental sync instead of a full one.
    public var nextBatch: BatchToken
    /// Changed joined rooms, keyed by room ID.
    public var joined: [RoomId: JoinedRoomDelta]
    /// New/updated invites, keyed by room ID.
    public var invited: [RoomId: InvitedRoomDelta]
    /// Rooms left or removed, keyed by room ID.
    public var left: [RoomId: LeftRoomDelta]
    /// Knock (ask-to-join) state changes, keyed by room ID.
    public var knocked: [RoomId: KnockedRoomDelta]
    /// Top-level account-data events (push rules, `m.fully_read`, …).
    public var accountData: [BasicEvent]
    /// To-device messages (verification flows, key shares, …).
    public var toDevice: [BasicEvent]
    /// Users whose device lists changed (re-query `/keys/query`).
    public var deviceChanged: [UserId]
    /// Users who left all shared rooms (drop their cached keys).
    public var deviceLeft: [UserId]
    /// Server-reported remaining `signed_curve25519` one-time keys.
    /// Nil when the response carries no count (e.g. sliding sync).
    public var signedKeyCount: Int?

    public init(
        nextBatch: BatchToken,
        joined: [RoomId: JoinedRoomDelta] = [:],
        invited: [RoomId: InvitedRoomDelta] = [:],
        left: [RoomId: LeftRoomDelta] = [:],
        knocked: [RoomId: KnockedRoomDelta] = [:],
        accountData: [BasicEvent] = [],
        toDevice: [BasicEvent] = [],
        deviceChanged: [UserId] = [],
        deviceLeft: [UserId] = [],
        signedKeyCount: Int? = nil
    ) {
        self.nextBatch = nextBatch
        self.joined = joined
        self.invited = invited
        self.left = left
        self.knocked = knocked
        self.accountData = accountData
        self.toDevice = toDevice
        self.deviceChanged = deviceChanged
        self.deviceLeft = deviceLeft
        self.signedKeyCount = signedKeyCount
    }
}

/// Delta for a joined room.
public struct JoinedRoomDelta: Hashable, Sendable {
    /// New timeline events since the last sync, oldest first.
    public var timeline: [MessageEvent]
    /// True when `timeline` is a window after a gap — the client must
    /// replace (not append) its local timeline.
    public var timelineLimited: Bool
    /// Pagination cursor for older history (`GET /messages`).
    public var prevBatch: BatchToken?
    /// New state events (name, topic, membership, …).
    public var state: [MessageEvent]
    /// Ephemeral events (typing, receipts). Never persisted.
    public var ephemeral: [BasicEvent]
    /// Total unread notifications (server-computed).
    public var unreadCount: Int
    /// Highlighted (mention/keyword) notification count.
    public var highlightCount: Int
    /// Candidate room heroes for display-name fallback.
    public var heroes: [UserId]
    /// Room-scoped account data (tags, …).
    public var accountData: [BasicEvent]

    public init(
        timeline: [MessageEvent] = [],
        timelineLimited: Bool = false,
        prevBatch: BatchToken? = nil,
        state: [MessageEvent] = [],
        ephemeral: [BasicEvent] = [],
        unreadCount: Int = 0,
        highlightCount: Int = 0,
        heroes: [UserId] = [],
        accountData: [BasicEvent] = []
    ) {
        self.timeline = timeline
        self.timelineLimited = timelineLimited
        self.prevBatch = prevBatch
        self.state = state
        self.ephemeral = ephemeral
        self.unreadCount = unreadCount
        self.highlightCount = highlightCount
        self.heroes = heroes
        self.accountData = accountData
    }
}

/// Delta for an invited room (stripped state only).
public struct InvitedRoomDelta: Hashable, Sendable {
    /// Stripped invite state (inviter member event, room name, …).
    public var events: [StrippedStateEvent]
    /// Who sent the invite, extracted from the member event.
    public var inviter: UserId?

    public init(events: [StrippedStateEvent] = [], inviter: UserId? = nil) {
        self.events = events
        self.inviter = inviter
    }
}

/// Delta for a left room.
public struct LeftRoomDelta: Hashable, Sendable {
    /// Final timeline events (e.g. the leave event itself).
    public var timeline: [MessageEvent]
    /// State at leave time.
    public var state: [MessageEvent]
    /// Room-scoped account data (tags, …).
    public var accountData: [BasicEvent]

    public init(
        timeline: [MessageEvent] = [], state: [MessageEvent] = [],
        accountData: [BasicEvent] = []
    ) {
        self.timeline = timeline
        self.state = state
        self.accountData = accountData
    }
}

/// Delta for a knocked room (stripped state only).
public struct KnockedRoomDelta: Hashable, Sendable {
    /// Stripped knock state.
    public var events: [StrippedStateEvent]

    public init(events: [StrippedStateEvent] = []) {
        self.events = events
    }
}
