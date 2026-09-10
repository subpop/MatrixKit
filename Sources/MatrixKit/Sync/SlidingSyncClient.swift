import Foundation
import Logging

/// Sliding sync engine (MSC4186 simplified sliding sync): runs the
/// `POST` long-poll loop, parses responses, applies deltas to the store,
/// and yields them to subscribers.
///
/// Runs alongside `SyncClient`, not instead of it: it feeds rooms through
/// `StateStore.applySliding(_:)`, which routes per-room state without
/// touching the v2 `syncToken`. The `pos` cursor lives here (in memory).
/// Accepts the same `SyncCryptoHooks` as `SyncClient` so one
/// `MatrixClient.configureEncryption()` call arms both engines.
public actor SlidingSyncClient {
    /// Default wire path (MSC4186 unstable prefix, as served by Synapse).
    /// Injectable via `init` so a stabilized path (or test double) can
    /// replace it.
    public static let defaultEndpointPath = "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"

    /// Default sliding window: first 20 rooms with name/avatar/topic/
    /// encryption/space-graph state and 10 timeline events each.
    /// Nonisolated so any context can pass it to `start`.
    public static var defaultLists: [String: SlidingSyncList] {
        [
            "main": SlidingSyncList(
                ranges: [[0, 19]],
                requiredState: [
                    ["m.room.name", ""], ["m.room.avatar", ""],
                    ["m.room.topic", ""], ["m.room.encryption", ""],
                    ["m.space.child", "*"], ["m.space.parent", "*"],
                ],
                timelineLimit: 10)
        ]
    }

    private let transport: MatrixTransport
    private let session: Session
    private let store: StateStore
    private let logger: Logger
    private let endpointPath: String
    private var cryptoHooks: SyncCryptoHooks?
    private var currentTask: Task<Void, Never>?
    private var connId = ""
    private var currentPos: String?
    /// To-device stream position. Tracked separately from `pos`;
    /// only advances while E2EE extensions are enabled.
    private var toDeviceSince: String?
    private var lists: [String: SlidingSyncList] = [:]
    private var subscriptions: [RoomId: SlidingSyncRoomSubscription] = [:]

    public init(
        transport: MatrixTransport,
        session: Session,
        store: StateStore,
        endpointPath: String = defaultEndpointPath
    ) {
        self.transport = transport
        self.session = session
        self.store = store
        var logger = Logger(label: "MatrixKit.SlidingSyncClient")
        MatrixTransport.applyConfiguredLevel(to: &logger)
        self.logger = logger
        self.endpointPath = endpointPath
    }

    /// Install the crypto hooks applied to every delta (see
    /// `SyncCryptoHooks`). Replaces any previous hooks.
    public func setCryptoHooks(_ hooks: SyncCryptoHooks?) {
        cryptoHooks = hooks
    }

    /// Current `pos` cursor. Nil before the first successful response;
    /// resumes across `stop()`/`start()` until the process exits.
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
        self.lists = lists
        self.subscriptions = subscriptions
        logger.info("Starting sliding sync (pos: \(currentPos ?? "<initial>"))")

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
                    if error == .unknownToken || error == .notAuthenticated {
                        logger.error("Sliding sync fatal: \(error)")
                        break
                    }
                    logger.warning("Sliding sync error (\(error)), retry in \(backoffSeconds)s")
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                    backoffSeconds = min(backoffSeconds * 2, 30)
                } catch {
                    // Unreachable: transport only throws MatrixError.
                    logger.error("Unexpected sliding sync error: \(error)")
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
    }

    /// Drop a room subscription; takes effect on the next request.
    public func unsubscribe(_ roomId: RoomId) {
        subscriptions.removeValue(forKey: roomId)
    }

    /// Stop the loop and finish the stream.
    public func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Internals

    /// Build the next request body from the current `pos`, lists, and
    /// subscriptions. Internal for testability (no network involved).
    /// The typing extension (MSC4508) always rides along for v2 parity —
    /// latest-state semantics mean no cursor hazards. E2EE/to-device
    /// extensions ride along exactly when crypto hooks are installed:
    /// requesting to-device without a consumer would advance past
    /// messages the v3 loop would otherwise deliver.
    func makeRequest(timeoutMs: Int) -> SlidingSyncRequest {
        var extensions = SlidingSyncExtensions(typing: TypingExtension())
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

    /// One `POST` round-trip: send the current `pos`, advance it from the
    /// response, run crypto hooks, and apply to the store. On
    /// `M_UNKNOWN_POS` the cursor resets so the next request starts a
    /// fresh connection, then the error is rethrown.
    private func requestOnce(timeoutMs: Int) async throws(MatrixError) -> SyncDelta {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        let request = makeRequest(timeoutMs: timeoutMs)
        let response: SlidingSyncResponse
        do {
            response = try await transport.send(
                .post, path: endpointPath, body: request, accessToken: token,
                timeoutSeconds: timeoutMs / 1000 + 30
            )
        } catch {
            if Self.isUnknownPos(error) { currentPos = nil }
            throw error
        }
        currentPos = response.pos
        if let batch = SlidingSyncResponseParser.toDeviceBatch(in: response.extensions) {
            toDeviceSince = batch
        }
        var delta = SlidingSyncResponseParser.parse(response)
        delta = await applySyncCryptoHooks(cryptoHooks, to: delta)
        await store.applySliding(delta)
        logger.debug("Sent sliding sync")
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
