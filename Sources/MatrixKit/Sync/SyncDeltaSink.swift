/// A consumer of parsed sync deltas.
///
/// Both engines fan parsed (and decrypted) deltas out in order. Sliding
/// sync requires the first (authoritative) sink to succeed before it
/// advances its connection cursor; later sinks are best-effort observers.
/// Classic sync reads the first sink's persisted cursor for replay.
public protocol SyncDeltaSink: Sendable {
    /// Cursor for the next incremental sync (`since`). The engines read
    /// the first sink's cursor; nil starts a full sync.
    var syncToken: BatchToken? { get async throws }
    /// Apply a v2 sync delta (advances the v2 cursor).
    func apply(_ delta: SyncDelta) async throws
    /// Apply a sliding-sync delta (leaves the v2 cursor untouched).
    func applySliding(_ delta: SyncDelta) async throws
}
