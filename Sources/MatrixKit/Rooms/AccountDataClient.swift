/// Account-data client: per-user and per-room key/value storage
/// (`GET/PUT /user/{userId}[/rooms/{roomId}]/account_data/{type}`).
public actor AccountDataClient {
    /// Read-marker account-data type (`m.fully_read`).
    public static let fullyReadType = "m.fully_read"
    /// Ignore-list account-data type (`m.ignored_user_list`).
    public static let ignoredUsersType = "m.ignored_user_list";
    /// Direct-chat account-data type (`m.direct`).
    public static let directType = "m.direct";

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

    private func userSegment() async -> String {
        await session.userId.pathSegmentEncoded
    }

    /// Global account-data entry, or nil when unset (`M_NOT_FOUND`).
    public func get(_ type: String) async throws(MatrixError) -> [String: AnyCodable]? {
        do {
            return try await transport.send(
                .get,
                path: "/_matrix/client/v3/user/\(await userSegment())/account_data/\(type)",
                accessToken: try await token()
            )
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            return nil
        }
    }

    /// Write a global account-data entry.
    public func put(_ type: String, content: [String: AnyCodable]) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/user/\(await userSegment())/account_data/\(type)",
            body: content,
            accessToken: try await token()
        )
    }

    /// Room account-data entry, or nil when unset (`M_NOT_FOUND`).
    public func getRoom(_ roomId: RoomId, _ type: String) async throws(MatrixError) -> [String: AnyCodable]? {
        do {
            return try await transport.send(
                .get,
                path: "/_matrix/client/v3/user/\(await userSegment())/rooms/\(roomId.pathSegmentEncoded)/account_data/\(type)",
                accessToken: try await token()
            )
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            return nil
        }
    }

    /// Write a room account-data entry.
    public func putRoom(
        _ roomId: RoomId, _ type: String, content: [String: AnyCodable]
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/user/\(await userSegment())/rooms/\(roomId.pathSegmentEncoded)/account_data/\(type)",
            body: content,
            accessToken: try await token()
        )
    }

    /// Advance the room's fully-read marker via the read-markers endpoint
    /// (`m.fully_read` cannot be written through the account-data PUT API).
    public func setFullyRead(_ roomId: RoomId, eventId: EventId) async throws(MatrixError) {
        let body: [String: AnyCodable] = ["m.fully_read": .string(eventId.value)]
        let _: EmptyResponse = try await transport.send(
            .post,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/read_markers",
            body: body,
            accessToken: try await token()
        )
    }

    /// The room's fully-read marker, or nil when unset or malformed.
    public func fullyRead(_ roomId: RoomId) async throws(MatrixError) -> EventId? {
        guard
            let id = try await getRoom(roomId, Self.fullyReadType)?["event_id"]?.stringValue
        else { return nil }
        return try? EventId(id)
    }

    /// The room's tags (`GET /user/{userId}/rooms/{roomId}/tags`), or nil
    /// when unset (`M_NOT_FOUND`).
    public func tags(_ roomId: RoomId) async throws(MatrixError) -> TagsResponse? {
        do {
            return try await transport.send(
                .get,
                path: tagsPath(roomId),
                accessToken: try await token()
            )
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            return nil
        }
    }

    /// Add a tag (`PUT /user/{userId}/rooms/{roomId}/tags/{tag}`).
    /// `order` is an optional ordering hint in [0, 1).
    public func addTag(
        _ roomId: RoomId, _ tag: String, order: Double? = nil
    ) async throws(MatrixError) {
        let body: [String: AnyCodable] = order.map { ["order": .double($0)] } ?? [:]
        let _: EmptyResponse = try await transport.send(
            .put,
            path: tagPath(roomId, tag),
            body: body,
            accessToken: try await token()
        )
    }

    /// Remove a tag (`DELETE /user/{userId}/rooms/{roomId}/tags/{tag}`).
    /// Deleting a tag the room does not have is not an error for us.
    public func deleteTag(_ roomId: RoomId, _ tag: String) async throws(MatrixError) {
        do {
            let _: EmptyResponse = try await transport.send(
                .delete,
                path: tagPath(roomId, tag),
                accessToken: try await token()
            )
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            // Already absent — treat as success (idempotent UX).
        }
    }

    /// Set or clear the `m.favourite` tag via the tag endpoints
    /// (`PUT`/`DELETE .../tags/m.favourite`).
    public func setFavourite(_ roomId: RoomId, isFavourite: Bool) async throws(MatrixError) {
        if isFavourite {
            try await addTag(roomId, "m.favourite", order: 0.5)
        } else {
            try await deleteTag(roomId, "m.favourite")
        }
    }

    private func tagsPath(_ roomId: RoomId) async -> String {
        "/_matrix/client/v3/user/\(await session.userId.pathSegmentEncoded)"
            + "/rooms/\(roomId.pathSegmentEncoded)/tags"
    }

    private func tagPath(_ roomId: RoomId, _ tag: String) async -> String {
        await tagsPath(roomId) + "/\(tag.pathSegmentEncoded)"
    }

    /// Ignored users from `m.ignored_user_list`.
    public func ignoredUsers() async throws(MatrixError) -> Set<UserId> {
        guard
            let dict = try await get(Self.ignoredUsersType)?["ignored_users"]?.objectValue
        else { return [] }
        return Set(dict.keys.map(UserId.init(unchecked:)))
    }

    /// Ignore or unignore a user (read-modify-write, preserving others).
    public func setIgnored(_ userId: UserId, ignored: Bool) async throws(MatrixError) {
        try await put(
            Self.ignoredUsersType,
            content: Self.ignoredList(
                in: try await get(Self.ignoredUsersType),
                userId: userId, ignored: ignored))
    }

    /// Ignore-list content for a read-modify-write (pure).
    nonisolated static func ignoredList(
        in content: [String: AnyCodable]?, userId: UserId, ignored: Bool
    ) -> [String: AnyCodable] {
        var dict = content?["ignored_users"]?.objectValue ?? [:]
        if ignored {
            dict[userId.value] = .object([:])
        } else {
            dict.removeValue(forKey: userId.value)
        }
        return ["ignored_users": .object(dict)]
    }

    /// Record or unrecord a room as a direct chat for a user in
    /// `m.direct` (read-modify-write, preserving other entries).
    public func setDirectRoom(
        _ roomId: RoomId, for userId: UserId, isDirect: Bool
    ) async throws(MatrixError) {
        try await put(
            Self.directType,
            content: Self.directRoomsContent(
                in: try await get(Self.directType),
                userId: userId, roomId: roomId, isDirect: isDirect))
    }

    /// `m.direct` content for a read-modify-write (pure).
    nonisolated static func directRoomsContent(
        in content: [String: AnyCodable]?, userId: UserId, roomId: RoomId, isDirect: Bool
    ) -> [String: AnyCodable] {
        var map = content ?? [:]
        var rooms = map[userId.value]?.arrayValue?.compactMap(\.stringValue) ?? []
        if isDirect {
            if !rooms.contains(roomId.value) {
                rooms.append(roomId.value)
            }
            map[userId.value] = .array(rooms.map(AnyCodable.string))
        } else {
            rooms.removeAll { $0 == roomId.value }
            if rooms.isEmpty {
                map.removeValue(forKey: userId.value)
            } else {
                map[userId.value] = .array(rooms.map(AnyCodable.string))
            }
        }
        return map
    }
}
