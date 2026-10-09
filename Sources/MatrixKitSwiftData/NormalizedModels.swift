#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// Schema version for the normalized store. Mismatches wipe the store
/// (never migrated — a full sync rebuilds it), same policy as the
/// snapshot caches.
public enum NormalizedStoreVersion {
    public static let current = 1
}

/// Single-row store metadata (`id == "meta"`).
@Model
public final class SDStoreMeta {
    @Attribute(.unique) public var id: String
    public var version: Int
    public var syncToken: String?
    /// Sliding-sync `pos` cursor. Separate from the v2 `syncToken` so the
    /// two engines never thrash one cursor.
    public var slidingPos: String?
    public var localUser: String?

    public init(
        version: Int = NormalizedStoreVersion.current,
        syncToken: String? = nil,
        slidingPos: String? = nil,
        localUser: String? = nil
    ) {
        self.id = "meta"
        self.version = version
        self.syncToken = syncToken
        self.slidingPos = slidingPos
        self.localUser = localUser
    }
}

/// A room row. Scalar state lives here as queryable columns; complex
/// nested structs (`powerLevelsContent`, hierarchy rows, heroes) stay
/// JSON blobs until a later pass normalizes them.
@Model
public final class SDRoom {
    @Attribute(.unique) public var roomId: String
    public var name: String?
    public var topic: String?
    public var avatarURL: String?
    /// `Membership.rawValue` (`join`, `invite`, …). String so `#Predicate`
    /// filters stay simple.
    public var membership: String
    public var unread: Int
    public var highlight: Int
    /// Writer-precomputed badge count (`max(server, client estimate)`).
    public var effectiveUnread: Int
    /// Oldest message-like event newer than the read marker, if any.
    public var firstUnreadEventId: String?
    public var prevBatch: String?
    public var fullyRead: String?
    /// Client-side read-marker timestamp (ms since epoch), if known.
    public var readMarkerTs: Int?
    /// Newest event timestamp in the room. Drives room-list sorting
    /// without faulting the event history.
    public var latestMessageTs: Int
    public var isSpace: Bool
    public var isFavourite: Bool
    public var isEncrypted: Bool
    public var isDirect: Bool
    public var canonicalAlias: String?
    public var successorRoomId: String?
    /// Invite sender while `membership == "invite"`.
    public var inviterId: String?
    /// JSON-encoded `[String]`.
    public var altAliases: Data?
    /// JSON-encoded `[String]`.
    public var pinnedEventIds: Data?
    /// JSON-encoded `m.room.power_levels` content.
    public var powerLevelsContent: Data?
    /// JSON-encoded hero user-ID strings.
    public var heroes: Data?
    /// JSON-encoded `[SpaceChild]` (MSC2946 hierarchy rows).
    public var hierarchyChildren: Data?
    /// JSON-encoded `[SpaceChildEdge]` (ordering).
    public var hierarchyDirectChildren: Data?
    public var hierarchyNextBatch: String?

    @Relationship(deleteRule: .cascade, inverse: \SDRoomEvent.room)
    public var events: [SDRoomEvent] = []
    @Relationship(deleteRule: .cascade, inverse: \SDRoomMember.room)
    public var members: [SDRoomMember] = []
    @Relationship(deleteRule: .cascade, inverse: \SDRoomEdge.room)
    public var edges: [SDRoomEdge] = []
    @Relationship(deleteRule: .cascade, inverse: \SDRoomAccountData.room)
    public var roomAccountData: [SDRoomAccountData] = []

    public init(
        roomId: String,
        membership: String,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: String? = nil,
        unread: Int = 0,
        highlight: Int = 0,
        effectiveUnread: Int = 0,
        firstUnreadEventId: String? = nil,
        prevBatch: String? = nil,
        fullyRead: String? = nil,
        readMarkerTs: Int? = nil,
        latestMessageTs: Int = 0,
        isSpace: Bool = false,
        isFavourite: Bool = false,
        isEncrypted: Bool = false,
        isDirect: Bool = false,
        canonicalAlias: String? = nil,
        successorRoomId: String? = nil,
        inviterId: String? = nil
    ) {
        self.roomId = roomId
        self.membership = membership
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.unread = unread
        self.highlight = highlight
        self.effectiveUnread = effectiveUnread
        self.firstUnreadEventId = firstUnreadEventId
        self.prevBatch = prevBatch
        self.fullyRead = fullyRead
        self.readMarkerTs = readMarkerTs
        self.latestMessageTs = latestMessageTs
        self.isSpace = isSpace
        self.isFavourite = isFavourite
        self.isEncrypted = isEncrypted
        self.isDirect = isDirect
        self.canonicalAlias = canonicalAlias
        self.successorRoomId = successorRoomId
        self.inviterId = inviterId
    }
}

/// A membership row. Profile fields are real columns (queryable).
@Model
public final class SDRoomMember {
    /// `"\(roomId)|\(userId)"`. Composite uniqueness via one column.
    @Attribute(.unique) public var key: String
    public var roomId: String
    public var userId: String
    /// `Membership.rawValue`.
    public var membership: String
    public var displayname: String?
    public var avatarUrl: String?
    public var reason: String?
    public var isDirect: Bool?

    public var room: SDRoom?

    public init(
        roomId: String,
        userId: String,
        membership: String,
        displayname: String? = nil,
        avatarUrl: String? = nil,
        reason: String? = nil,
        isDirect: Bool? = nil
    ) {
        self.key = "\(roomId)|\(userId)"
        self.roomId = roomId
        self.userId = userId
        self.membership = membership
        self.displayname = displayname
        self.avatarUrl = avatarUrl
        self.reason = reason
        self.isDirect = isDirect
    }
}

/// A timeline event row. Full history is kept (no window trim); the raw
/// payload stays as JSON while promoted columns serve `@Query` filters.
@Model
public final class SDRoomEvent {
    @Attribute(.unique) public var eventId: String
    public var roomId: String
    public var ts: Int
    public var type: String
    public var sender: String
    public var stateKey: String?
    public var redacts: String?
    public var content: Data
    public var unsigned: Data?
    /// True when `stateKey != nil`.
    public var isState: Bool
    /// Message or sticker, for list previews and unread estimates.
    public var isMessageLike: Bool
    /// `m.relates_to.rel_type` (`m.replace`, `m.annotation`, …), if any.
    public var relType: String?
    /// Thread root event ID, if threaded.
    public var threadRootId: String?
    /// Echo delivery state: `"pending"` / `"failed"`, nil when confirmed.
    public var sendState: String?
    public var sendFailureReason: String?

    public var room: SDRoom?

    public init(
        roomId: String,
        eventId: String,
        ts: Int,
        type: String,
        sender: String,
        stateKey: String? = nil,
        redacts: String? = nil,
        content: Data = Data(),
        unsigned: Data? = nil,
        isState: Bool = false,
        isMessageLike: Bool = false,
        relType: String? = nil,
        threadRootId: String? = nil,
        sendState: String? = nil,
        sendFailureReason: String? = nil
    ) {
        self.roomId = roomId
        self.eventId = eventId
        self.ts = ts
        self.type = type
        self.sender = sender
        self.stateKey = stateKey
        self.redacts = redacts
        self.content = content
        self.unsigned = unsigned
        self.isState = isState
        self.isMessageLike = isMessageLike
        self.relType = relType
        self.threadRootId = threadRootId
        self.sendState = sendState
        self.sendFailureReason = sendFailureReason
    }
}

/// Space-graph edge kind, stored as `SDRoomEdge.kind`.
public enum SDEdgeKind: String, Sendable, CaseIterable {
    /// `owner` lists `peer` via `m.space.child`.
    case child
    /// `owner` lists `peer` via `m.space.parent`.
    case parent
    /// Canonical `m.space.parent` (`canonical: true`).
    case canonicalParent
}

/// A space-graph edge row, replacing the three JSON array blobs.
@Model
public final class SDRoomEdge {
    /// `"\(ownerRoomId)|\(kind)|\(peerRoomId)"`.
    @Attribute(.unique) public var key: String
    public var ownerRoomId: String
    public var peerRoomId: String
    /// `SDEdgeKind.rawValue`.
    public var kind: String

    public var room: SDRoom?

    public init(ownerRoomId: String, peerRoomId: String, kind: SDEdgeKind) {
        self.key = "\(ownerRoomId)|\(kind.rawValue)|\(peerRoomId)"
        self.ownerRoomId = ownerRoomId
        self.peerRoomId = peerRoomId
        self.kind = kind.rawValue
    }
}

/// Top-level account-data entry (one row per type, JSON content).
@Model
public final class SDAccountData {
    @Attribute(.unique) public var type: String
    public var content: Data

    public init(type: String, content: Data) {
        self.type = type
        self.content = content
    }
}

/// Room-scoped account-data entry. Hierarchy cache rows live here rather
/// than on the room row.
@Model
public final class SDRoomAccountData {
    /// `"\(roomId)|\(type)"`.
    @Attribute(.unique) public var key: String
    public var roomId: String
    public var type: String
    public var content: Data

    public var room: SDRoom?

    public init(roomId: String, type: String, content: Data) {
        self.key = "\(roomId)|\(type)"
        self.roomId = roomId
        self.type = type
        self.content = content
    }
}

// MARK: - Typed reads

/// Decoded accessors over the JSON-blob columns, so consumers never
/// hand-decode row payloads. Lenient: corrupt blobs read as empty.
public extension SDRoomEvent {
    /// Decode this row to a `MessageEvent`, or nil when the stored
    /// payload no longer decodes.
    func messageEvent(decoder: JSONDecoder = JSONDecoder()) -> MessageEvent? {
        guard
            let content = try? decoder.decode(
                [String: AnyCodable].self, from: content)
        else { return nil }
        let unsigned = try? unsigned.map {
            try decoder.decode([String: AnyCodable].self, from: $0)
        }
        return MessageEvent(
            type: type,
            eventId: EventId(unchecked: eventId),
            sender: UserId(unchecked: sender),
            roomId: RoomId(unchecked: roomId),
            stateKey: stateKey,
            redacts: redacts.map(EventId.init(unchecked:)),
            originServerTs: ts,
            content: content,
            unsigned: unsigned)
    }
}

/// Space-graph direction helpers over edge rows. `m.space.child` lives
/// in the parent's state (owner = parent, peer = child);
/// `m.space.parent` lives in the child's state (owner = child,
/// peer = parent). IDs stay strings (storage-faithful, no invented
/// validation); callers wrap in `RoomId` as needed.
public extension SDRoomEdge {
    /// Parent space IDs of a room: `.child` owners plus `.parent` peers.
    static func parents(of roomId: String, in edges: [SDRoomEdge]) -> Set<String> {
        var out = Set<String>()
        for edge in edges {
            if edge.kind == SDEdgeKind.child.rawValue, edge.peerRoomId == roomId {
                out.insert(edge.ownerRoomId)
            } else if edge.kind == SDEdgeKind.parent.rawValue
                || edge.kind == SDEdgeKind.canonicalParent.rawValue,
                edge.ownerRoomId == roomId
            {
                out.insert(edge.peerRoomId)
            }
        }
        return out
    }

    /// Direct child IDs of an owner: `.child` peers plus `.parent`
    /// owners. Inverse of `parents(of:in:)`.
    static func children(of ownerId: String, in edges: [SDRoomEdge]) -> Set<String> {
        var out = Set<String>()
        for edge in edges {
            if edge.kind == SDEdgeKind.child.rawValue, edge.ownerRoomId == ownerId {
                out.insert(edge.peerRoomId)
            } else if edge.kind == SDEdgeKind.parent.rawValue
                || edge.kind == SDEdgeKind.canonicalParent.rawValue,
                edge.peerRoomId == ownerId
            {
                out.insert(edge.ownerRoomId)
            }
        }
        return out
    }

    /// Every ID contained in a space, transitively. Cycle-safe BFS over
    /// `children(of:in:)`; the space itself is excluded.
    static func descendants(of spaceId: String, in edges: [SDRoomEdge]) -> Set<String> {
        var seen: Set<String> = [spaceId]
        var queue = [spaceId]
        var out = Set<String>()
        while let current = queue.popLast() {
            for child in children(of: current, in: edges)
            where seen.insert(child).inserted {
                out.insert(child)
                queue.append(child)
            }
        }
        return out
    }
}

/// Decoded accessors over the room row's JSON-blob columns.
public extension SDRoom {
    /// Fetched space-hierarchy rows, or empty when never opened (or the
    /// blob no longer decodes).
    func decodedHierarchyChildren(decoder: JSONDecoder = JSONDecoder()) -> [SpaceChild] {
        guard let data = hierarchyChildren else { return [] }
        return (try? decoder.decode([SpaceChild].self, from: data)) ?? []
    }

    /// Direct-child edges of the fetched hierarchy level, or empty.
    func decodedHierarchyDirectChildren(
        decoder: JSONDecoder = JSONDecoder()
    ) -> [SpaceChildEdge] {
        guard let data = hierarchyDirectChildren else { return [] }
        return (try? decoder.decode([SpaceChildEdge].self, from: data)) ?? []
    }

    /// Pinned event IDs, or empty.
    func decodedPinnedEventIds(decoder: JSONDecoder = JSONDecoder()) -> [String] {
        guard let data = pinnedEventIds else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    /// Alternative aliases, or empty.
    func decodedAltAliases(decoder: JSONDecoder = JSONDecoder()) -> [String] {
        guard let data = altAliases else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }
}
#endif
