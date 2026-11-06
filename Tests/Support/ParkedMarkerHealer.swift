import MatrixKit

/// Marker healer whose first `markersNeedingResolution()` call parks
/// until the test releases it. The sync consumer runs that call from
/// inside its delta loop (via `resolveReadMarkers`), so a parked first
/// call suspends the consumer mid-loop at a test-controlled point.
/// That lets a suite stop and restart sync while a superseded
/// generation's consumer is still unwinding — the shape of the
/// late-epilogue race the start/stop generation guards protect against.
public actor ParkedMarkerHealer: MarkerHealingStore {
    /// Waiters for the first `markersNeedingResolution()` call parking.
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
    /// The parked first call, resumed by `release()` with no markers.
    private var parkedCall:
        CheckedContinuation<[(roomId: RoomId, marker: EventId)], Never>?
    /// Further calls (e.g. from a restarted sync generation) return
    /// immediately so only the first call parks.
    private var isFirstCall = true

    public init() {}

    /// Resolve once the first resolution pass has parked.
    public func waitForFirstPark() async {
        guard isFirstCall else { return }
        await withCheckedContinuation { continuation in
            parkedWaiters.append(continuation)
        }
    }

    /// Resume the parked first call. No-op when it already resumed.
    public func release() {
        parkedCall?.resume(returning: [])
        parkedCall = nil
    }

    public func markersNeedingResolution() async throws -> [(roomId: RoomId, marker: EventId)] {
        guard isFirstCall else { return [] }
        isFirstCall = false
        return await withCheckedContinuation { continuation in
            parkedCall = continuation
            parkedWaiters.forEach { $0.resume() }
            parkedWaiters.removeAll()
        }
    }

    public func adoptResolvedMarkerTs(
        _ eventId: EventId, roomId: RoomId, ts: Int
    ) async throws {}
}
