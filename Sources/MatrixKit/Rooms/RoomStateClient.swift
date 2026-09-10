/// Room state, typing, and read receipts.
public actor RoomStateClient {
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

    // MARK: - State

    /// Full room state (`GET /rooms/{roomId}/state`).
    public func getState(_ roomId: RoomId) async throws(MatrixError) -> [MessageEvent] {
        let response: StateResponse = try await transport.send(
            .get, path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/state",
            accessToken: try await token()
        )
        return response.events
    }

    /// A single state event's content (`GET /rooms/{roomId}/state/{type}/{key}`).
    public func getStateEvent(
        _ roomId: RoomId, type: String, stateKey: String = ""
    ) async throws(MatrixError) -> [String: AnyCodable] {
        try await transport.send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/state/\(type.pathSegmentEncoded)/\(stateKey.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    /// Send a state event (`PUT /rooms/{roomId}/state/{type}/{key}`).
    @discardableResult
    public func sendStateEvent(
        _ roomId: RoomId, type: String, stateKey: String = "",
        content: [String: AnyCodable]
    ) async throws(MatrixError) -> EventId {
        let response: SendEventResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/state/\(type.pathSegmentEncoded)/\(stateKey.pathSegmentEncoded)",
            body: AnyCodableDictionary(content),
            accessToken: try await token()
        )
        return response.eventId
    }

    // MARK: - Convenience

    /// Set the room name (`m.room.name`).
    @discardableResult
    public func setName(_ roomId: RoomId, name: String) async throws(MatrixError) -> EventId {
        try await sendStateEvent(
            roomId, type: EventType.roomName.rawValue,
            content: ["name": .string(name)]
        )
    }

    /// Set the room topic (`m.room.topic`).
    @discardableResult
    public func setTopic(_ roomId: RoomId, topic: String) async throws(MatrixError) -> EventId {
        try await sendStateEvent(
            roomId, type: EventType.roomTopic.rawValue,
            content: ["topic": .string(topic)]
        )
    }

    /// Set the room avatar (`m.room.avatar`).
    @discardableResult
    public func setAvatar(_ roomId: RoomId, url: MXCURI) async throws(MatrixError) -> EventId {
        try await sendStateEvent(
            roomId, type: EventType.roomAvatar.rawValue,
            content: ["url": .string(url.value)]
        )
    }

    // MARK: - Typing & receipts

    /// Send typing notification (`PUT /rooms/{roomId}/typing/{userId}`).
    public func sendTyping(
        _ roomId: RoomId, userId: UserId, typing: Bool, timeoutMs: Int? = nil
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/typing/\(userId.pathSegmentEncoded)",
            body: TypingRequest(typing: typing, timeout: timeoutMs),
            accessToken: try await token()
        )
    }

    /// Send a read receipt (`POST /rooms/{roomId}/receipt/{type}/{eventId}`).
    public func sendReceipt(
        _ roomId: RoomId, eventId: EventId, receiptType: String = "m.read"
    ) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .post,
            path: "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/receipt/\(receiptType.pathSegmentEncoded)/\(eventId.pathSegmentEncoded)",
            body: ReceiptRequest(),
            accessToken: try await token()
        )
    }

    /// Current `m.room.power_levels` content (throws when absent).
    public func powerLevels(_ roomId: RoomId) async throws(MatrixError) -> [String: AnyCodable] {
        try await getStateEvent(roomId, type: "m.room.power_levels")
    }

    /// Set one member's power level (read-modify-write, preserving the
    /// rest of the power-levels event).
    public func setMemberPowerLevel(
        _ roomId: RoomId, userId: UserId, powerLevel: Int
    ) async throws(MatrixError) {
        var content = try await powerLevels(roomId)
        var users = content["users"]?.objectValue ?? [:]
        users[userId.value] = .int(powerLevel)
        content["users"] = .object(users)
        _ = try await sendStateEvent(
            roomId, type: "m.room.power_levels", content: content)
    }

    /// Replace the power-level thresholds (read-modify-write, preserving
    /// per-user entries and unrelated keys).
    public func updatePowerLevelSettings(
        _ roomId: RoomId, settings: RoomPowerLevelSettings
    ) async throws(MatrixError) {
        _ = try await sendStateEvent(
            roomId, type: "m.room.power_levels",
            content: settings.applying(to: try await powerLevels(roomId)))
    }
}

/// `GET /rooms/{roomId}/state` response (bare array).
public struct StateResponse: Hashable, Sendable, Codable {
    /// Full room state events (the endpoint returns a bare array).
    public var events: [MessageEvent]

    public init(events: [MessageEvent] = []) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.events = try container.decode([MessageEvent].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(events)
    }
}

/// Encodable wrapper for `[String: AnyCodable]` bodies.
public struct AnyCodableDictionary: Hashable, Sendable, Codable {
    /// The wrapped content dictionary.
    public var value: [String: AnyCodable]

    public init(_ value: [String: AnyCodable]) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode([String: AnyCodable].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// `PUT .../typing/{userId}` body.
public struct TypingRequest: Hashable, Sendable, Codable {
    /// Whether the user started (`true`) or stopped (`false`) typing.
    public var typing: Bool
    /// How long (ms) the server should consider the user typing.
    public var timeout: Int?

    public init(typing: Bool, timeout: Int? = nil) {
        self.typing = typing
        self.timeout = timeout
    }
}

/// Read receipt body (empty object).
public struct ReceiptRequest: Hashable, Sendable, Codable {
    public init() {}
}
