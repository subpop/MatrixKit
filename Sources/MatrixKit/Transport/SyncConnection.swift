import Foundation
import os

/// Long-poll `GET /sync` loop yielding raw `SyncResponse` values.
///
/// Owns the `since` cursor and reconnects with exponential backoff on
/// transient failures. Non-retryable errors (bad token, ...) are forwarded
/// to `onError` and terminate the stream.
public actor SyncConnection {
    private let transport: MatrixTransport
    private let session: Session
    private var currentTask: Task<Void, Never>?

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
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
        stream(
            since: since, filterJSON: filterJSON,
            syncTimeoutMs: syncTimeoutMs, onError: onError,
            process: { $0 })
    }

    /// Process each response before advancing `since` or requesting another.
    /// A failed store write retries from the previous cursor with backoff.
    func stream<Output: Sendable>(
        since: BatchToken?,
        filterJSON: String? = nil,
        syncTimeoutMs: Int = 30_000,
        onError: (@Sendable (MatrixError) -> Void)? = nil,
        process: @escaping @Sendable (SyncResponse) async throws -> Output
    ) -> AsyncStream<Output> {
        stop()
        let transport = self.transport
        let session = self.session
        var cursor = since?.value
        var backoffSeconds = 1

        let (stream, continuation) = AsyncStream<Output>.makeStream()

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
                    if Task.isCancelled { break }
                    let output = try await process(response)
                    if Task.isCancelled { break }
                    cursor = response.nextBatch
                    backoffSeconds = 1
                    continuation.yield(output)
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
                        MatrixKitLog.syncConnection.error("Sync fatal: \(error, privacy: .public)")
                        onError?(error)
                        break
                    }
                    MatrixKitLog.syncConnection.warning(
                        "Sync error (\(error, privacy: .public)), retry in \(backoffSeconds, privacy: .public)s"
                    )
                    try? await Task.sleep(for: .seconds(backoffSeconds))
                    backoffSeconds = min(backoffSeconds * 2, 30)
                } catch {
                    // Transport and the SDK's store processor only throw MatrixError.
                    MatrixKitLog.syncConnection.error("Unexpected sync error: \(error, privacy: .public)")
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
