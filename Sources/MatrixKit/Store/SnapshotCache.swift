/// On-disk snapshot cache backend (SQLite, SwiftData, ...).
///
/// `StoreSnapshot` is the interchange format: any backend persists it and
/// recomposes it via `StateStore.restore(_:)`. Callers hold `any
/// SnapshotCache` and stay backend-agnostic.
public protocol SnapshotCache: Sendable {
    /// Atomically replace the stored snapshot.
    func save(_ snapshot: StoreSnapshot) async throws
    /// Stored snapshot, or nil when absent, unreadable, or versioned out.
    /// Implementations must never throw for a missing/foreign cache.
    func load() async throws -> StoreSnapshot?
    /// Delete the stored snapshot.
    func clear() async throws
}
