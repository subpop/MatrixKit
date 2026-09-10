import Logging

/// Crypto side-effects applied to each parsed delta before it reaches
/// the store. Wired by `MatrixClient.configureEncryption()`; nil (the
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
/// to the store, and yields them to subscribers.
public actor SyncClient {
    private let connection: SyncConnection
    private let store: StateStore
    private let session: Session
    private let logger: Logger
    private var cryptoHooks: SyncCryptoHooks?

    public init(connection: SyncConnection, store: StateStore, session: Session) {
        self.connection = connection
        self.store = store
        self.session = session
        self.logger = Logger(label: "MatrixKit.SyncClient")
    }

    /// Install the crypto hooks applied to every delta (see
    /// `SyncCryptoHooks`). Replaces any previous hooks.
    public func setCryptoHooks(_ hooks: SyncCryptoHooks?) {
        cryptoHooks = hooks
    }

    /// Start syncing. Each parsed + applied delta is yielded. The stream
    /// finishes when `stop()` is called or on fatal error.
    public func start(filter: SyncFilter? = nil) async throws(MatrixError) -> AsyncStream<SyncDelta> {
        guard await session.isValid else { throw .notAuthenticated }
        let since = await store.syncToken
        let filterJSON = try filter.map(SyncResponseParser.encodeFilter)
        logger.info("Starting sync (since: \(since?.value ?? "<initial>"))")

        let rawStream = await connection.stream(since: since, filterJSON: filterJSON) { error in
            self.logger.error("Sync terminated: \(error)")
        }
        let store = self.store
        let (stream, continuation) = AsyncStream<SyncDelta>.makeStream()
        Task {
            for await response in rawStream {
                var delta = SyncResponseParser.parse(response)
                delta = await self.applyCrypto(delta)
                await store.apply(delta)
                continuation.yield(delta)
            }
            continuation.finish()
        }
        return stream
    }

    /// Single sync round-trip (initial sync / catch-up), applied to the store.
    @discardableResult
    public func syncOnce(filter: SyncFilter? = nil) async throws(MatrixError) -> SyncDelta {
        guard await session.isValid else { throw .notAuthenticated }
        let since = await store.syncToken
        let filterJSON = try filter.map(SyncResponseParser.encodeFilter)
        let response = try await connection.syncOnce(since: since, filterJSON: filterJSON)
        var delta = SyncResponseParser.parse(response)
        delta = await applyCrypto(delta)
        await store.apply(delta)
        return delta
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
        logger.info("Sync stopped")
    }

    /// Whether `start` has been called without a matching `stop`.
    public var isRunning: Bool {
        get async { await connection.isRunning }
    }
}
