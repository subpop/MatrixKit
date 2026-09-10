/// Space models: hierarchy rows and `m.space.child` content.
import Foundation

/// Whether a space child is a plain room or a sub-space.
public enum SpaceChildType: String, Hashable, Sendable, Codable {
    /// A regular room.
    case room
    /// A sub-space (`room_type` is `m.space`).
    case space
}

/// Join rule of a space child, as reported by the hierarchy API.
public enum SpaceChildJoinRule: String, Hashable, Sendable, Codable {
    /// Anyone can join.
    case `public`
    /// Join requests go through knocking.
    case knock
    /// Invite only.
    case invite
    /// Restricted (e.g. space members or allow-listed rooms).
    case restricted
    /// Restricted with knocking allowed (rooms can be knocked on to
    /// request an invite from an allowed user).
    case knockRestricted = "knock_restricted"

    /// Map a wire join-rule string, or nil when unrecognized.
    public static func parse(_ raw: String?) -> SpaceChildJoinRule? {
        switch raw {
        case "public": .public
        case "knock": .knock
        case "invite": .invite
        case "restricted": .restricted
        case "knock_restricted": .knockRestricted
        default: nil
        }
    }
}

/// One row of a space hierarchy: a child room or sub-space.
public struct SpaceChild: Hashable, Sendable, Codable, Identifiable {
    /// The child's room ID.
    public var id: RoomId { roomId }
    /// The child's room ID.
    public var roomId: RoomId
    /// Display name, if known.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Joined member count reported by the server.
    public var memberCount: Int
    /// Room or sub-space.
    public var roomType: SpaceChildType
    /// Whether the local user has joined the child.
    public var isJoined: Bool
    /// Number of children (sub-spaces only).
    public var childrenCount: Int
    /// Join rule, if recognized.
    public var joinRule: SpaceChildJoinRule?
    /// Whether the child accepts knocks (`knock` or `knock_restricted`).
    public var isKnockable: Bool {
        joinRule == .knock || joinRule == .knockRestricted
    }
    /// Canonical alias, if any.
    public var canonicalAlias: String?
    /// Direct child room IDs from this entry's `children_state`. Lets
    /// callers rebuild levels and recursive counts without refetching.
    public var childIds: [RoomId]
    /// Whether the room may be viewed without joining.
    public var worldReadable: Bool?
    /// Whether guest users may join and participate.
    public var guestCanJoin: Bool?
    /// Room IDs allowed by restricted join rules, if any.
    public var allowedRoomIds: [RoomId]
    /// The room version.
    public var roomVersion: String?
    /// The encryption algorithm, if the room is encrypted.
    public var encryption: String?
    /// Child edges from this entry's `children_state`, for direct ordering.
    public var childEdges: [SpaceChildEdge]

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: MXCURI? = nil,
        memberCount: Int = 0,
        roomType: SpaceChildType = .room,
        isJoined: Bool = false,
        childrenCount: Int = 0,
        joinRule: SpaceChildJoinRule? = nil,
        canonicalAlias: String? = nil,
        childIds: [RoomId] = [],
        worldReadable: Bool? = nil,
        guestCanJoin: Bool? = nil,
        allowedRoomIds: [RoomId] = [],
        roomVersion: String? = nil,
        encryption: String? = nil,
        childEdges: [SpaceChildEdge] = []
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.roomType = roomType
        self.isJoined = isJoined
        self.childrenCount = childrenCount
        self.joinRule = joinRule
        self.canonicalAlias = canonicalAlias
        self.childIds = childIds
        self.worldReadable = worldReadable
        self.guestCanJoin = guestCanJoin
        self.allowedRoomIds = allowedRoomIds
        self.roomVersion = roomVersion
        self.encryption = encryption
        self.childEdges = childEdges
    }
}

/// A space the local user can add children to.
public struct EditableSpace: Hashable, Sendable, Identifiable {
    /// The space's room ID.
    public var id: RoomId { roomId }
    /// The space's room ID.
    public var roomId: RoomId
    /// Display name, if known.
    public var name: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?

    public init(roomId: RoomId, name: String? = nil, avatarURL: MXCURI? = nil) {
        self.roomId = roomId
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// A joined child listed while leaving a space.
public struct LeaveSpaceChild: Hashable, Sendable, Identifiable {
    /// The child's room ID.
    public var id: RoomId { roomId }
    /// The child's room ID.
    public var roomId: RoomId
    /// Display name, if known.
    public var name: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Whether leaving would leave the room ownerless.
    public var isLastOwner: Bool
    /// Joined member count.
    public var memberCount: Int
    /// Whether the child is a sub-space.
    public var isSpace: Bool

    public init(
        roomId: RoomId,
        name: String? = nil,
        avatarURL: MXCURI? = nil,
        isLastOwner: Bool = false,
        memberCount: Int = 0,
        isSpace: Bool = false
    ) {
        self.roomId = roomId
        self.name = name
        self.avatarURL = avatarURL
        self.isLastOwner = isLastOwner
        self.memberCount = memberCount
        self.isSpace = isSpace
    }
}

/// `m.space.child` state content.
public struct SpaceChildContent: Hashable, Sendable, Codable {
    /// Servers that can route joins into the child.
    public var via: [String]
    /// Ordering hint within the parent, if set.
    public var order: String?
    /// Whether the parent suggests (but doesn't require) this child.
    public var suggested: Bool?

    public init(via: [String] = [], order: String? = nil, suggested: Bool? = nil) {
        self.via = via
        self.order = order
        self.suggested = suggested
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        via = try container.decodeIfPresent([String].self, forKey: .via) ?? []
        order = try container.decodeIfPresent(String.self, forKey: .order)
        suggested = try container.decodeIfPresent(Bool.self, forKey: .suggested)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(via, forKey: .via)
        try container.encodeIfPresent(order, forKey: .order)
        try container.encodeIfPresent(suggested, forKey: .suggested)
    }

    private enum CodingKeys: String, CodingKey {
        case via
        case order
        case suggested
    }

    /// The `order` value when it is valid per the spec (ASCII `\x20`-`\x7E`,
    /// at most 50 characters); nil otherwise. Invalid orders are treated as
    /// though the key were absent.
    public var validOrder: String? {
        guard
            let order,
            order.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }),
            order.count <= 50
        else { return nil }
        return order
    }
}

/// One child relationship inside a space's `children_state`: the edge the
/// space declares to a direct child.
public struct SpaceChildEdge: Hashable, Sendable, Codable {
    /// The child's room ID (state key).
    public var roomId: RoomId
    /// Ordering hint, when the content carries a valid one.
    public var order: String?
    /// Servers that can route joins into the child.
    public var via: [String]
    /// Whether the parent suggests the child.
    public var suggested: Bool
    /// Timestamp of the `m.space.child` event, when reported.
    public var originServerTs: Int?

    public init(
        roomId: RoomId,
        order: String? = nil,
        via: [String] = [],
        suggested: Bool = false,
        originServerTs: Int? = nil
    ) {
        self.roomId = roomId
        self.order = order
        self.via = via
        self.suggested = suggested
        self.originServerTs = originServerTs
    }
}

/// One room of an MSC2946 hierarchy page.
public struct HierarchyRoom: Hashable, Sendable, Codable {
    /// The room's ID.
    public var roomId: RoomId
    /// Room type (`m.space` for sub-spaces).
    public var roomType: String?
    /// Display name, if known.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: String?
    /// Canonical alias, if any.
    public var canonicalAlias: String?
    /// Join rule string, if reported.
    public var joinRule: String?
    /// Joined member count.
    public var memberCount: Int?
    /// This room's children (sub-spaces report theirs).
    public var childrenState: [SpaceChildState]?
    /// Whether the room may be viewed without joining.
    public var worldReadable: Bool?
    /// Whether guest users may join and participate.
    public var guestCanJoin: Bool?
    /// Restrictive join rules' allow-listed rooms, if any.
    public var allowedRoomIds: [RoomId]?
    /// The room version.
    public var roomVersion: String?
    /// The encryption algorithm, if the room is encrypted.
    public var encryption: String?

    public init(
        roomId: RoomId,
        roomType: String? = nil,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: String? = nil,
        canonicalAlias: String? = nil,
        joinRule: String? = nil,
        memberCount: Int? = nil,
        childrenState: [SpaceChildState]? = nil,
        worldReadable: Bool? = nil,
        guestCanJoin: Bool? = nil,
        allowedRoomIds: [RoomId]? = nil,
        roomVersion: String? = nil,
        encryption: String? = nil
    ) {
        self.roomId = roomId
        self.roomType = roomType
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.canonicalAlias = canonicalAlias
        self.joinRule = joinRule
        self.memberCount = memberCount
        self.childrenState = childrenState
        self.worldReadable = worldReadable
        self.guestCanJoin = guestCanJoin
        self.allowedRoomIds = allowedRoomIds
        self.roomVersion = roomVersion
        self.encryption = encryption
    }

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case roomType = "room_type"
        case name
        case topic
        case avatarURL = "avatar_url"
        case canonicalAlias = "canonical_alias"
        case joinRule = "join_rule"
        case memberCount = "num_joined_members"
        case childrenState = "children_state"
        case worldReadable = "world_readable"
        case guestCanJoin = "guest_can_join"
        case allowedRoomIds = "allowed_room_ids"
        case roomVersion = "room_version"
        case encryption
    }
}

/// An `m.space.child` edge inside a hierarchy page.
public struct SpaceChildState: Hashable, Sendable, Codable {
    /// The child's room ID (state key).
    public var stateKey: String
    /// Edge content (servers, ordering).
    public var content: SpaceChildContent
    /// Timestamp of the child event.
    public var originServerTs: Int?
    /// Sender of the child event.
    public var sender: UserId?
    /// Event type (`m.space.child`).
    public var type: String?

    public init(
        stateKey: String,
        content: SpaceChildContent,
        originServerTs: Int? = nil,
        sender: UserId? = nil,
        type: String? = nil
    ) {
        self.stateKey = stateKey
        self.content = content
        self.originServerTs = originServerTs
        self.sender = sender
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case stateKey = "state_key"
        case content
        case originServerTs = "origin_server_ts"
        case sender
        case type
    }
}

/// Order two room IDs by Unicode code points (the spec's tiebreak and
/// canonical-parent rule). Internal: used by ordering and canonical logic.
func codePointLessThan(_ a: String, _ b: String) -> Bool {
    let aScalars = Array(a.unicodeScalars)
    let bScalars = Array(b.unicodeScalars)
    for (x, y) in zip(aScalars, bScalars) {
        if x != y { return x.value < y.value }
    }
    return aScalars.count < bScalars.count
}

/// MSC2946 hierarchy response (`GET /rooms/{roomId}/hierarchy`).
public struct HierarchyResponse: Hashable, Sendable, Codable {
    /// Pagination token for the next page, if more rooms exist.
    public var nextBatch: String?
    /// Rooms in this page (flattened hierarchy).
    public var rooms: [HierarchyRoom]

    public init(nextBatch: String? = nil, rooms: [HierarchyRoom] = []) {
        self.nextBatch = nextBatch
        self.rooms = rooms
    }

    private enum CodingKeys: String, CodingKey {
        case nextBatch = "next_batch"
        case rooms
    }
}
