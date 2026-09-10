/// Simplified sliding sync (MSC4186) wire types and parser.
/// See `SlidingSyncClient` for the long-poll loop.
///
/// v1 scope: room lists with window ranges plus per-room subscriptions
/// (`conn_id`, `pos`, `lists`, `room_subscriptions`). MSC4186 list results
/// carry only `count` — there are no incremental list ops (those were
/// MSC3575); clients sort with `bump_stamp`. The E2EE, to-device, and
/// typing (MSC4508) extensions feed the shared crypto hooks and the room
/// ephemeral stream; other extensions decode opaquely and are ignored.
import Foundation

// MARK: - Request

/// Typing extension knobs (`extensions.typing`, MSC4508). Latest-state
/// semantics: the server sends the current typing users per in-scope
/// room, replacing the client's previous state.
public struct TypingExtension: Hashable, Sendable, Codable {
    /// Request typing notifications.
    public var enabled: Bool
    /// List keys the extension applies to. Nil matches all lists.
    public var lists: [String]?
    /// Subscribed room IDs the extension applies to. Nil matches all
    /// subscriptions.
    public var rooms: [String]?

    public init(enabled: Bool = true, lists: [String]? = nil, rooms: [String]? = nil) {
        self.enabled = enabled
        self.lists = lists
        self.rooms = rooms
    }
}

/// E2EE extension knobs (`extensions.e2ee`).
public struct E2EEExtension: Hashable, Sendable, Codable {
    /// Request device lists and one-time-key counts.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

/// To-device extension knobs (`extensions.to_device`).
public struct ToDeviceExtension: Hashable, Sendable, Codable {
    /// Request to-device messages.
    public var enabled: Bool
    /// Max messages per response.
    public var limit: Int?
    /// Stream position from the previous `to_device.next_batch`.
    public var since: String?

    public init(enabled: Bool = true, limit: Int? = nil, since: String? = nil) {
        self.enabled = enabled
        self.limit = limit
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case limit
        case since
    }
}

/// Requested extensions (`extensions`).
public struct SlidingSyncExtensions: Hashable, Sendable, Codable {
    /// E2EE extension (device lists).
    public var e2ee: E2EEExtension?
    /// To-device extension.
    public var toDevice: ToDeviceExtension?
    /// Typing notifications (MSC4508). Enabled by default for parity
    /// with the v2 loop, which always receives ephemeral events.
    public var typing: TypingExtension?

    public init(
        e2ee: E2EEExtension? = nil,
        toDevice: ToDeviceExtension? = nil,
        typing: TypingExtension? = nil
    ) {
        self.e2ee = e2ee
        self.toDevice = toDevice
        self.typing = typing
    }

    private enum CodingKeys: String, CodingKey {
        case e2ee
        case toDevice = "to_device"
        case typing
    }
}

/// A sliding window over the room list (`lists` map value).
public struct SlidingSyncList: Hashable, Sendable, Codable {
    /// Index ranges to fetch, e.g. `[[0, 19]]` for the first 20 rooms.
    public var ranges: [[Int]]
    /// Required state per room, as `[eventType, stateKey]` pairs.
    public var requiredState: [[String]]?
    /// Max timeline events per room.
    public var timelineLimit: Int

    public init(ranges: [[Int]], requiredState: [[String]]? = nil, timelineLimit: Int) {
        self.ranges = ranges
        self.requiredState = requiredState
        self.timelineLimit = timelineLimit
    }

    private enum CodingKeys: String, CodingKey {
        case ranges
        case requiredState = "required_state"
        case timelineLimit = "timeline_limit"
    }
}

/// A per-room subscription (`room_subscriptions` map value).
public struct SlidingSyncRoomSubscription: Hashable, Sendable, Codable {
    /// Required state, as `[eventType, stateKey]` pairs.
    public var requiredState: [[String]]?
    /// Max timeline events for the room.
    public var timelineLimit: Int

    public init(requiredState: [[String]]? = nil, timelineLimit: Int) {
        self.requiredState = requiredState
        self.timelineLimit = timelineLimit
    }

    private enum CodingKeys: String, CodingKey {
        case requiredState = "required_state"
        case timelineLimit = "timeline_limit"
    }
}

/// Request body for the sliding sync endpoint.
public struct SlidingSyncRequest: Hashable, Sendable, Codable {
    /// Connection ID; stable across requests on one connection.
    public var connId: String?
    /// Position cursor from the previous response. Nil on first request.
    public var pos: String?
    /// Long-poll duration in milliseconds.
    public var timeoutMs: Int?
    /// Named sliding windows (v1 uses a single list).
    public var lists: [String: SlidingSyncList]
    /// Explicit per-room subscriptions, keyed by room ID string.
    public var roomSubscriptions: [String: SlidingSyncRoomSubscription]
    /// Room ID strings to drop from subscriptions.
    public var unsubscribeRooms: [String]?
    /// Enabled extensions (E2EE, to-device). Nil requests none.
    public var extensions: SlidingSyncExtensions?

    public init(
        connId: String? = nil,
        pos: String? = nil,
        timeoutMs: Int? = nil,
        lists: [String: SlidingSyncList] = [:],
        roomSubscriptions: [String: SlidingSyncRoomSubscription] = [:],
        unsubscribeRooms: [String]? = nil,
        extensions: SlidingSyncExtensions? = nil
    ) {
        self.connId = connId
        self.pos = pos
        self.timeoutMs = timeoutMs
        self.lists = lists
        self.roomSubscriptions = roomSubscriptions
        self.unsubscribeRooms = unsubscribeRooms
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey {
        case connId = "conn_id"
        case pos
        case timeoutMs = "timeout"
        case lists
        case roomSubscriptions = "room_subscriptions"
        case unsubscribeRooms = "unsubscribe_rooms"
        case extensions
    }
}

// MARK: - Response

/// Response body from the sliding sync endpoint.
public struct SlidingSyncResponse: Hashable, Sendable, Codable {
    /// New position cursor; send as `pos` on the next request.
    public var pos: String
    /// Sliding-window results, keyed by list name.
    public var lists: [String: SlidingSyncListResult]
    /// Room payloads, keyed by room ID string.
    public var rooms: [String: SlidingSyncRoom]
    /// Extension payloads (typing, receipts, E2EE, …). The E2EE and
    /// to-device extensions parse into `SyncDelta`; the rest decode
    /// opaquely and are ignored.
    public var extensions: [String: AnyCodable]?

    public init(
        pos: String,
        lists: [String: SlidingSyncListResult] = [:],
        rooms: [String: SlidingSyncRoom] = [:],
        extensions: [String: AnyCodable]? = nil
    ) {
        self.pos = pos
        self.lists = lists
        self.rooms = rooms
        self.extensions = extensions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pos = try container.decode(String.self, forKey: .pos)
        self.lists = try container.decodeIfPresent([String: SlidingSyncListResult].self, forKey: .lists) ?? [:]
        self.rooms = try container.decodeIfPresent([String: SlidingSyncRoom].self, forKey: .rooms) ?? [:]
        self.extensions = try container.decodeIfPresent([String: AnyCodable].self, forKey: .extensions)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pos, forKey: .pos)
        try container.encode(lists, forKey: .lists)
        try container.encode(rooms, forKey: .rooms)
        try container.encodeIfPresent(extensions, forKey: .extensions)
    }

    private enum CodingKeys: String, CodingKey {
        case pos
        case lists
        case rooms
        case extensions
    }
}

/// Result for one sliding window. MSC4186 carries only `count` — list
/// operations (`SYNC`/`INSERT`/`DELETE`) were MSC3575 and never appear
/// here; decode tolerates them for forward compatibility only.
public struct SlidingSyncListResult: Hashable, Sendable, Codable {
    /// Total rooms matching the list (may exceed the window).
    public var count: Int
    /// Decoded list ops, always empty on MSC4186 servers. Retained so
    /// unknown shapes decode instead of failing.
    public var ops: [SlidingSyncOp]

    public init(count: Int = 0, ops: [SlidingSyncOp] = []) {
        self.count = count
        self.ops = ops
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        self.ops = try container.decodeIfPresent([SlidingSyncOp].self, forKey: .ops) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(ops, forKey: .ops)
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case ops
    }
}

/// One list operation (`SYNC`, `INSERT`, `DELETE`, `INVALIDATE`).
/// MSC3575 only — MSC4186 servers never send these.
public struct SlidingSyncOp: Hashable, Sendable, Codable {
    /// Operation name.
    public var op: String
    /// Affected index range, for range ops.
    public var range: [Int]?
    /// Affected room IDs, for `SYNC` ops.
    public var roomIds: [String]?
    /// Affected index, for point ops.
    public var index: Int?

    public init(op: String, range: [Int]? = nil, roomIds: [String]? = nil, index: Int? = nil) {
        self.op = op
        self.range = range
        self.roomIds = roomIds
        self.index = index
    }

    private enum CodingKeys: String, CodingKey {
        case op
        case range
        case roomIds = "room_ids"
        case index
    }
}

/// A room hero for display-name fallback (`heroes` entries).
public struct SlidingSyncHero: Hashable, Sendable, Codable {
    /// Hero's user ID.
    public var userId: UserId

    public init(userId: UserId) {
        self.userId = userId
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

/// Per-room payload in a sliding sync response.
public struct SlidingSyncRoom: Hashable, Sendable, Codable {
    /// Room display-name shortcut.
    public var name: String?
    /// Room avatar shortcut (`mxc://…`).
    public var avatar: String?
    /// True when `requiredState`/`timeline` carry full (not incremental) data.
    public var initial: Bool
    /// Requested state events (name, membership, encryption, …).
    public var requiredState: [MessageEvent]
    /// Timeline events, oldest first.
    public var timeline: [MessageEvent]
    /// True when `timeline` is a window after a gap — replace, don't append.
    public var limited: Bool
    /// Pagination cursor for older history (`GET /messages`).
    public var prevBatch: String?
    /// Total unread notifications (server-computed).
    public var unreadCount: Int
    /// Highlighted (mention/keyword) notifications.
    public var highlightCount: Int
    /// Hero users for display-name fallback.
    public var heroes: [SlidingSyncHero]
    /// Opaque activity stamp for client-side room ordering (larger =
    /// more recent). May decrease on redaction; never a timestamp.
    public var bumpStamp: Int?

    public init(
        name: String? = nil,
        avatar: String? = nil,
        initial: Bool = false,
        requiredState: [MessageEvent] = [],
        timeline: [MessageEvent] = [],
        limited: Bool = false,
        prevBatch: String? = nil,
        unreadCount: Int = 0,
        highlightCount: Int = 0,
        heroes: [SlidingSyncHero] = [],
        bumpStamp: Int? = nil
    ) {
        self.name = name
        self.avatar = avatar
        self.initial = initial
        self.requiredState = requiredState
        self.timeline = timeline
        self.limited = limited
        self.prevBatch = prevBatch
        self.unreadCount = unreadCount
        self.highlightCount = highlightCount
        self.heroes = heroes
        self.bumpStamp = bumpStamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        self.initial = try container.decodeIfPresent(Bool.self, forKey: .initial) ?? false
        self.requiredState = try container.decodeIfPresent([MessageEvent].self, forKey: .requiredState) ?? []
        self.timeline = try container.decodeIfPresent([MessageEvent].self, forKey: .timeline) ?? []
        self.limited = try container.decodeIfPresent(Bool.self, forKey: .limited) ?? false
        self.prevBatch = try container.decodeIfPresent(String.self, forKey: .prevBatch)
        let unread = try container.decodeIfPresent(UnreadNotifications.self, forKey: .unreadNotifications)
        self.unreadCount = unread?.notificationCount ?? 0
        self.highlightCount = unread?.highlightCount ?? 0
        self.heroes = try container.decodeIfPresent([SlidingSyncHero].self, forKey: .heroes) ?? []
        self.bumpStamp = try container.decodeIfPresent(Int.self, forKey: .bumpStamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encode(initial, forKey: .initial)
        try container.encode(requiredState, forKey: .requiredState)
        try container.encode(timeline, forKey: .timeline)
        try container.encode(limited, forKey: .limited)
        try container.encodeIfPresent(prevBatch, forKey: .prevBatch)
        try container.encode(
            UnreadNotifications(notificationCount: unreadCount, highlightCount: highlightCount),
            forKey: .unreadNotifications)
        try container.encode(heroes, forKey: .heroes)
        try container.encodeIfPresent(bumpStamp, forKey: .bumpStamp)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case avatar
        case initial
        case requiredState = "required_state"
        case timeline
        case limited
        case prevBatch = "prev_batch"
        case unreadNotifications = "unread_notifications"
        case heroes
        case bumpStamp = "bump_stamp"
    }
}

// MARK: - Parser

/// Converts raw `SlidingSyncResponse` values into `SyncDelta`.
public enum SlidingSyncResponseParser {
    /// Map a decoded sliding sync response onto per-room deltas. Total
    /// function: missing sections decode to empty defaults, never throws.
    /// The `pos` cursor becomes `nextBatch`; note `StateStore.applySliding`
    /// (not `apply`) consumes these deltas so the v2 sync token is untouched.
    /// E2EE/to-device extensions land in `toDevice`/`deviceChanged`/
    /// `deviceLeft` for the shared crypto hooks. The typing extension
    /// (MSC4508) becomes one synthetic `m.typing` ephemeral event per
    /// room, so the existing `RoomActor` ephemeral path handles display.
    public static func parse(_ response: SlidingSyncResponse) -> SyncDelta {
        var joined: [RoomId: JoinedRoomDelta] = [:]
        for (roomIdString, room) in response.rooms {
            let roomId = RoomId(unchecked: roomIdString)
            joined[roomId] = JoinedRoomDelta(
                timeline: room.timeline,
                timelineLimited: room.limited,
                prevBatch: room.prevBatch.map { BatchToken($0) },
                state: room.requiredState,
                unreadCount: room.unreadCount,
                highlightCount: room.highlightCount,
                heroes: room.heroes.map { $0.userId }
            )
        }
        let (toDevice, changed, left) = extensions(in: response.extensions)
        for (roomIdString, userIds) in typing(in: response.extensions) {
            let roomId = RoomId(unchecked: roomIdString)
            var delta = joined[roomId] ?? JoinedRoomDelta()
            delta.ephemeral.append(BasicEvent(
                type: "m.typing",
                content: ["user_ids": .array(userIds.map { .string($0.value) })]))
            joined[roomId] = delta
        }
        return SyncDelta(
            nextBatch: BatchToken(response.pos), joined: joined,
            toDevice: toDevice, deviceChanged: changed, deviceLeft: left)
    }

    /// Parse the E2EE and to-device extensions.
    static func extensions(
        in extensions: [String: AnyCodable]?
    ) -> (toDevice: [BasicEvent], changed: [UserId], left: [UserId]) {
        guard let extensions else { return ([], [], []) }
        var toDevice: [BasicEvent] = []
        if let events = extensions["to_device"]?.objectValue?["events"]?.arrayValue {
            for event in events {
                guard
                    let data = try? JSONEncoder().encode(event),
                    let decoded = try? JSONDecoder().decode(BasicEvent.self, from: data)
                else { continue }
                toDevice.append(decoded)
            }
        }
        func users(_ value: AnyCodable?) -> [UserId] {
            value?.arrayValue?.compactMap {
                $0.stringValue.map(UserId.init(unchecked:))
            } ?? []
        }
        let lists = extensions["e2ee"]?.objectValue?["device_lists"]?.objectValue
        return (toDevice, users(lists?["changed"]), users(lists?["left"]))
    }

    /// Parse the typing extension (MSC4508): room ID to currently
    /// typing users. Latest-state semantics — each entry replaces the
    /// client's previous typing state for that room.
    static func typing(
        in extensions: [String: AnyCodable]?
    ) -> [(roomId: String, userIds: [UserId])] {
        guard
            let rooms = extensions?["typing"]?.objectValue?["rooms"]?.objectValue
        else { return [] }
        return rooms.compactMap { roomId, update in
            guard
                let userIds = update.objectValue?["user_ids"]?.arrayValue?
                    .compactMap({ $0.stringValue.map(UserId.init(unchecked:)) })
            else { return nil }
            return (roomId, userIds)
        }
    }

    /// Advance a to-device cursor from response extensions, if present.
    static func toDeviceBatch(in extensions: [String: AnyCodable]?) -> String? {
        extensions?["to_device"]?.objectValue?["next_batch"]?.stringValue
    }
}
