/// Room membership operations: create, join, leave, invite, moderation.
public actor RoomClient {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Lifecycle

    /// Create a room (`POST /createRoom`).
    public func create(_ request: CreateRoomRequest) async throws(MatrixError) -> RoomId {
        let response: CreateRoomResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/createRoom",
            body: request, accessToken: try await token()
        )
        return response.roomId
    }

    /// Join by room ID (`POST /join/{roomId}`).
    public func join(_ roomId: RoomId, reason: String? = nil) async throws(MatrixError) {
        let _: JoinResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/join/\(roomId.pathSegmentEncoded)",
            body: JoinRequest(reason: reason), accessToken: try await token()
        )
    }

    /// Join by alias (`POST /join/{alias}`).
    public func join(_ alias: RoomAlias, reason: String? = nil) async throws(MatrixError) {
        let _: JoinResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/join/\(alias.pathSegmentEncoded)",
            body: JoinRequest(reason: reason), accessToken: try await token()
        )
    }

    /// Knock on a room by ID (`POST /knock/{roomId}`). Returns the
    /// server-resolved room ID.
    public func knock(_ roomId: RoomId, reason: String? = nil) async throws(MatrixError) -> RoomId {
        let response: KnockResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/knock/\(roomId.pathSegmentEncoded)",
            body: KnockRequest(reason: reason), accessToken: try await token()
        )
        return response.roomId
    }

    /// Knock on a room by alias (`POST /knock/{alias}`). Returns the
    /// server-resolved room ID.
    public func knock(_ alias: RoomAlias, reason: String? = nil) async throws(MatrixError) -> RoomId {
        let response: KnockResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/knock/\(alias.pathSegmentEncoded)",
            body: KnockRequest(reason: reason), accessToken: try await token()
        )
        return response.roomId
    }

    /// Leave a room (`POST /rooms/{roomId}/leave`).
    public func leave(_ roomId: RoomId, reason: String? = nil) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/leave",
            body: LeaveRequest(reason: reason), accessToken: try await token()
        )
    }

    /// Forget a room (`POST /rooms/{roomId}/forget`).
    public func forget(_ roomId: RoomId) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/forget",
            accessToken: try await token()
        )
    }

    /// Upgrade a room (`POST /rooms/{roomId}/upgrade`). Returns the
    /// replacement room's ID; the tombstone arrives via the next sync.
    public func upgrade(
        _ roomId: RoomId, newVersion: String
    ) async throws(MatrixError) -> RoomId {
        let response: UpgradeRoomResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/upgrade",
            body: ["new_version": newVersion],
            accessToken: try await token()
        )
        return response.replacementRoom
    }

    // MARK: - Membership management

    /// Invite a user (`POST /rooms/{roomId}/invite`).
    public func invite(_ roomId: RoomId, user: UserId, reason: String? = nil) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/invite",
            body: MembershipAction(userId: user, reason: reason),
            accessToken: try await token()
        )
    }

    /// Kick a user (`POST /rooms/{roomId}/kick`).
    public func kick(_ roomId: RoomId, user: UserId, reason: String? = nil) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/kick",
            body: MembershipAction(userId: user, reason: reason),
            accessToken: try await token()
        )
    }

    /// Ban a user (`POST /rooms/{roomId}/ban`).
    public func ban(_ roomId: RoomId, user: UserId, reason: String? = nil) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/ban",
            body: MembershipAction(userId: user, reason: reason),
            accessToken: try await token()
        )
    }

    /// Unban a user (`POST /rooms/{roomId}/unban`).
    public func unban(_ roomId: RoomId, user: UserId) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/unban",
            body: MembershipAction(userId: user),
            accessToken: try await token()
        )
    }

    /// Report an event's content (`POST /rooms/{roomId}/report/{eventId}`).
    /// `score` is a severity hint in -100 (most offensive) to 0.
    public func report(
        _ eventId: EventId, in roomId: RoomId,
        score: Int? = nil, reason: String? = nil
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/report/\(eventId.pathSegmentEncoded)",
            body: ReportRequest(score: score, reason: reason),
            accessToken: try await token()
        )
    }

    // MARK: - Members

    /// Full member list (`GET /rooms/{roomId}/members`).
    public func members(_ roomId: RoomId) async throws(MatrixError) -> [MemberInfo] {
        let response: MembersResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/members",
            accessToken: try await token()
        )
        return response.chunk
    }

    /// Joined members with display names (`GET /rooms/{roomId}/joined_members`).
    public func joinedMembers(_ roomId: RoomId) async throws(MatrixError) -> [UserId: JoinedMember] {
        let response: JoinedMembersResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/joined_members",
            accessToken: try await token()
        )
        var result: [UserId: JoinedMember] = [:]
        for (key, value) in response.joined {
            result[UserId(unchecked: key)] = value
        }
        return result
    }

    // MARK: - Directory

    /// Public room directory (`POST /publicRooms`).
    public func publicRooms(
        limit: Int? = nil,
        since: String? = nil,
        server: String? = nil,
        filter: String? = nil
    ) async throws(MatrixError) -> PublicRoomsResponse {
        try await transport.send(
            .post, path: "/_matrix/client/v3/publicRooms",
            body: PublicRoomsRequest(
                limit: limit, since: since, server: server,
                filter: filter.map(PublicRoomsFilter.init(genericSearchTerm:))),
            accessToken: try await token()
        )
    }

    /// Search the public directory, mapping entries to display rows.
    /// `query` filters server-side (`generic_search_term`).
    public func searchDirectory(
        query: String?, server: String? = nil, limit: Int = 100, since: String? = nil
    ) async throws(MatrixError) -> (rooms: [DirectoryRoom], nextBatch: String?) {
        let response = try await publicRooms(
            limit: limit, since: since, server: server, filter: query)
        return (
            response.chunk.map(DirectoryRoom.init(entry:)),
            response.nextBatch)
    }

    /// Paginate the public directory (`GET /publicRooms`). The GET variant
    /// takes pagination as query parameters; use the POST variant for
    /// server-side text filtering.
    public func publicRoomsGet(
        limit: Int? = nil, since: String? = nil, server: String? = nil
    ) async throws(MatrixError) -> PublicRoomsResponse {
        var query: [String: String] = [:]
        if let limit { query["limit"] = "\(limit)" }
        if let since { query["since"] = since }
        if let server { query["server"] = server }
        return try await transport.send(
            .get, path: "/_matrix/client/v3/publicRooms",
            query: query.isEmpty ? nil : query,
            accessToken: try await token()
        )
    }

    // MARK: - Aliases

    /// Local aliases published for a room (`GET /rooms/{roomId}/aliases`).
    public func aliases(_ roomId: RoomId) async throws(MatrixError) -> [String] {
        let response: RoomAliasesResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/aliases",
            accessToken: try await token()
        )
        return response.aliases
    }

    /// Room visibility in the public directory
    /// (`GET /directory/list/room/{roomId}`).
    public func roomVisibility(_ roomId: RoomId) async throws(MatrixError) -> RoomVisibility {
        let response: RoomVisibilityResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/directory/list/room/\(roomId.pathSegmentEncoded)",
            accessToken: try await token()
        )
        return response.visibility
    }

    /// Publish or hide a room in the public directory
    /// (`PUT /directory/list/room/{roomId}`).
    public func setRoomVisibility(
        _ roomId: RoomId, visibility: RoomVisibility
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/directory/list/room/\(roomId.pathSegmentEncoded)",
            body: ["visibility": visibility],
            accessToken: try await token()
        )
    }

    /// Publish a room alias (`PUT /directory/room/{alias}`).
    public func publishAlias(
        _ alias: RoomAlias, roomId: RoomId
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/directory/room/\(alias.value.pathSegmentEncoded)",
            body: ["room_id": roomId.value],
            accessToken: try await token()
        )
    }

    /// Remove a room alias (`DELETE /directory/room/{alias}`).
    public func removeAlias(_ alias: RoomAlias) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .delete,
            path: "/_matrix/client/v3/directory/room/\(alias.value.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Resolve an alias to its room (`GET /directory/room/{alias}`).
    public func resolveAlias(_ alias: RoomAlias) async throws(MatrixError) -> AliasResolution {
        try await transport.send(
            .get,
            path: "/_matrix/client/v3/directory/room/\(alias.value.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Whether an alias is free (`M_NOT_FOUND` on resolve).
    public func isAliasAvailable(_ alias: RoomAlias) async throws(MatrixError) -> Bool {
        do {
            _ = try await resolveAlias(alias)
            return false
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            return true
        }
    }

    /// Set the canonical alias and alternatives (`m.room.canonical_alias`).
    public func setCanonicalAlias(
        roomId: RoomId, alias: RoomAlias?, altAliases: [RoomAlias] = []
    ) async throws(MatrixError) {
        var content: [String: AnyCodable] = [
            "alt_aliases": .array(altAliases.map { .string($0.value) }),
        ]
        if let alias {
            content["alias"] = .string(alias.value)
        }
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/state/m.room.canonical_alias/",
            body: AnyCodableDictionary(content),
            accessToken: try await token()
        )
    }

    // MARK: - Preview

    /// Preview a room before joining: state plus recent messages.
    /// Throws when the room is not world-readable.
    public func preview(
        _ roomId: RoomId, messageLimit: Int = 20
    ) async throws(MatrixError) -> RoomPreview {
        let state: StateResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/state",
            accessToken: try await token()
        )
        var name: String?
        var topic: String?
        var avatarURL: MXCURI?
        var canonicalAlias: String?
        var memberCount = 0
        for event in state.events {
            switch event.type {
            case "m.room.name":
                name = event.content["name"]?.stringValue
            case "m.room.topic":
                topic = event.content["topic"]?.stringValue
            case "m.room.avatar":
                avatarURL = event.content["url"]?.stringValue.flatMap { try? MXCURI($0) }
            case "m.room.canonical_alias":
                canonicalAlias = event.content["alias"]?.stringValue
            case "m.room.member"
            where event.content["membership"]?.stringValue == Membership.join.rawValue:
                memberCount += 1
            default:
                break
            }
        }
        // `from` omitted: servers page from the latest edge.
        let peek: MessagesResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/messages",
            query: ["limit": "\(messageLimit)", "dir": "b"],
            accessToken: try await token()
        )
        return RoomPreview(
            roomId: roomId,
            name: name,
            topic: topic,
            avatarURL: avatarURL,
            memberCount: memberCount,
            canonicalAlias: canonicalAlias,
            messages: Array(peek.chunk.reversed()))
    }
}

/// `GET /directory/room/{alias}` response body.
public struct AliasResolution: Hashable, Sendable, Codable {
    /// The room the alias points to.
    public var roomId: RoomId
    /// Servers likely to be in the room (join candidates).
    public var servers: [String]

    public init(roomId: RoomId, servers: [String] = []) {
        self.roomId = roomId
        self.servers = servers
    }

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case servers
    }
}

/// `POST /rooms/{roomId}/leave` body.
public struct LeaveRequest: Hashable, Sendable, Codable {
    /// Optional reason shown in the leave event.
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

/// Shared body for invite/kick/ban/unban.
public struct MembershipAction: Hashable, Sendable, Codable {
    /// Target user's MXID.
    public var userId: UserId
    /// Optional reason shown in the membership event.
    public var reason: String?

    public init(userId: UserId, reason: String? = nil) {
        self.userId = userId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case reason
    }
}

/// `GET /rooms/{roomId}/members` response.
public struct MembersResponse: Hashable, Sendable, Codable {
    /// Member events in the room.
    public var chunk: [MemberInfo]

    public init(chunk: [MemberInfo] = []) {
        self.chunk = chunk
    }
}

/// A joined member entry with profile details.
public struct JoinedMember: Hashable, Sendable, Codable {
    /// Current display name, if set.
    public var displayName: String?
    /// Avatar MXC URI, if set.
    public var avatarUrl: String?

    public init(displayName: String? = nil, avatarUrl: String? = nil) {
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

/// `GET /rooms/{roomId}/joined_members` response.
public struct JoinedMembersResponse: Hashable, Sendable, Codable {
    /// Joined members keyed by MXID string.
    public var joined: [String: JoinedMember]

    public init(joined: [String: JoinedMember] = [:]) {
        self.joined = joined
    }
}

/// `POST /publicRooms` request body.
public struct PublicRoomsRequest: Hashable, Sendable, Codable {
    /// Max entries per page.
    public var limit: Int?
    /// Pagination cursor from a previous response.
    public var since: String?
    /// Only rooms published by this server.
    public var server: String?
    /// Server-side text filter.
    public var filter: PublicRoomsFilter?

    public init(
        limit: Int? = nil, since: String? = nil, server: String? = nil,
        filter: PublicRoomsFilter? = nil
    ) {
        self.limit = limit
        self.since = since
        self.server = server
        self.filter = filter
    }
}

/// `POST /publicRooms` text filter (MSC3827, stable).
public struct PublicRoomsFilter: Hashable, Sendable, Codable {
    /// Server-side generic search term (name, topic, alias, …).
    public var genericSearchTerm: String

    public init(genericSearchTerm: String) {
        self.genericSearchTerm = genericSearchTerm
    }

    private enum CodingKeys: String, CodingKey {
        case genericSearchTerm = "generic_search_term"
    }
}

/// `GET /rooms/{roomId}/aliases` response body.
public struct RoomAliasesResponse: Hashable, Sendable, Codable {
    /// Local aliases published for the room.
    public var aliases: [String]

    public init(aliases: [String] = []) {
        self.aliases = aliases
    }
}

/// `GET /directory/list/room/{roomId}` response body.
public struct RoomVisibilityResponse: Hashable, Sendable, Codable {
    /// Whether the room is published in the public directory.
    public var visibility: RoomVisibility

    public init(visibility: RoomVisibility) {
        self.visibility = visibility
    }
}

/// `POST /rooms/{roomId}/upgrade` response body.
public struct UpgradeRoomResponse: Hashable, Sendable, Codable {
    /// The replacement room's ID.
    public var replacementRoom: RoomId

    public init(replacementRoom: RoomId) {
        self.replacementRoom = replacementRoom
    }

    private enum CodingKeys: String, CodingKey {
        case replacementRoom = "replacement_room"
    }
}

/// `POST /rooms/{roomId}/report/{eventId}` request body.
public struct ReportRequest: Hashable, Sendable, Codable {
    /// Severity hint, -100 (most offensive) to 0.
    public var score: Int?
    /// Human-readable reason for the report.
    public var reason: String?

    public init(score: Int? = nil, reason: String? = nil) {
        self.score = score
        self.reason = reason
    }
}
