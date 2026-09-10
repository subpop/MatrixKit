/// User profiles: display names and avatars.
public actor ProfileClient {
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

    /// Full profile (`GET /profile/{userId}`).
    public func getProfile(_ userId: UserId) async throws(MatrixError) -> UserProfile {
        try await transport.send(
            .get, path: "/_matrix/client/v3/profile/\(userId.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Display name (`GET /profile/{userId}/displayname`).
    public func getDisplayName(_ userId: UserId) async throws(MatrixError) -> String? {
        let response: DisplayNameResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/profile/\(userId.pathSegmentEncoded)/displayname",
            accessToken: try await token()
        )
        return response.displayname
    }

    /// Set own display name (`PUT /profile/{userId}/displayname`).
    public func setDisplayName(_ userId: UserId, name: String) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put, path: "/_matrix/client/v3/profile/\(userId.pathSegmentEncoded)/displayname",
            body: DisplayNameResponse(displayname: name),
            accessToken: try await token()
        )
    }

    /// Avatar URL (`GET /profile/{userId}/avatar_url`).
    public func getAvatarURL(_ userId: UserId) async throws(MatrixError) -> MXCURI? {
        let response: AvatarURLResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/profile/\(userId.pathSegmentEncoded)/avatar_url",
            accessToken: try await token()
        )
        return response.avatarUrl.flatMap { try? MXCURI($0) }
    }

    /// Set own avatar (`PUT /profile/{userId}/avatar_url`).
    public func setAvatarURL(_ userId: UserId, url: MXCURI) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put, path: "/_matrix/client/v3/profile/\(userId.pathSegmentEncoded)/avatar_url",
            body: AvatarURLResponse(avatarUrl: url.value),
            accessToken: try await token()
        )
    }

    // MARK: - Presence

    /// Presence status (`GET /presence/{userId}/status`).
    public func presence(_ userId: UserId) async throws(MatrixError) -> UserPresence {
        try await transport.send(
            .get, path: "/_matrix/client/v3/presence/\(userId.pathSegmentEncoded)/status",
            accessToken: try await token()
        )
    }

    /// Set own presence (`PUT /presence/{userId}/status`).
    public func setPresence(
        _ userId: UserId, presence: Presence, statusMessage: String? = nil
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put, path: "/_matrix/client/v3/presence/\(userId.pathSegmentEncoded)/status",
            body: SetPresenceRequest(presence: presence, statusMessage: statusMessage),
            accessToken: try await token()
        )
    }

    // MARK: - User directory

    /// Search the user directory (`POST /user_directory/search`).
    public func searchUsers(
        query: String, limit: Int? = nil
    ) async throws(MatrixError) -> (users: [UserDirectoryEntry], limited: Bool) {
        let response: UserDirectoryResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/user_directory/search",
            body: UserDirectoryRequest(searchTerm: query, limit: limit),
            accessToken: try await token()
        )
        return (response.results, response.limited ?? false)
    }
}

/// `GET /profile/{userId}` response.
public struct UserProfile: Hashable, Sendable, Codable {
    /// Display name, if set.
    public var displayname: String?
    /// Avatar MXC URI string, if set. See `avatarMXC` for the typed form.
    public var avatarUrl: String?

    public init(displayname: String? = nil, avatarUrl: String? = nil) {
        self.displayname = displayname
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case displayname
        case avatarUrl = "avatar_url"
    }

    /// Avatar as a validated `MXCURI`. Nil when unset or malformed.
    public var avatarMXC: MXCURI? {
        avatarUrl.flatMap { try? MXCURI($0) }
    }
}

/// Display-name get/set body.
public struct DisplayNameResponse: Hashable, Sendable, Codable {
    /// The display name. Nil clears it.
    public var displayname: String?

    public init(displayname: String? = nil) {
        self.displayname = displayname
    }
}

/// Avatar URL get/set body.
public struct AvatarURLResponse: Hashable, Sendable, Codable {
    /// Avatar MXC URI string. Nil clears the avatar.
    public var avatarUrl: String?

    public init(avatarUrl: String? = nil) {
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case avatarUrl = "avatar_url"
    }
}

/// `GET /presence/{userId}/status` response body.
public struct UserPresence: Hashable, Sendable, Codable {
    /// Current presence state.
    public var presence: Presence
    /// Milliseconds since the user was last active, if reported.
    public var lastActiveAgo: Int?
    /// User-set status message, if any.
    public var statusMessage: String?
    /// Whether the user is currently active, if reported.
    public var currentlyActive: Bool?

    public init(
        presence: Presence,
        lastActiveAgo: Int? = nil,
        statusMessage: String? = nil,
        currentlyActive: Bool? = nil
    ) {
        self.presence = presence
        self.lastActiveAgo = lastActiveAgo
        self.statusMessage = statusMessage
        self.currentlyActive = currentlyActive
    }

    private enum CodingKeys: String, CodingKey {
        case presence
        case lastActiveAgo = "last_active_ago"
        case statusMessage = "status_msg"
        case currentlyActive = "currently_active"
    }
}

/// `PUT /presence/{userId}/status` request body.
public struct SetPresenceRequest: Hashable, Sendable, Codable {
    /// New presence state.
    public var presence: Presence
    /// Status message. Nil clears it.
    public var statusMessage: String?

    public init(presence: Presence, statusMessage: String? = nil) {
        self.presence = presence
        self.statusMessage = statusMessage
    }

    private enum CodingKeys: String, CodingKey {
        case presence
        case statusMessage = "status_msg"
    }
}

/// `POST /user_directory/search` request body.
public struct UserDirectoryRequest: Hashable, Sendable, Codable {
    /// Search term matched against MXIDs, display names, and 3PIDs.
    public var searchTerm: String
    /// Max results to return.
    public var limit: Int?

    public init(searchTerm: String, limit: Int? = nil) {
        self.searchTerm = searchTerm
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case searchTerm = "search_term"
        case limit
    }
}

/// One user-directory search hit.
public struct UserDirectoryEntry: Hashable, Sendable, Codable {
    /// The user's MXID.
    public var userId: UserId
    /// Display name, if set.
    public var displayName: String?
    /// Avatar MXC URI string, if set.
    public var avatarUrl: String?

    public init(userId: UserId, displayName: String? = nil, avatarUrl: String? = nil) {
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

/// `POST /user_directory/search` response body.
public struct UserDirectoryResponse: Hashable, Sendable, Codable {
    /// Matching users.
    public var results: [UserDirectoryEntry]
    /// Whether the result set was truncated.
    public var limited: Bool?

    public init(results: [UserDirectoryEntry] = [], limited: Bool? = nil) {
        self.results = results
        self.limited = limited
    }
}
