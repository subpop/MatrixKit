/// Room operation models.

/// `POST /createRoom` request body.
public struct CreateRoomRequest: Hashable, Sendable, Codable {
    /// `public` or `private` directory visibility.
    public var visibility: RoomVisibility?
    /// Local alias to create (without `#`/server suffix).
    public var roomAliasName: String?
    /// Initial room name.
    public var name: String?
    /// Initial room topic.
    public var topic: String?
    /// MXIDs to invite at creation.
    public var invite: [UserId]?
    /// Third-party (email/phone) invites at creation.
    public var invite3pid: [Invite3PID]?
    /// Room version to create (server default when omitted).
    public var roomVersion: String?
    /// Extra `m.room.create` content.
    public var creationContent: [String: AnyCodable]?
    /// State events to set at creation.
    public var initialState: [InitialStateEvent]?
    /// Creation preset (`private_chat`, `public_chat`, `trusted_private_chat`).
    public var preset: RoomPreset?
    /// Mark as a direct-message room.
    public var isDirect: Bool?
    /// Power-level overrides applied at creation.
    public var powerLevelContentOverride: [String: AnyCodable]?

    public init(
        visibility: RoomVisibility? = nil,
        roomAliasName: String? = nil,
        name: String? = nil,
        topic: String? = nil,
        invite: [UserId]? = nil,
        invite3pid: [Invite3PID]? = nil,
        roomVersion: String? = nil,
        creationContent: [String: AnyCodable]? = nil,
        initialState: [InitialStateEvent]? = nil,
        preset: RoomPreset? = nil,
        isDirect: Bool? = nil,
        powerLevelContentOverride: [String: AnyCodable]? = nil
    ) {
        self.visibility = visibility
        self.roomAliasName = roomAliasName
        self.name = name
        self.topic = topic
        self.invite = invite
        self.invite3pid = invite3pid
        self.roomVersion = roomVersion
        self.creationContent = creationContent
        self.initialState = initialState
        self.preset = preset
        self.isDirect = isDirect
        self.powerLevelContentOverride = powerLevelContentOverride
    }

    private enum CodingKeys: String, CodingKey {
        case visibility
        case roomAliasName = "room_alias_name"
        case name
        case topic
        case invite
        case invite3pid = "invite_3pid"
        case roomVersion = "room_version"
        case creationContent = "creation_content"
        case initialState = "initial_state"
        case preset
        case isDirect = "is_direct"
        case powerLevelContentOverride = "power_level_content_override"
    }
}

/// A third-party invite for room creation.
public struct Invite3PID: Hashable, Sendable, Codable {
    /// Identity server hostname.
    public var idServer: String
    /// Access token for the identity server.
    public var idAccessToken: String
    /// Medium (`email`, `msisdn`, …).
    public var medium: String
    /// Address within the medium (email address, phone number, …).
    public var address: String

    public init(idServer: String, idAccessToken: String, medium: String, address: String) {
        self.idServer = idServer
        self.idAccessToken = idAccessToken
        self.medium = medium
        self.address = address
    }

    private enum CodingKeys: String, CodingKey {
        case idServer = "id_server"
        case idAccessToken = "id_access_token"
        case medium
        case address
    }
}

/// An initial state event for room creation.
public struct InitialStateEvent: Hashable, Sendable, Codable {
    /// State event type (e.g. `m.room.name`).
    public var type: String
    /// State key (empty for singleton state).
    public var stateKey: String
    /// Event content.
    public var content: [String: AnyCodable]

    public init(type: String, stateKey: String = "", content: [String: AnyCodable]) {
        self.type = type
        self.stateKey = stateKey
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case stateKey = "state_key"
        case content
    }
}

/// `POST /createRoom` response body.
public struct CreateRoomResponse: Hashable, Sendable, Codable {
    /// ID of the newly created room.
    public var roomId: RoomId

    public init(roomId: RoomId) {
        self.roomId = roomId
    }

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
    }
}

/// `POST /join/{roomIdOrAlias}` request body (empty for plain joins).
public struct JoinRequest: Hashable, Sendable, Codable {
    /// Optional reason shown in the join event.
    public var reason: String?
    /// Third-party invite signature, for 3PID-gated rooms.
    public var thirdPartySigned: ThirdPartySigned?

    public init(reason: String? = nil, thirdPartySigned: ThirdPartySigned? = nil) {
        self.reason = reason
        self.thirdPartySigned = thirdPartySigned
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case thirdPartySigned = "third_party_signed"
    }
}

/// Third-party signed join data.
public struct ThirdPartySigned: Hashable, Sendable, Codable {
    /// Inviter who signed the 3PID invite.
    public var sender: UserId
    /// Invited MXID the token was issued for.
    public var mxid: UserId
    /// The 3PID invite token.
    public var token: String
    /// Server signatures over the token.
    public var signatures: [String: AnyCodable]

    public init(sender: UserId, mxid: UserId, token: String, signatures: [String: AnyCodable]) {
        self.sender = sender
        self.mxid = mxid
        self.token = token
        self.signatures = signatures
    }
}

/// `POST /join/...` response body.
public struct JoinResponse: Hashable, Sendable, Codable {
    /// The joined room's ID (echoes the request, resolved for aliases).
    public var roomId: RoomId

    public init(roomId: RoomId) {
        self.roomId = roomId
    }

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
    }
}

/// `POST /knock/{roomIdOrAlias}` request body.
public struct KnockRequest: Hashable, Sendable, Codable {
    /// Optional reason shown in the knock event.
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

/// `POST /knock/...` response body (same shape as a join response).
public typealias KnockResponse = JoinResponse

/// A generic state event with decoded content.
public struct StateEvent<Content: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    /// State event type.
    public var type: String
    /// State key distinguishing instances of this type.
    public var stateKey: String
    /// Typed event content.
    public var content: Content
    /// Sender, when the server includes it.
    public var sender: UserId?
    /// Event ID, when the server includes it.
    public var eventId: EventId?
    /// Send time in ms, when the server includes it.
    public var originServerTs: Int?

    public init(
        type: String,
        stateKey: String = "",
        content: Content,
        sender: UserId? = nil,
        eventId: EventId? = nil,
        originServerTs: Int? = nil
    ) {
        self.type = type
        self.stateKey = stateKey
        self.content = content
        self.sender = sender
        self.eventId = eventId
        self.originServerTs = originServerTs
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case stateKey = "state_key"
        case content
        case sender
        case eventId = "event_id"
        case originServerTs = "origin_server_ts"
    }
}

/// `m.room.member` content.
public struct MemberContent: Hashable, Sendable, Codable {
    /// Membership state (`join`, `invite`, `leave`, `ban`, `knock`).
    public var membership: Membership
    /// User-set display name, if any.
    public var displayname: String?
    /// Avatar MXC URI, if set.
    public var avatarUrl: String?
    /// Reason for leave/ban, if given.
    public var reason: String?
    /// Set on the invite `m.room.member` event when the room was created
    /// with the `is_direct` flag. Clients may use it to auto-mark the
    /// room as a direct chat in their own `m.direct` account data.
    public var isDirect: Bool?

    public init(
        membership: Membership,
        displayname: String? = nil,
        avatarUrl: String? = nil,
        reason: String? = nil,
        isDirect: Bool? = nil
    ) {
        self.membership = membership
        self.displayname = displayname
        self.avatarUrl = avatarUrl
        self.reason = reason
        self.isDirect = isDirect
    }

    private enum CodingKeys: String, CodingKey {
        case membership
        case displayname
        case avatarUrl = "avatar_url"
        case reason
        case isDirect = "is_direct"
    }
}

/// `m.room.name` content.
public struct RoomNameContent: Hashable, Sendable, Codable {
    /// The room's explicit name.
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// `m.room.topic` content.
public struct RoomTopicContent: Hashable, Sendable, Codable {
    /// The room's topic text.
    public var topic: String

    public init(topic: String) {
        self.topic = topic
    }
}

/// `m.room.avatar` content.
public struct RoomAvatarContent: Hashable, Sendable, Codable {
    /// Avatar MXC URI. Absent when the avatar is removed.
    public var url: String?

    public init(url: String? = nil) {
        self.url = url
    }
}

/// A member entry as returned by `GET /rooms/{roomId}/members`.
public struct MemberInfo: Hashable, Sendable, Codable {
    /// Always `m.room.member`.
    public var type: String
    /// The membership subject's MXID.
    public var stateKey: String
    /// Who sent this membership change.
    public var sender: UserId
    /// Membership details.
    public var content: MemberContent
    /// Event ID, when the server includes it.
    public var eventId: EventId?

    public init(
        type: String = EventType.roomMember.rawValue,
        stateKey: String,
        sender: UserId,
        content: MemberContent,
        eventId: EventId? = nil
    ) {
        self.type = type
        self.stateKey = stateKey
        self.sender = sender
        self.content = content
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case stateKey = "state_key"
        case sender
        case content
        case eventId = "event_id"
    }

    /// The user this membership event is about.
    public var userId: UserId {
        UserId(unchecked: stateKey)
    }
}

/// Aggregated room metadata for UI display.
public struct RoomInfo: Hashable, Sendable {
    /// The room's Matrix ID.
    public var roomId: RoomId
    /// Best-effort display name (explicit name, heroes, or ID fallback).
    public var name: String?
    /// Room topic, if set.
    public var topic: String?
    /// Room avatar, if set.
    public var avatarURL: MXCURI?
    /// Local user's membership.
    public var membership: Membership
    /// Known member count (complete only with full state).
    public var memberCount: Int

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: MXCURI? = nil,
        membership: Membership = .join,
        memberCount: Int = 0
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.membership = membership
        self.memberCount = memberCount
    }
}

/// A public room directory entry (`POST /publicRooms`).
public struct PublicRoomEntry: Hashable, Sendable, Codable {
    /// The room's Matrix ID.
    public var roomId: RoomId
    /// Explicit room name, if set.
    public var name: String?
    /// Room topic, if set.
    public var topic: String?
    /// Canonical alias, if published.
    public var canonicalAlias: String?
    /// Joined member count (for sorting by popularity).
    public var numJoinedMembers: Int
    /// Whether the room history is world-readable.
    public var worldReadable: Bool
    /// Whether guests may join.
    public var guestCanJoin: Bool
    /// Avatar MXC URI, if set.
    public var avatarUrl: String?

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        canonicalAlias: String? = nil,
        numJoinedMembers: Int = 0,
        worldReadable: Bool = false,
        guestCanJoin: Bool = false,
        avatarUrl: String? = nil
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.canonicalAlias = canonicalAlias
        self.numJoinedMembers = numJoinedMembers
        self.worldReadable = worldReadable
        self.guestCanJoin = guestCanJoin
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case name
        case topic
        case canonicalAlias = "canonical_alias"
        case numJoinedMembers = "num_joined_members"
        case worldReadable = "world_readable"
        case guestCanJoin = "guest_can_join"
        case avatarUrl = "avatar_url"
    }
}

/// A public-directory row, ready for display.
public struct DirectoryRoom: Hashable, Sendable, Identifiable {
    /// The room's Matrix ID.
    public var id: RoomId { roomId }
    /// The room's Matrix ID.
    public var roomId: RoomId
    /// Display name, if set.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Canonical alias, if published.
    public var alias: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Joined member count.
    public var memberCount: Int
    /// Whether history is world-readable (preview-before-join works).
    public var isWorldReadable: Bool
    /// Whether the entry is a space. Directory responses carry no room
    /// type, so this is always false here; resolve spaces via hierarchy.
    public var isSpace: Bool

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        alias: String? = nil,
        avatarURL: MXCURI? = nil,
        memberCount: Int = 0,
        isWorldReadable: Bool = false,
        isSpace: Bool = false
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.alias = alias
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.isWorldReadable = isWorldReadable
        self.isSpace = isSpace
    }

    /// Map a directory entry.
    public init(entry: PublicRoomEntry) {
        self.init(
            roomId: entry.roomId,
            name: entry.name,
            topic: entry.topic,
            alias: entry.canonicalAlias,
            avatarURL: entry.avatarUrl.flatMap { try? MXCURI($0) },
            memberCount: entry.numJoinedMembers,
            isWorldReadable: entry.worldReadable)
    }
}

/// A room preview: state plus recent messages for a room the user has
/// not joined. Fetching throws when the room is not world-readable.
public struct RoomPreview: Hashable, Sendable {
    /// The previewed room's ID.
    public var roomId: RoomId
    /// Display name, if known.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Joined member count from state.
    public var memberCount: Int
    /// Canonical alias, if any.
    public var canonicalAlias: String?
    /// Recent messages, newest last.
    public var messages: [MessageEvent]

    public init(
        roomId: RoomId,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: MXCURI? = nil,
        memberCount: Int = 0,
        canonicalAlias: String? = nil,
        messages: [MessageEvent] = []
    ) {
        self.roomId = roomId
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.memberCount = memberCount
        self.canonicalAlias = canonicalAlias
        self.messages = messages
    }
}

/// `POST /publicRooms` response body.
public struct PublicRoomsResponse: Hashable, Sendable, Codable {
    /// This page of directory entries.
    public var chunk: [PublicRoomEntry]
    /// Cursor for the next page, if more rooms match.
    public var nextBatch: String?
    /// Cursor for the previous page.
    public var prevBatch: String?
    /// Estimated total matches (for progress UI).
    public var totalRoomCountEstimate: Int?

    public init(
        chunk: [PublicRoomEntry] = [],
        nextBatch: String? = nil,
        prevBatch: String? = nil,
        totalRoomCountEstimate: Int? = nil
    ) {
        self.chunk = chunk
        self.nextBatch = nextBatch
        self.prevBatch = prevBatch
        self.totalRoomCountEstimate = totalRoomCountEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case chunk
        case nextBatch = "next_batch"
        case prevBatch = "prev_batch"
        case totalRoomCountEstimate = "total_room_count_estimate"
    }
}

/// One tag on a room (spec §room tagging).
public struct RoomTag: Hashable, Sendable, Codable {
    /// Ordering hint in [0, 1); clients sort lowest-first.
    public var order: Double?

    public init(order: Double? = nil) {
        self.order = order
    }
}

/// `GET /user/{userId}/rooms/{roomId}/tags` response body.
public struct TagsResponse: Hashable, Sendable, Codable {
    /// The room's tags keyed by tag name.
    public var tags: [String: RoomTag]

    public init(tags: [String: RoomTag] = [:]) {
        self.tags = tags
    }
}
