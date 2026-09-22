import Logging

/// Sending and paginating room messages.
public actor MessageClient {
    private let transport: MatrixTransport
    private let session: Session
    private let logger: Logger

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
        var logger = Logger(label: "MatrixKit.MessageClient")
        MatrixTransport.applyConfiguredLevel(to: &logger)
        self.logger = logger
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Send

    /// Send a raw event payload (`PUT /rooms/{roomId}/send/{type}/{txnId}`).
    @discardableResult
    public func sendEvent(
        _ roomId: RoomId,
        eventType: String = EventType.roomMessage.rawValue,
        content: any Encodable & Sendable,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        let response: SendEventResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/send/\(eventType.pathSegmentEncoded)/\(transactionId.value.pathSegmentEncoded)",
            body: content,
            accessToken: try await token()
        )
        logger.debug("\(Self.friendlySendVerb(eventType: eventType))")
        return response.eventId
    }

    /// Friendly past-tense verb for a sent event, by type. Message
    /// bodies never enter logs — only the kind of event sent.
    private static func friendlySendVerb(eventType: String) -> String {
        switch eventType {
        case EventType.roomMessage.rawValue: "Sent message"
        case "m.room.encrypted": "Sent encrypted message"
        case EventType.reaction.rawValue: "Sent reaction"
        default: "Sent event"
        }
    }

    /// Send a message event (`PUT /rooms/{roomId}/send/{type}/{txnId}`).
    @discardableResult
    public func send(
        _ roomId: RoomId,
        content: MessageContent,
        eventType: String = EventType.roomMessage.rawValue,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await sendEvent(roomId, eventType: eventType, content: content, transactionId: transactionId)
    }

    /// Send a plain-text message.
    @discardableResult
    public func sendText(
        _ roomId: RoomId, _ body: String, relatesTo: RelatesTo? = nil,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await send(
            roomId, content: .text(body, relatesTo: relatesTo, mentions: mentions),
            transactionId: transactionId)
    }

    /// Send an HTML message with plain-text fallback.
    @discardableResult
    public func sendHTML(
        _ roomId: RoomId, body: String, formattedBody: String, relatesTo: RelatesTo? = nil,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await send(
            roomId,
            content: .html(
                body, formattedBody: formattedBody, relatesTo: relatesTo, mentions: mentions),
            transactionId: transactionId)
    }
    /// Reply to an event (rich reply with fallback).
    @discardableResult

    public func reply(
        _ roomId: RoomId, to eventId: EventId, body: String,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await send(
            roomId,
            content: .markdown(
                body, relatesTo: .reply(to: eventId), mentions: mentions),
            transactionId: transactionId)
    }

    /// Reply inside a thread (`m.thread` rooted at `root`, with an
    /// `m.in_reply_to` fallback to the direct parent).
    @discardableResult
    public func threadReply(
        _ roomId: RoomId, root: EventId, parent: EventId? = nil, body: String,
        mentions: Mentions? = nil, transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await send(
            roomId,
            content: .markdown(
                body, relatesTo: .thread(root: root, replyTo: parent),
                mentions: mentions),
            transactionId: transactionId)
    }

    /// Edit a message (`m.replace` relation + `m.new_content`).
    @discardableResult
    public func edit(
        _ roomId: RoomId, eventId: EventId, newBody: String,
        mentions: Mentions? = nil
    ) async throws(MatrixError) -> EventId {
        let content = EditContent.markdown(
            editing: eventId, newBody, mentions: mentions)
        return try await sendEvent(roomId, content: content)
    }

    /// Redact an event (`PUT /rooms/{roomId}/redact/{eventId}/{txnId}`).
    @discardableResult
    public func redact(
        _ roomId: RoomId, eventId: EventId, reason: String? = nil,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        let response: SendEventResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/redact/\(eventId.pathSegmentEncoded)/\(transactionId.value.pathSegmentEncoded)",
            body: RedactRequest(reason: reason),
            accessToken: try await token()
        )
        return response.eventId
    }

    /// React with an emoji key (`m.reaction`).
    @discardableResult
    public func react(
        _ roomId: RoomId, to eventId: EventId, key: String,
        transactionId: TransactionId = .random()
    ) async throws(MatrixError) -> EventId {
        try await sendEvent(
            roomId,
            eventType: EventType.reaction.rawValue,
            content: ReactionContent.reaction(to: eventId, key: key),
            transactionId: transactionId
        )
    }

    // MARK: - Paginate

    /// Page through room history (`GET /rooms/{roomId}/messages`).
    public func paginate(
        _ roomId: RoomId,
        from: BatchToken?,
        limit: Int = 50,
        direction: PaginationDirection = .backward
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent> {
        var query: [String: String] = [
            "limit": "\(limit)",
            "dir": direction.rawValue,
        ]
        if let from { query["from"] = from.value }
        let response: MessagesResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/messages",
            query: query,
            accessToken: try await token()
        )
        return PaginationChunk(
            start: response.start, end: response.end, chunk: response.chunk)
    }

    // MARK: - Context

    /// Fetch one event (`GET /rooms/{roomId}/event/{eventId}`).
    public func event(
        _ roomId: RoomId, _ eventId: EventId
    ) async throws(MatrixError) -> MessageEvent {
        try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/event/\(eventId.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Fetch related events (`GET /_matrix/client/v1/rooms/{roomId}/
    /// relations/{eventId}/{relType}[/{eventType}]`). Thread replies live
    /// under relType `m.thread`. Note the `v1` base: unlike most room
    /// endpoints, servers expose relations there, not under `v3`.
    public func relations(
        _ roomId: RoomId, eventId: EventId, relType: String, eventType: String? = nil,
        from: BatchToken? = nil, limit: Int = 50, direction: PaginationDirection = .backward
    ) async throws(MatrixError) -> RelationsResponse {
        var path = "/_matrix/client/v1/rooms/\(roomId.pathSegmentEncoded)"
            + "/relations/\(eventId.pathSegmentEncoded)/\(relType)"
        if let eventType { path += "/\(eventType)" }
        var query: [String: String] = [
            "limit": "\(limit)",
            "dir": direction.rawValue,
        ]
        if let from { query["from"] = from.value }
        return try await transport.send(
            .get, path: path, query: query, accessToken: try await token())
    }

    /// Load context around one event (`GET /rooms/{roomId}/context/{eventId}`).
    public func context(
        _ roomId: RoomId, eventId: EventId, limit: Int = 20
    ) async throws(MatrixError) -> EventContext {
        let response: ContextResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/context/\(eventId.pathSegmentEncoded)",
            query: ["limit": "\(limit)"],
            accessToken: try await token()
        )
        return EventContext(
            roomId: roomId,
            focusEventId: eventId,
            eventsBefore: response.eventsBefore,
            event: response.event,
            eventsAfter: response.eventsAfter,
            start: response.start.map { BatchToken($0) },
            end: response.end.map { BatchToken($0) })
    }
}

/// `GET /rooms/{roomId}/relations/{eventId}/{relType}` response body.
public struct RelationsResponse: Hashable, Sendable, Codable {
    /// Related events (reverse-chronological for `dir=b`).
    public var chunk: [MessageEvent]
    /// Token for the next (older) page, if more exist.
    public var nextBatch: String?
    /// Token for the previous (newer) page, if any.
    public var prevBatch: String?

    public init(
        chunk: [MessageEvent] = [], nextBatch: String? = nil, prevBatch: String? = nil
    ) {
        self.chunk = chunk
        self.nextBatch = nextBatch
        self.prevBatch = prevBatch
    }

    private enum CodingKeys: String, CodingKey {
        case chunk
        case nextBatch = "next_batch"
        case prevBatch = "prev_batch"
    }
}

/// `GET /rooms/{roomId}/context/{eventId}` response body.
public struct ContextResponse: Hashable, Sendable, Codable {
    /// Events before the focus event (reverse-chronological, newest first).
    public var eventsBefore: [MessageEvent]
    /// The focus event, when visible to the requester.
    public var event: MessageEvent?
    /// Events after the focus event (chronological, oldest first).
    public var eventsAfter: [MessageEvent]
    /// Pagination token toward older history.
    public var start: String?
    /// Pagination token toward newer history.
    public var end: String?
    /// State at the start of the context, when requested.
    public var state: [MessageEvent]?

    public init(
        eventsBefore: [MessageEvent] = [],
        event: MessageEvent? = nil,
        eventsAfter: [MessageEvent] = [],
        start: String? = nil,
        end: String? = nil,
        state: [MessageEvent]? = nil
    ) {
        self.eventsBefore = eventsBefore
        self.event = event
        self.eventsAfter = eventsAfter
        self.start = start
        self.end = end
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case eventsBefore = "events_before"
        case event
        case eventsAfter = "events_after"
        case start
        case end
        case state
    }
}

/// Context window around one event, oldest first.
public struct EventContext: Hashable, Sendable {
    /// The room the context belongs to.
    public var roomId: RoomId
    /// The focused event's ID.
    public var focusEventId: EventId
    /// Events before the focus (reverse-chronological from the server).
    public var eventsBefore: [MessageEvent]
    /// The focus event, when visible to the requester.
    public var event: MessageEvent?
    /// Events after the focus (chronological from the server).
    public var eventsAfter: [MessageEvent]
    /// Pagination token toward older history.
    public var start: BatchToken?
    /// Pagination token toward newer history.
    public var end: BatchToken?

    public init(
        roomId: RoomId,
        focusEventId: EventId,
        eventsBefore: [MessageEvent] = [],
        event: MessageEvent? = nil,
        eventsAfter: [MessageEvent] = [],
        start: BatchToken? = nil,
        end: BatchToken? = nil
    ) {
        self.roomId = roomId
        self.focusEventId = focusEventId
        self.eventsBefore = eventsBefore
        self.event = event
        self.eventsAfter = eventsAfter
        self.start = start
        self.end = end
    }

    /// Whole window, oldest first. Servers may repeat the anchor (or
    /// boundary events) across the segments; duplicates are dropped so
    /// downstream rendering sees unique IDs.
    public var events: [MessageEvent] {
        (eventsBefore.reversed() + (event.map { [$0] } ?? []) + eventsAfter)
            .dedupedByEventId()
    }
}
/// `GET /rooms/{roomId}/messages` response body.
public struct MessagesResponse: Hashable, Sendable, Codable {
    /// Cursor at the start of this page.
    public var start: String
    /// Cursor for the next page, if more history exists.
    public var end: String?
    /// Events in this page.
    public var chunk: [MessageEvent]
    /// State at the start of the chunk (paginated `/messages` only).
    public var state: [MessageEvent]?

    public init(start: String, end: String? = nil, chunk: [MessageEvent] = [], state: [MessageEvent]? = nil) {
        self.start = start
        self.end = end
        self.chunk = chunk
        self.state = state
    }
}

/// `m.room.message` content for an edit (`m.replace` + `m.new_content`).
public struct EditContent: Hashable, Sendable, Codable {
    /// Fallback text (` * <new body>`) for clients without edit support.
    public var body: String
    /// The replacement message content.
    public var newContent: MessageContent
    /// `m.replace` relation pointing at the edited event.
    public var relatesTo: RelatesTo

    public init(body: String, newContent: MessageContent, relatesTo: RelatesTo) {
        self.body = body
        self.newContent = newContent
        self.relatesTo = relatesTo
    }

    private enum CodingKeys: String, CodingKey {
        case body
        case newContent = "m.new_content"
        case relatesTo = "m.relates_to"
    }
}

extension EditContent {
    /// Replacement content for editing a markdown text message.
    /// `m.new_content` repeats the full formatted content per spec.
    public static func markdown(
        editing eventId: EventId, _ newBody: String, mentions: Mentions? = nil
    ) -> EditContent {
        EditContent(
            body: " * \(newBody)",
            newContent: .markdown(newBody, mentions: mentions),
            relatesTo: .edit(of: eventId))
    }
}
