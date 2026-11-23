import Foundation
import os

/// Sliding sync engine (MSC4186 simplified sliding sync): runs the
/// `POST` long-poll loop, parses responses, applies deltas to its
/// sinks, and yields them to subscribers.
///
/// Runs alongside `SyncClient`, not instead of it: rooms route through
/// `applySliding` (not `apply`), which leaves the v2 `syncToken`
/// untouched. The connection-scoped `pos` cursor lives here (in memory).
/// Accepts the same `SyncCryptoHooks` as `SyncClient` so one
/// `MatrixClient.configureEncryption()` call arms both engines.
public actor SlidingSyncClient {
    /// Default wire path (MSC4186 unstable prefix, as served by Synapse).
    /// Injectable via `init` so a stabilized path (or test double) can
    /// replace it.
    public static let defaultEndpointPath =
        "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"

    /// Default sliding window: first 20 rooms with name/avatar/topic/
    /// encryption/space-graph/image-pack state and 10 timeline events each.
    /// Nonisolated so any context can pass it to `start`.
    public static var defaultLists: [String: SlidingSyncList] {
        [
            "main": SlidingSyncList(
                ranges: [[0, 19]],
                requiredState: [
                    ["m.room.name", ""], ["m.room.avatar", ""],
                    ["m.room.topic", ""], ["m.room.encryption", ""],
                    ["m.space.child", "*"], ["m.space.parent", "*"],
                    [ImagePack.roomEventType, "*"],
                ],
                timelineLimit: 10)
        ]
    }

    private let transport: MatrixTransport
    private let session: Session
    private let endpointPath: String
    private var cryptoHooks: SyncCryptoHooks?
    /// The first sink is the authoritative store; its failure prevents
    /// acknowledging the response. Other sinks are best-effort observers.
    private var sinks: [any SyncDeltaSink] = []
    private var currentTask: Task<Void, Never>?
    private var connId = ""
    private var currentPos: String?
    private var requestInFlight = false
    private var generation = 0
    /// To-device stream position. Tracked separately from `pos`;
    /// only advances while E2EE extensions are enabled.
    private var toDeviceSince: String?
    private var lists: [String: SlidingSyncList] = [:]
    private var listCounts: [String: Int] = [:]
    private var subscriptions: [RoomId: SlidingSyncRoomSubscription] = [:]
    private var pendingUnsubscriptions: Set<RoomId> = []

    public init(
        transport: MatrixTransport,
        session: Session,
        sinks: [any SyncDeltaSink] = [],
        endpointPath: String = defaultEndpointPath
    ) {
        self.transport = transport
        self.session = session
        self.sinks = sinks
        self.endpointPath = endpointPath
    }

    /// Install the crypto hooks applied to every delta (see
    /// `SyncCryptoHooks`). Replaces any previous hooks.
    public func setCryptoHooks(_ hooks: SyncCryptoHooks?) {
        cryptoHooks = hooks
    }

    /// Register an extra delta consumer.
    public func addDeltaSink(_ sink: any SyncDeltaSink) {
        sinks.append(sink)
    }

    /// Drop all delta consumers.
    public func clearDeltaSinks() {
        sinks.removeAll()
    }

    /// Current connection's `pos`; a new connection starts without one.
    public var pos: String? { currentPos }

    /// Whether `start` has been called without a matching `stop`.
    public var isRunning: Bool { currentTask != nil }

    /// Start long-polling with the given lists and subscriptions. Each
    /// parsed + applied delta is yielded; the stream finishes when
    /// `stop()` is called or on fatal error.
    public func start(
        lists: [String: SlidingSyncList],
        subscriptions: [RoomId: SlidingSyncRoomSubscription] = [:],
        syncTimeoutMs: Int = 30_000
    ) async throws(MatrixError) -> AsyncStream<SyncDelta> {
        guard await session.isValid else { throw .notAuthenticated }
        stop()
        connId = UUID().uuidString
        currentPos = nil
        self.lists = lists
        listCounts.removeAll()
        self.subscriptions = subscriptions
        pendingUnsubscriptions.removeAll()
        MatrixKitLog.slidingSync.info(
            "Starting sliding sync (pos: \(self.currentPos ?? "<initial>", privacy: .public))"
        )

        let (stream, continuation) = AsyncStream<SyncDelta>.makeStream()
        currentTask = Task {
            defer { continuation.finish() }
            var backoffSeconds = 1
            while !Task.isCancelled {
                do {
                    let delta = try await self.requestOnce(timeoutMs: syncTimeoutMs)
                    backoffSeconds = 1
                    continuation.yield(delta)
                } catch let error as MatrixError {
                    if Task.isCancelled { break }
                    let isFatal: Bool
                    switch error {
                    case .unknownToken, .notAuthenticated:
                        isFatal = true
                    default:
                        isFatal = false
                    }
                    if isFatal {
                        MatrixKitLog.slidingSync.error("Sliding sync fatal: \(error, privacy: .public)")
                        break
                    }
                    MatrixKitLog.slidingSync.warning(
                        "Sliding sync error (\(error, privacy: .public)), retry in \(backoffSeconds, privacy: .public)s"
                    )
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                    backoffSeconds = min(backoffSeconds * 2, 30)
                } catch {
                    // Unreachable: transport only throws MatrixError.
                    MatrixKitLog.slidingSync.error(
                        "Unexpected sliding sync error: \(error, privacy: .public)")
                    break
                }
            }
        }
        return stream
    }

    /// Single sliding sync round-trip, applied to the store. Pass `lists` /
    /// `subscriptions` to replace the running configuration.
    @discardableResult
    public func syncOnce(
        lists: [String: SlidingSyncList]? = nil,
        subscriptions: [RoomId: SlidingSyncRoomSubscription]? = nil,
        syncTimeoutMs: Int = 30_000
    ) async throws(MatrixError) -> SyncDelta {
        guard await session.isValid else { throw .notAuthenticated }
        if let lists { self.lists = lists }
        if let subscriptions { self.subscriptions = subscriptions }
        return try await requestOnce(timeoutMs: syncTimeoutMs)
    }

    /// Subscribe to a room; takes effect on the next request.
    public func subscribe(
        _ roomId: RoomId,
        requiredState: [[String]]? = nil,
        timelineLimit: Int = 10
    ) {
        subscriptions[roomId] = SlidingSyncRoomSubscription(
            requiredState: requiredState, timelineLimit: timelineLimit)
        pendingUnsubscriptions.remove(roomId)
    }

    /// Drop a room subscription; takes effect on the next request.
    public func unsubscribe(_ roomId: RoomId) {
        subscriptions.removeValue(forKey: roomId)
        pendingUnsubscriptions.insert(roomId)
    }

    /// Stop the loop and finish the stream.
    public func stop() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Internals

    /// Build the next request body from the current `pos`, lists, and
    /// subscriptions. Internal for testability (no network involved).
    /// The typing (MSC4508) and account-data (MSC3959) extensions always
    /// ride along for v2 parity — latest-state semantics mean no cursor
    /// hazards. E2EE/to-device
    /// extensions ride along exactly when crypto hooks are installed:
    /// requesting to-device without a consumer would advance past
    /// messages the v3 loop would otherwise deliver.
    func makeRequest(timeoutMs: Int) -> SlidingSyncRequest {
        var extensions = SlidingSyncExtensions(
            typing: TypingExtension(), accountData: AccountDataExtension())
        if cryptoHooks != nil {
            extensions.e2ee = E2EEExtension()
            extensions.toDevice = ToDeviceExtension(limit: 100, since: toDeviceSince)
        }
        return SlidingSyncRequest(
            connId: connId.isEmpty ? nil : connId,
            pos: currentPos,
            timeoutMs: timeoutMs,
            lists: lists,
            roomSubscriptions: Dictionary(
                uniqueKeysWithValues: subscriptions.map { ($0.key.value, $0.value) }),
            unsubscribeRooms: pendingUnsubscriptions.map(\.value).sorted(),
            extensions: extensions
        )
    }

    /// True when the server expired the sliding connection (`M_UNKNOWN_POS`):
    /// the client must restart with a fresh `pos`.
    static func isUnknownPos(_ error: MatrixError) -> Bool {
        if case .serverError(let code, _, _) = error, code == "M_UNKNOWN_POS" {
            return true
        }
        return false
    }

    /// One serialized round-trip. A response is acknowledged only after
    /// the authoritative sink has successfully persisted it.
    private func requestOnce(timeoutMs: Int) async throws(MatrixError) -> SyncDelta {
        guard !requestInFlight else { throw .networkError("Sliding sync request already in flight") }
        requestInFlight = true
        defer { requestInFlight = false }
        if connId.isEmpty { connId = UUID().uuidString }
        let requestGeneration = generation
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let expanding = lists.contains { name, list in
            guard let end = list.ranges.first?.last else { return false }
            return end < (listCounts[name] ?? 0) - 1
        }
        let request = makeRequest(timeoutMs: expanding ? 0 : timeoutMs)
        MatrixKitLog.slidingSync.debug(
            "Request conn=\(self.connId, privacy: .private) pos=\(self.currentPos ?? "<initial>", privacy: .private) subscriptions=\(self.subscriptions.count)")
        let response: SlidingSyncResponse
        do {
            response = try await transport.send(
                .post, path: endpointPath, query: request.queryParameters,
                body: request, accessToken: token,
                timeoutSeconds: timeoutMs / 1000 + 30
            )
        } catch {
            if Self.isUnknownPos(error), requestGeneration == generation {
                currentPos = nil
                connId = UUID().uuidString
            }
            throw error
        }
        guard requestGeneration == generation, !Task.isCancelled else {
            throw .networkError("Sliding sync request cancelled")
        }
        MatrixKitLog.slidingSync.debug(
            "Response pos=\(response.pos, privacy: .private) rooms=\(response.rooms.count)")
        var delta = SlidingSyncResponseParser.parse(response)
        for (roomId, room) in delta.joined where room.timelineLimited {
            MatrixKitLog.slidingSync.debug(
                "Limited room=\(roomId.value, privacy: .private(mask: .hash)) events=\(room.timeline.count) prevBatch=\(room.prevBatch?.value ?? "<none>", privacy: .private)")
        }
        delta = await applySyncCryptoHooks(cryptoHooks, to: delta)
        guard requestGeneration == generation, !Task.isCancelled else {
            throw .networkError("Sliding sync request cancelled")
        }
        if let store = sinks.first {
            do {
                try await store.applySliding(delta)
            } catch {
                MatrixKitLog.slidingSync.error(
                    "Delta sink failed: \(error, privacy: .public)")
                throw .networkError("Sliding sync store apply failed: \(error.localizedDescription)")
            }
        }
        guard requestGeneration == generation, !Task.isCancelled else {
            throw .networkError("Sliding sync request cancelled")
        }
        currentPos = response.pos
        pendingUnsubscriptions.subtract(request.unsubscribeRooms?.map(RoomId.init(unchecked:)) ?? [])
        for (name, result) in response.lists {
            listCounts[name] = result.count
            guard var list = lists[name], let end = list.ranges.first?.last,
                end < result.count - 1
            else { continue }
            list.ranges = [[0, min(end + 80, result.count - 1)]]
            lists[name] = list
        }
        MatrixKitLog.slidingSync.debug("Applied pos=\(response.pos, privacy: .private)")
        if let batch = SlidingSyncResponseParser.toDeviceBatch(in: response.extensions) {
            toDeviceSince = batch
        }
        for sink in sinks.dropFirst() {
            do {
                try await sink.applySliding(delta)
            } catch {
                MatrixKitLog.slidingSync.error("Delta observer failed: \(error, privacy: .public)")
            }
        }
        return delta
    }
}

/// Run the crypto hooks over a parsed delta: to-device and device-list
/// side-effects plus timeline decryption. No hooks set — delta passes
/// through untouched. Shared by `SyncClient` and `SlidingSyncClient` so
/// both engines decrypt identically.
func applySyncCryptoHooks(_ hooks: SyncCryptoHooks?, to delta: SyncDelta) async -> SyncDelta {
    guard let hooks else { return delta }
    if let handleToDevice = hooks.handleToDevice, !delta.toDevice.isEmpty {
        await handleToDevice(delta.toDevice)
    }
    if let handleDeviceLists = hooks.handleDeviceLists,
        !delta.deviceChanged.isEmpty || !delta.deviceLeft.isEmpty
    {
        await handleDeviceLists(delta.deviceChanged, delta.deviceLeft)
    }
    if let handleKeyCounts = hooks.handleKeyCounts {
        await handleKeyCounts(delta.signedKeyCount)
    }
    guard let decrypt = hooks.decryptRoomEvent else { return delta }
    var delta = delta
    for (roomId, var joined) in delta.joined {
        var timeline: [MessageEvent] = []
        timeline.reserveCapacity(joined.timeline.count)
        for event in joined.timeline {
            timeline.append(await decrypt(event, roomId) ?? event)
        }
        joined.timeline = timeline
        delta.joined[roomId] = joined
    }
    return delta
}
