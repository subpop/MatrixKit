import Foundation

/// Typing state folded from sync ephemeral events.
///
/// The server sends the full typer list per room on every change, so
/// each `m.typing` event replaces the room's entry wholesale. The local
/// user is never listed to themselves. `update(from:)` reports which
/// rooms changed, letting callers wake only affected UI without
/// re-rendering on every delta.
public actor TypingTracker {
    private var typingByRoom: [RoomId: [UserId: Date]] = [:]
    private var localUser: UserId?
    private let expiry: TimeInterval

    /// - Parameters:
    ///   - localUser: This session's user ID, excluded from results.
    ///   - expiry: Age after which an entry reads as stale (the SDK's
    ///     typing `timeout` default).
    public init(localUser: UserId? = nil, expiry: TimeInterval = 30) {
        self.localUser = localUser
        self.expiry = expiry
    }

    /// Adopt the local user (receipt filtering).
    public func setLocalUser(_ userId: UserId?) {
        localUser = userId
    }

    /// Fold a sync delta's typing ephemeral, replacing each listed
    /// room's entry. Returns the touched room IDs (including rooms
    /// whose list emptied).
    @discardableResult
    public func update(from delta: SyncDelta) -> Set<RoomId> {
        let now = Date()
        var touched = Set<RoomId>()
        for (roomId, joined) in delta.joined {
            for event in joined.ephemeral where event.type == "m.typing" {
                let users = event.content["user_ids"]?.arrayValue?.compactMap {
                    $0.stringValue.map(UserId.init(unchecked:))
                } ?? []
                typingByRoom[roomId] = Dictionary(
                    uniqueKeysWithValues: users.filter { $0 != localUser }
                        .map { ($0, now) })
                touched.insert(roomId)
            }
        }
        return touched
    }

    /// Users currently typing in a room, with stale entries filtered.
    public func users(in roomId: RoomId) -> [UserId] {
        let cutoff = Date().addingTimeInterval(-expiry)
        return (typingByRoom[roomId] ?? [:])
            .filter { $0.value >= cutoff }
            .map(\.key)
    }
}
