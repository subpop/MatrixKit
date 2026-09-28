import Foundation
import MatrixKit

/// In-memory `RoomKeySharer`: serves a fixed device list and records
/// `m.room_key` shares.
///
/// Shared fake (moved from `RoomCryptoTests`).
public actor FakeSharer: RoomKeySharer {
    public var devices: [String: [String]] = [:]
    public var shares: [(
        user: String, devices: [String],
        content: [String: AnyCodable], eventType: String
    )] = []
    public var identity = "SELFEDKEY"

    public init() {}

    /// Fix the device list served for a user.
    public func setDevices(_ devices: [String: [String]]) {
        self.devices = devices
    }

    public func deviceIds(for user: UserId) async throws(MatrixError) -> [String] {
        devices[user.value] ?? []
    }

    public func sendEncrypted(
        eventType: String, content: [String: AnyCodable],
        to user: UserId, devices: [DeviceId]
    ) async throws(MatrixError) {
        shares.append((
            user.value, devices.map(\.value), content, eventType))
    }

    public func identityKey() async throws(MatrixError) -> String { identity }
}

/// In-memory `RoomEventSender`: records sent room events.
///
/// Shared fake (moved from `RoomCryptoTests`).
public actor FakeRoomSender: RoomEventSender {
    public var sent: [(room: String, type: String, content: [String: AnyCodable], txn: String)] = []
    private var counter = 0

    public init() {}

    /// Clear the log between table rows sharing one sender.
    public func reset() {
        sent = []
    }

    public func sendEvent(
        _ roomId: RoomId,
        eventType: String,
        content: any Encodable & Sendable,
        transactionId: TransactionId
    ) async throws(MatrixError) -> EventId {
        guard let dict = content as? [String: AnyCodable] else {
            throw .encodingError("FakeRoomSender only handles dict content")
        }
        counter += 1
        sent.append((roomId.value, eventType, dict, transactionId.value))
        return EventId(unchecked: "$fake\(counter)")
    }
}

/// Canned `TimelinePaging`: serves one fixed page per direction plus a
/// configurable event-context window.
///
/// Shared fake (moved from `RoomCryptoTests`).
public actor FakePager: TimelinePaging {
    public var page: PaginationChunk<MessageEvent> = PaginationChunk(start: "s")
    public var forwardPage: PaginationChunk<MessageEvent> = PaginationChunk(start: "s")
    public var calls = 0
    public var contextBefore: [MessageEvent] = []
    public var contextEvent: MessageEvent?
    public var contextAfter: [MessageEvent] = []
    public var contextStart: BatchToken?
    public var contextEnd: BatchToken?

    public init() {}

    public func paginate(
        _ roomId: RoomId,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent> {
        calls += 1
        switch direction {
        case .backward: return page
        case .forward: return forwardPage
        }
    }

    public func context(
        _ roomId: RoomId,
        eventId: EventId,
        limit: Int
    ) async throws(MatrixError) -> EventContext {
        EventContext(
            roomId: roomId, focusEventId: eventId,
            eventsBefore: contextBefore, event: contextEvent,
            eventsAfter: contextAfter, start: contextStart, end: contextEnd)
    }

    public var eventsById: [EventId: MessageEvent] = [:]
    public var relationChunk: [MessageEvent] = []
    public var relationEnd: String?
    public var eventError: MatrixError?
    public var relationsError: MatrixError?

    public func event(
        _ roomId: RoomId,
        _ eventId: EventId
    ) async throws(MatrixError) -> MessageEvent {
        if let eventError { throw eventError }
        guard let event = eventsById[eventId] else { throw .notAuthenticated }
        return event
    }

    public func relations(
        _ roomId: RoomId,
        eventId: EventId,
        relType: String,
        eventType: String?,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> RelationsResponse {
        calls += 1
        if let relationsError { throw relationsError }
        return RelationsResponse(
            chunk: relationChunk, nextBatch: relationEnd)
    }

    public func setPage(_ page: PaginationChunk<MessageEvent>) {
        self.page = page
    }

    public func setContext(
        before: [MessageEvent], focus: MessageEvent?, after: [MessageEvent],
        start: String?, end: String?
    ) {
        contextBefore = before
        contextEvent = focus
        contextAfter = after
        contextStart = start.map { BatchToken($0) }
        contextEnd = end.map { BatchToken($0) }
    }

    public func setForwardPage(_ page: PaginationChunk<MessageEvent>) {
        self.forwardPage = page
    }

    public func setEvents(_ events: [EventId: MessageEvent]) {
        self.eventsById = events
    }

    public func setRelations(chunk: [MessageEvent], nextBatch: String?) {
        self.relationChunk = chunk
        self.relationEnd = nextBatch
    }

    public func setEventError(_ error: MatrixError?) {
        self.eventError = error
    }

    public func setRelationsError(_ error: MatrixError?) {
        self.relationsError = error
    }
}
