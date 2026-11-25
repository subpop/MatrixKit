import os

/// Crypto side-effects applied to each parsed delta before it reaches
/// the sinks. Wired by `MatrixClient.configureEncryption()`; nil (the
/// default) leaves sync behavior unchanged.
public struct SyncCryptoHooks: Sendable {
    /// Consume raw to-device events (decrypt, route `m.room_key`).
    public var handleToDevice: (@Sendable ([BasicEvent]) async -> Void)?
    /// Decrypt one timeline event. Clear events pass through unchanged;
    /// return nil to keep undecryptable ciphertext as-is.
    public var decryptRoomEvent:
        (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)?
    /// Consume device-list deltas `(changed, left)`.
    public var handleDeviceLists:
        (@Sendable ([UserId], [UserId]) async -> Void)?
    /// Consume the server-reported `signed_curve25519` one-time-key
    /// count (nil when the sync carries none). Backs OTK pool refills.
    public var handleKeyCounts: (@Sendable (Int?) async -> Void)?

    public init(
        handleToDevice: (@Sendable ([BasicEvent]) async -> Void)? = nil,
        decryptRoomEvent: (@Sendable (MessageEvent, RoomId) async -> MessageEvent?)? = nil,
        handleDeviceLists: (@Sendable ([UserId], [UserId]) async -> Void)? = nil,
        handleKeyCounts: (@Sendable (Int?) async -> Void)? = nil
    ) {
        self.handleToDevice = handleToDevice
        self.decryptRoomEvent = decryptRoomEvent
        self.handleDeviceLists = handleDeviceLists
        self.handleKeyCounts = handleKeyCounts
    }
}

/// Sync engine: runs the long-poll loop, parses responses, applies deltas
/// to its sinks, and yields them to subscribers.
public actor SyncClient {
    private let connection: SyncConnection
    private let session: Session
    private var cryptoHooks: SyncCryptoHooks?
    /// Delta consumers; the first is the authoritative cursor-owning store.
    private var sinks: [any SyncDeltaSink]

    public init(
        connection: SyncConnection, session: Session,
        sinks: [any SyncDeltaSink] = []
    ) {
        self.connection = connection
        self.session = session
        self.sinks = sinks
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

    /// Start syncing. Each parsed + applied delta is yielded. The stream
    /// finishes when `stop()` is called or on fatal error.
    public func start(filter: SyncFilter? = nil) async throws(MatrixError) -> AsyncStream<SyncDelta> {
        guard await session.isValid else { throw .notAuthenticated }
        let since = await sinceToken()
        let filterJSON = try filter.map(SyncResponseParser.encodeFilter)
        MatrixKitLog.sync.info("Starting sync (since: \(since?.value ?? "<initial>", privacy: .public))")

        return await connection.stream(
            since: since, filterJSON: filterJSON,
            onError: { error in
                MatrixKitLog.sync.error("Sync terminated: \(error, privacy: .public)")
            },
            process: { [self] response in
                try await self.process(response)
            })
    }

    /// Single sync round-trip (initial sync / catch-up), applied to the sinks.
    @discardableResult
    public func syncOnce(filter: SyncFilter? = nil) async throws(MatrixError) -> SyncDelta {
        guard await session.isValid else { throw .notAuthenticated }
        let since = await sinceToken()
        let filterJSON = try filter.map(SyncResponseParser.encodeFilter)
        let response = try await connection.syncOnce(since: since, filterJSON: filterJSON)
        return try await process(response)
    }

    /// The first sink's cursor, or nil for a full sync.
    private func sinceToken() async -> BatchToken? {
        guard let first = sinks.first else { return nil }
        guard let token = try? await first.syncToken else { return nil }
        return token
    }

    private func process(_ response: SyncResponse) async throws(MatrixError) -> SyncDelta {
        var delta = SyncResponseParser.parse(response)
        delta = await applyCrypto(delta)
        try await fanOut(delta)
        return delta
    }

    /// Only acknowledge a delta after the cursor-owning store applies it.
    /// Failures in later observers do not block the authoritative cursor.
    private func fanOut(_ delta: SyncDelta) async throws(MatrixError) {
        if let store = sinks.first {
            do {
                try await store.apply(delta)
            } catch {
                MatrixKitLog.sync.error("Delta sink failed: \(error, privacy: .public)")
                throw .networkError("Sync store apply failed: \(error.localizedDescription)")
            }
        }
        for sink in sinks.dropFirst() {
            do {
                try await sink.apply(delta)
            } catch {
                MatrixKitLog.sync.error(
                    "Delta observer failed: \(error, privacy: .public)")
            }
        }
    }

    /// Run the crypto hooks over a parsed delta: to-device and
    /// device-list side-effects plus timeline decryption. No hooks set —
    /// delta passes through untouched.
    private func applyCrypto(_ delta: SyncDelta) async -> SyncDelta {
        await applySyncCryptoHooks(cryptoHooks, to: delta)
    }

    /// Stop the sync loop.
    public func stop() async {
        await connection.stop()
        MatrixKitLog.sync.info("Sync stopped")
    }

    /// Whether `start` has been called without a matching `stop`.
    public var isRunning: Bool {
        get async { await connection.isRunning }
    }
}
