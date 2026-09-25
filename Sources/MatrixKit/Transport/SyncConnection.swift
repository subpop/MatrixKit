import Foundation
import Logging

/// Long-poll `GET /sync` loop yielding raw `SyncResponse` values.
///
/// Owns the `since` cursor and reconnects with exponential backoff on
/// transient failures. Non-retryable errors (bad token, ...) are forwarded
/// to `onError` and terminate the stream.
public actor SyncConnection {
    private let transport: MatrixTransport
    private let session: Session
    private let logger: Logger
    private var currentTask: Task<Void, Never>?

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
        var logger = Logger(label: "MatrixKit.SyncConnection")
        MatrixTransport.applyConfiguredLevel(to: &logger)
        self.logger = logger
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    /// Start long-polling. Each successful response is yielded; the stream
    /// finishes when `stop()` is called or on fatal error.
    public func stream(
        since: BatchToken?,
        filterJSON: String? = nil,
        syncTimeoutMs: Int = 30_000,
        onError: (@Sendable (MatrixError) -> Void)? = nil
    ) -> AsyncStream<SyncResponse> {
        stop()
        let transport = self.transport
        let session = self.session
        let logger = self.logger
        var cursor = since?.value
        var backoffSeconds = 1

        let (stream, continuation) = AsyncStream<SyncResponse>.makeStream()

        currentTask = Task {
            defer { continuation.finish() }
            while !Task.isCancelled {
                var query: [String: String] = ["timeout": "\(syncTimeoutMs)"]
                if let cursor { query["since"] = cursor }
                if let filterJSON { query["filter"] = filterJSON }
                do {
                    let token = await session.accessToken
                    guard !token.isEmpty else { throw MatrixError.notAuthenticated }
                    let response: SyncResponse = try await transport.send(
                        .get, path: "/_matrix/client/v3/sync",
                        query: query,
                        accessToken: token,
                        timeoutSeconds: syncTimeoutMs / 1000 + 30
                    )
                    cursor = response.nextBatch
                    backoffSeconds = 1
                    continuation.yield(response)
                } catch let error as MatrixError {
                    if Task.isCancelled { break }
                    if error == .unknownToken || error == .notAuthenticated {
                        logger.error("Sync fatal: \(error)")
                        onError?(error)
                        break
                    }
                    logger.warning("Sync error (\(error)), retry in \(backoffSeconds)s")
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                    backoffSeconds = min(backoffSeconds * 2, 30)
                } catch {
                    // Unreachable: transport only throws MatrixError.
                    logger.error("Unexpected sync error: \(error)")
                    break
                }
            }
        }
        return stream
    }

    /// One-shot sync (initial sync or catch-up), no loop.
    public func syncOnce(
        since: BatchToken?,
        filterJSON: String? = nil,
        syncTimeoutMs: Int = 30_000
    ) async throws(MatrixError) -> SyncResponse {
        var query: [String: String] = ["timeout": "\(syncTimeoutMs)"]
        if let since { query["since"] = since.value }
        if let filterJSON { query["filter"] = filterJSON }
        return try await transport.send(
            .get, path: "/_matrix/client/v3/sync",
            query: query, accessToken: try await token(),
            timeoutSeconds: syncTimeoutMs / 1000 + 30
        )
    }

    /// Stop the loop and finish the stream.
    public func stop() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Whether the long-poll task is currently active.
    public var isRunning: Bool {
        currentTask != nil
    }
}
