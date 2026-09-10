/// Per-room timeline facade: snapshots plus backwards pagination.
///
/// Live events arrive via sync into the `RoomActor`; `paginateBack()` fetches
/// older history through `/messages` and prepends it.
import Foundation

extension Array where Element == MessageEvent {
    /// Events with duplicate IDs removed, keeping the first occurrence.
    ///
    /// Servers may overlap window boundaries (context anchor, pagination
    /// edges); rendering requires unique IDs, so every stitch point
    /// dedupes through here.
    func dedupedByEventId() -> [MessageEvent] {
        var seen = Set<EventId>()
        return filter { seen.insert($0.eventId).inserted }
    }
}

public actor Timeline {
    /// The room this timeline belongs to.
    public let roomId: RoomId
    private let messages: any TimelinePaging
    private let room: RoomActor
    private var isPaginating = false
    /// Optional Megolm decryptor applied to paginated history
    /// (same contract as `SyncCryptoHooks.decryptRoomEvent`).
    private var decryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?

    public init(roomId: RoomId, messages: any TimelinePaging, room: RoomActor) {
        self.roomId = roomId
        self.messages = messages
        self.room = room
    }

    /// Set the decryptor applied to events loaded by `paginateBack`.
    public func setDecryptor(
        _ decryptor:
            (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    ) {
        self.decryptor = decryptor
    }

    /// Current in-memory events, oldest first.
    public func events() async -> [MessageEvent] {
        await room.timeline
    }

    /// Whether older history may exist (`prev_batch` cursor known).
    public func canPaginateBack() async -> Bool {
        await room.prevBatch != nil
    }

    /// Whether a `paginateBack` request is currently in flight.
    public func paginationInProgress() -> Bool {
        isPaginating
    }

    /// Load one page of older history. Returns the number of events loaded.
    @discardableResult
    public func paginateBack(limit: Int = 50) async throws(MatrixError) -> Int {
        guard !isPaginating else { return 0 }
        guard let from = await room.prevBatch else { return 0 }
        isPaginating = true
        defer { isPaginating = false }
        let page = try await messages.paginate(roomId, from: from, limit: limit)
        // `/messages dir=b` returns newest-first; the timeline reads oldest-first.
        var chunk = Array(page.chunk.reversed())
        if let decryptor {
            var decrypted: [MessageEvent] = []
            decrypted.reserveCapacity(chunk.count)
            for event in chunk {
                decrypted.append(await decryptor(event, roomId) ?? event)
            }
            chunk = decrypted
        }
        // `/messages` pages can overlap the live window; drop repeats.
        let known = Set(await room.timeline.map(\.eventId))
        chunk.removeAll { known.contains($0.eventId) }
        await room.prependHistory(
            chunk, prevBatch: page.end.map { BatchToken($0) })
        return chunk.count
    }

    /// Room updates (new events, state, typing, ...) for live UI.
    public func updates() async -> AsyncStream<RoomUpdate> {
        await room.updates()
    }

    /// Find a reaction event by target, key, and sender (for toggling
    /// reactions off, which needs the reaction's event ID).
    public func reactionEvent(
        target: EventId, key: String, sender: UserId
    ) async -> EventId? {
        for event in await room.timeline {
            guard EventType(rawValue: event.type) == .reaction,
                !event.isRedacted,
                event.sender == sender,
                let data = try? JSONEncoder().encode(event.content),
                let content = try? JSONDecoder().decode(
                    ReactionContent.self, from: data),
                content.relatesTo.eventId == target,
                content.relatesTo.key == key
            else { continue }
            return event.eventId
        }
        return nil
    }
}

/// Event-context window: a stable snapshot around one event, pageable
/// in both directions. Unlike `Timeline` this is detached from the live
/// `RoomActor` window — used for event permalinks and thread roots.
/// Forward pages assume `/messages` `dir=f` returns oldest-first.
public actor FocusedTimeline {
    /// The room this window belongs to.
    public let roomId: RoomId
    /// The focused event's ID.
    public let focusEventId: EventId
    /// Buffered window, oldest first.
    public private(set) var events: [MessageEvent]
    /// Cursor toward older history (`GET /messages` `dir=b`).
    public private(set) var start: BatchToken?
    /// Cursor toward newer history (`GET /messages` `dir=f`).
    public private(set) var end: BatchToken?

    private let messages: any TimelinePaging
    private var isPaginating = false
    /// Optional Megolm decryptor applied to loaded events
    /// (same contract as `SyncCryptoHooks.decryptRoomEvent`).
    private var decryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?

    public init(roomId: RoomId, focusEventId: EventId, messages: any TimelinePaging) {
        self.roomId = roomId
        self.focusEventId = focusEventId
        self.messages = messages
        self.events = []
    }

    /// Set the decryptor applied to loaded events.
    public func setDecryptor(
        _ decryptor:
            (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    ) {
        self.decryptor = decryptor
    }

    /// Load the initial context window around the focus event.
    public func load(limit: Int = 20) async throws(MatrixError) {
        let context = try await messages.context(roomId, eventId: focusEventId, limit: limit)
        events = await decrypted(context.events)
        start = context.start
        end = context.end
    }

    /// Whether older history may exist (`start` cursor known).
    public func canPaginateBack() -> Bool {
        start != nil
    }

    /// Whether newer history may exist (`end` cursor known).
    public func canPaginateForward() -> Bool {
        end != nil
    }

    /// Whether a pagination request is currently in flight.
    public func paginationInProgress() -> Bool {
        isPaginating
    }

    /// Load one page of older history. Returns the number of events loaded.
    @discardableResult
    public func paginateBack(limit: Int = 50) async throws(MatrixError) -> Int {
        guard !isPaginating, let from = start else { return 0 }
        isPaginating = true
        defer { isPaginating = false }
        let page = try await messages.paginate(
            roomId, from: from, limit: limit, direction: .backward)
        let known = Set(events.map(\.eventId))
        // `/messages dir=b` returns newest-first; the window reads oldest-first.
        let chunk = await decrypted(page.chunk).reversed().filter { !known.contains($0.eventId) }
        events.insert(contentsOf: chunk, at: 0)
        start = page.end.map { BatchToken($0) }
        return chunk.count
    }

    /// Load one page of newer history. Returns the number of events loaded.
    @discardableResult
    public func paginateForward(limit: Int = 50) async throws(MatrixError) -> Int {
        guard !isPaginating, let from = end else { return 0 }
        isPaginating = true
        defer { isPaginating = false }
        let page = try await messages.paginate(
            roomId, from: from, limit: limit, direction: .forward)
        let known = Set(events.map(\.eventId))
        let chunk = await decrypted(page.chunk).filter { !known.contains($0.eventId) }
        events.append(contentsOf: chunk)
        end = page.end.map { BatchToken($0) }
        return chunk.count
    }

    private func decrypted(_ events: [MessageEvent]) async -> [MessageEvent] {
        guard let decryptor else { return events }
        var out: [MessageEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            out.append(await decryptor(event, roomId) ?? event)
        }
        return out
    }
}

/// Thread view: the root event plus its `m.thread` replies, oldest
/// first. Detached from the live `RoomActor` window like
/// `FocusedTimeline`.
public actor ThreadTimeline {
    /// The room the thread belongs to.
    public let roomId: RoomId
    /// The thread root's event ID.
    public let rootEventId: EventId
    /// The root event, once loaded.
    public private(set) var root: MessageEvent?
    /// Thread replies, oldest first.
    public private(set) var replies: [MessageEvent]
    /// Cursor toward older replies (`next_batch` of the relations query).
    public private(set) var nextBatch: BatchToken?

    private let messages: any TimelinePaging
    private var isPaginating = false
    /// Optional Megolm decryptor applied to loaded events
    /// (same contract as `SyncCryptoHooks.decryptRoomEvent`).
    private var decryptor:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?

    public init(roomId: RoomId, rootEventId: EventId, messages: any TimelinePaging) {
        self.roomId = roomId
        self.rootEventId = rootEventId
        self.messages = messages
        self.replies = []
    }

    /// Set the decryptor applied to loaded events.
    public func setDecryptor(
        _ decryptor:
            (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    ) {
        self.decryptor = decryptor
    }

    /// Load the root event and the first page of replies.
    ///
    /// Servers without single-event fetch fall back to a context window;
    /// servers without relations fall back to `localEvents` (typically the
    /// live window) filtered by thread root. Other errors propagate.
    public func load(limit: Int = 50, localEvents: [MessageEvent]? = nil) async throws(MatrixError) {
        let root: MessageEvent
        do {
            root = try await messages.event(roomId, rootEventId)
        } catch {
            let context = try await messages.context(roomId, eventId: rootEventId, limit: 1)
            guard let focus = context.event else { throw error }
            root = focus
        }
        self.root = await decrypted(root)
        do {
            let page = try await messages.relations(
                roomId, eventId: rootEventId, relType: RelationType.thread.rawValue,
                eventType: EventType.roomMessage.rawValue,
                from: nil, limit: limit, direction: .backward)
            // Relations arrive newest-first; the thread reads oldest-first.
            replies = await decrypted(page.chunk).reversed()
            nextBatch = page.nextBatch.map { BatchToken($0) }
        } catch let error {
            guard Self.isUnrecognized(error), let localEvents else { throw error }
            replies = await decrypted(localEvents.filter {
                $0.messageContent?.threadRootEventId == rootEventId
            })
            nextBatch = nil
        }
    }

    /// Whether an error is an unrecognized endpoint (`M_UNRECOGNIZED`).
    private static func isUnrecognized(_ error: MatrixError) -> Bool {
        guard case .serverError(let code, _, _) = error else { return false }
        return code == "M_UNRECOGNIZED"
    }

    /// Whether older replies may exist (`next_batch` known).
    public func canPaginateBack() -> Bool {
        nextBatch != nil
    }

    /// Whether a `loadMore` request is currently in flight.
    public func paginationInProgress() -> Bool {
        isPaginating
    }

    /// Load one page of older replies. Returns the number loaded.
    @discardableResult
    public func loadMore(limit: Int = 50) async throws(MatrixError) -> Int {
        guard !isPaginating, let from = nextBatch else { return 0 }
        isPaginating = true
        defer { isPaginating = false }
        let page = try await messages.relations(
            roomId, eventId: rootEventId, relType: RelationType.thread.rawValue,
            eventType: EventType.roomMessage.rawValue,
            from: from, limit: limit, direction: .backward)
        let known = Set(replies.map(\.eventId)).union(root.map { [$0.eventId] } ?? [])
        let chunk = await decrypted(page.chunk).reversed().filter { !known.contains($0.eventId) }
        replies.insert(contentsOf: chunk, at: 0)
        nextBatch = page.nextBatch.map { BatchToken($0) }
        return chunk.count
    }

    /// Root followed by replies, oldest first.
    public func events() -> [MessageEvent] {
        ((root.map { [$0] } ?? []) + replies).dedupedByEventId()
    }

    private func decrypted(_ event: MessageEvent) async -> MessageEvent {
        guard let decryptor else { return event }
        return await decryptor(event, roomId) ?? event
    }

    private func decrypted(_ events: [MessageEvent]) async -> [MessageEvent] {
        guard let decryptor else { return events }
        var out: [MessageEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            out.append(await decryptor(event, roomId) ?? event)
        }
        return out
    }
}

/// Narrow seam for timeline data: backwards pagination, event context,
/// single events, and relations (thread replies).
/// `MessageClient` conforms.
public protocol TimelinePaging: Actor {
    func paginate(
        _ roomId: RoomId,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent>
    func context(
        _ roomId: RoomId,
        eventId: EventId,
        limit: Int
    ) async throws(MatrixError) -> EventContext
    func event(
        _ roomId: RoomId,
        _ eventId: EventId
    ) async throws(MatrixError) -> MessageEvent
    func relations(
        _ roomId: RoomId,
        eventId: EventId,
        relType: String,
        eventType: String?,
        from: BatchToken?,
        limit: Int,
        direction: PaginationDirection
    ) async throws(MatrixError) -> RelationsResponse
}

extension MessageClient: TimelinePaging {}

extension TimelinePaging {
    /// Paginate backwards with the default page size.
    func paginate(
        _ roomId: RoomId, from: BatchToken?, limit: Int = 50
    ) async throws(MatrixError) -> PaginationChunk<MessageEvent> {
        try await paginate(
            roomId, from: from, limit: limit, direction: .backward)
    }
}
