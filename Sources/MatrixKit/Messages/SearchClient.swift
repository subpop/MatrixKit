/// Full-text message search (`POST /_matrix/client/v3/search`).
public actor SearchClient {
    private let transport: MatrixTransport
    private let session: Session
    private let store: StateStore

    public init(transport: MatrixTransport, session: Session, store: StateStore) {
        self.transport = transport
        self.session = session
        self.store = store
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    /// Search room messages server-side. `from` continues a previous page
    /// (`nextBatch`); sender and room names resolve from profile info and
    /// the local store without extra requests. Page size is server-side.
    public func search(
        term: String, filter: MessageSearchFilter? = nil, from: String? = nil
    ) async throws(MatrixError) -> (
        results: [MessageSearchResult], nextBatch: String?, totalCount: Int?
    ) {
        var roomEvents: [String: AnyCodable] = [
            "search_term": .string(term),
            "order_by": .string(filter?.orderBy.rawValue ?? SearchOrder.recent.rawValue),
            "event_context": .object([
                "before_limit": .int(0),
                "after_limit": .int(0),
                "include_profile_info": .bool(true),
            ]),
        ]
        if let filter {
            var facet: [String: AnyCodable] = [:]
            if let rooms = filter.roomIds {
                facet["rooms"] = .array(rooms.map { .string($0.value) })
            }
            if let senders = filter.senderIds {
                facet["senders"] = .array(senders.map { .string($0.value) })
            }
            if !facet.isEmpty {
                roomEvents["filter"] = .object(facet)
            }
        }
        if let from {
            roomEvents["next_batch"] = .string(from)
        }
        let body = ["search_categories": AnyCodable.object(["room_events": .object(roomEvents)])]
        let response: SearchResponse = try await transport.send(
            .post, path: "/_matrix/client/v3/search",
            body: AnyCodableDictionary(body),
            accessToken: try await token()
        )
        guard let events = response.searchCategories?.roomEvents else {
            return ([], nil, nil)
        }
        var results: [MessageSearchResult] = []
        for entry in events.results ?? [] {
            if let result = await mapResult(entry, highlights: events.highlights ?? []) {
                results.append(result)
            }
        }
        return (results, events.nextBatch, events.count)
    }

    private func mapResult(
        _ entry: SearchResultEntry, highlights: [String]
    ) async -> MessageSearchResult? {
        let event = entry.result
        guard let roomId = event.roomId else { return nil }
        let profile = entry.context?.profileInfo?[event.sender.value]
        var roomName: String?
        var memberDisplayName: String?
        var memberAvatar: MXCURI?
        if let actor = await store.existingRoom(roomId) {
            roomName = await actor.name
            if let member = await actor.members[event.sender] {
                memberDisplayName = member.displayname
                memberAvatar = member.avatarUrl.flatMap { try? MXCURI($0) }
            }
        }
        return MessageSearchResult(
            eventId: event.eventId,
            roomId: roomId,
            roomName: roomName,
            sender: event.sender,
            senderDisplayName: profile?.displayname ?? memberDisplayName,
            senderAvatarURL: profile?.avatarUrl.flatMap { try? MXCURI($0) } ?? memberAvatar,
            body: event.messageContent?.body ?? "",
            timestamp: event.timestamp,
            rank: entry.rank,
            highlights: highlights)
    }
}

/// `POST /_matrix/client/v3/search` response body.
public struct SearchResponse: Hashable, Sendable, Codable {
    /// Search categories (only `room_events` is requested).
    public var searchCategories: SearchCategories?

    public init(searchCategories: SearchCategories? = nil) {
        self.searchCategories = searchCategories
    }

    private enum CodingKeys: String, CodingKey {
        case searchCategories = "search_categories"
    }
}

/// Search category results.
public struct SearchCategories: Hashable, Sendable, Codable {
    /// Room-message hits.
    public var roomEvents: RoomEventSearchResult?

    public init(roomEvents: RoomEventSearchResult? = nil) {
        self.roomEvents = roomEvents
    }

    private enum CodingKeys: String, CodingKey {
        case roomEvents = "room_events"
    }
}

/// Room-message search hits.
public struct RoomEventSearchResult: Hashable, Sendable, Codable {
    /// Approximate total matches.
    public var count: Int?
    /// Words to highlight in results.
    public var highlights: [String]?
    /// This page of hits.
    public var results: [SearchResultEntry]?
    /// Cursor for the next page, if more match.
    public var nextBatch: String?

    public init(
        count: Int? = nil, highlights: [String]? = nil,
        results: [SearchResultEntry]? = nil, nextBatch: String? = nil
    ) {
        self.count = count
        self.highlights = highlights
        self.results = results
        self.nextBatch = nextBatch
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case highlights
        case results
        case nextBatch = "next_batch"
    }
}

/// One ranked hit with its event context.
public struct SearchResultEntry: Hashable, Sendable, Codable {
    /// Server relevance score.
    public var rank: Double?
    /// The matching event.
    public var result: MessageEvent
    /// Surrounding context and profile info.
    public var context: SearchResultContext?

    public init(
        rank: Double? = nil, result: MessageEvent,
        context: SearchResultContext? = nil
    ) {
        self.rank = rank
        self.result = result
        self.context = context
    }
}

/// Event context for one hit (profile info only in this client).
public struct SearchResultContext: Hashable, Sendable, Codable {
    /// Display names and avatars by user ID.
    public var profileInfo: [String: ProfileInfo]?

    public init(profileInfo: [String: ProfileInfo]? = nil) {
        self.profileInfo = profileInfo
    }

    private enum CodingKeys: String, CodingKey {
        case profileInfo = "profile_info"
    }
}

/// Profile info for one user.
public struct ProfileInfo: Hashable, Sendable, Codable {
    /// Display name, if set.
    public var displayname: String?
    /// Avatar MXC URI, if set.
    public var avatarUrl: String?

    public init(displayname: String? = nil, avatarUrl: String? = nil) {
        self.displayname = displayname
        self.avatarUrl = avatarUrl
    }

    private enum CodingKeys: String, CodingKey {
        case displayname
        case avatarUrl = "avatar_url"
    }
}
