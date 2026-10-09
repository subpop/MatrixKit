/// Out-of-window read-marker healing for the normalized store.
///
/// `MatrixClient.resolveReadMarkers` fetches each unresolved fully-read
/// marker once and adopts its timestamp. One network fetch serves the
/// room, wherever it is stored.
public protocol MarkerHealingStore: Sendable {
    /// Every room whose fully-read marker needs a single-event fetch:
    /// an ID is known but its event is absent from the store.
    func markersNeedingResolution() async throws -> [(roomId: RoomId, marker: EventId)]
    /// Adopt a fetched fully-read timestamp (max-only, stale-safe).
    func adoptResolvedMarkerTs(
        _ eventId: EventId, roomId: RoomId, ts: Int
    ) async throws
}

/// Ciphertext refresh for late-arriving Megolm keys.
///
/// Backup restores, room-key shares, and sessions persisted across
/// relaunch otherwise never refresh already-stored undecryptable
/// events, leaving "Unable to decrypt" placeholders stuck.
public protocol CiphertextStore: Sendable {
    /// IDs of all known rooms, regardless of membership.
    func knownRoomIds() async throws -> [RoomId]
    /// Stored events still ciphertext, as value types for a decryptor
    /// running outside the store.
    func encryptedEvents(roomId: RoomId) async throws -> [MessageEvent]
    /// Write back a decrypted event, matching the ciphertext row by ID.
    func replaceEvent(_ event: MessageEvent, roomId: RoomId) async throws
}
