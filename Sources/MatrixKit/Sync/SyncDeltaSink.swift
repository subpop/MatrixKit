/// A consumer of parsed sync deltas.
///
/// Both sync engines fan every parsed (and decrypted) delta out to
/// their sinks in order. Sink failures are logged and never break
/// sync: the next batch replays from the first sink's cursor, and the
/// writer dedupes, so delivery is at-least-once.
public protocol SyncDeltaSink: Sendable {
    /// Cursor for the next incremental sync (`since`). The engines read
    /// the first sink's cursor; nil starts a full sync.
    var syncToken: BatchToken? { get async throws }
    /// Apply a v2 sync delta (advances the v2 cursor).
    func apply(_ delta: SyncDelta) async throws
    /// Apply a sliding-sync delta (leaves the v2 cursor untouched).
    func applySliding(_ delta: SyncDelta) async throws
}
