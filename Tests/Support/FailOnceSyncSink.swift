import MatrixKit

/// A cursor-owning store that rejects its first classic sync delta.
public actor FailOnceSyncSink: SyncDeltaSink {
    public private(set) var syncToken: BatchToken?
    public private(set) var applyCount = 0

    public init() {}

    public func apply(_ delta: SyncDelta) throws {
        applyCount += 1
        if applyCount == 1 {
            throw MatrixError.networkError("test store failure")
        }
        syncToken = delta.nextBatch
    }

    public func applySliding(_ delta: SyncDelta) throws {}
}
