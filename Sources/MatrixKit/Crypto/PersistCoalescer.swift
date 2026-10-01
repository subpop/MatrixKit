import Foundation

/// Coalesces bursty persistence requests into debounced writes.
///
/// Crypto state mutates per message (each send/decrypt advances
/// ratchets), but `KeyStore` backends block the calling thread
/// (Keychain IPC). Persisting synchronously per mutation both hammers
/// the backend and parks cooperative-pool threads, starving unrelated
/// async work — sync loops, recovery flows — behind unrelated writes
/// (a fresh login's key-request storm once stalled the app this way).
/// The coalescer collapses each burst into one write after a short
/// quiet period.
///
/// Durability: at most `interval` of state advancement is lost on a
/// kill. Call `flush()` where that window is unacceptable (e.g. app
/// termination) and `cancel()` where the state is discarded anyway
/// (e.g. logout, which deletes right after — a scheduled flush must
/// never resurrect deleted entries).
actor PersistCoalescer {
    private let interval: Duration
    private let write: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    init(interval: Duration = .seconds(1), write: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.write = write
    }

    /// Record a mutation. Schedules a flush `interval` out unless one
    /// is already pending.
    func markDirty() {
        guard pending == nil else { return }
        pending = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    /// Write immediately, dropping any scheduled flush.
    func flush() async {
        pending?.cancel()
        pending = nil
        await write()
    }

    /// Drop a scheduled flush without writing.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func flushNow() async {
        pending = nil
        await write()
    }
}
