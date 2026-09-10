/// Observable room list: joined/invited rooms backed by the `StateStore`.
import Observation
@Observable @MainActor
public final class ObservableRoomList {
    /// Joined rooms, sorted by display name. Rebuilt by `refresh()`.
    public private(set) var joined: [ObservableRoom]
    /// Pending invites, sorted by display name.
    public private(set) var invited: [ObservableRoom]

    private weak var client: MatrixClient?

    init(client: MatrixClient) {
        self.client = client
        self.joined = []
        self.invited = []
    }

    /// Rebuild from the store (call after syncs or room changes).
    public func refresh() async {
        guard let client else { return }
        let joinedIds = await client.store.joinedRoomIds()
        let invitedIds = await client.store.invitedRoomIds()
        joined = await withTaskGroup(of: ObservableRoom.self) { group in
            for id in joinedIds {
                group.addTask { await client.room(id) }
            }
            var rooms: [ObservableRoom] = []
            for await room in group { rooms.append(room) }
            return rooms.sorted { $0.displayName < $1.displayName }
        }
        var invitedRooms: [ObservableRoom] = []
        for id in invitedIds {
            invitedRooms.append(await client.room(id))
        }
        invited = invitedRooms.sorted { $0.displayName < $1.displayName }
        completeSpaceGraph()
    }

    /// Complete child→parent edges across the whole set.
    ///
    /// `m.space.parent` is frequently absent server-side, so rooms would
    /// otherwise miss parents the spaces themselves declare. Resets every
    /// room to its actor-direct parents, unions the inversion of each
    /// space's children, then closes transitively so nested rooms belong
    /// to every ancestor (sidebar filtering matches on direct membership,
    /// which must include the transitive kind). Idempotent; converges as
    /// room refreshes flow. Cycles terminate: the sets only grow.
    private func completeSpaceGraph() {
        let all = joined + invited
        for room in all {
            room.parentSpaceIds = room.spaceParents
        }
        var byId: [RoomId: ObservableRoom] = [:]
        for room in all {
            byId[room.roomId] = room
        }
        for space in all where space.isSpace {
            for child in space.spaceChildren {
                byId[child]?.parentSpaceIds.insert(space.roomId)
            }
        }
        var changed = true
        while changed {
            changed = false
            for room in all {
                for parent in room.parentSpaceIds {
                    if let grandparents = byId[parent]?.parentSpaceIds {
                        let before = room.parentSpaceIds.count
                        room.parentSpaceIds.formUnion(grandparents)
                        if room.parentSpaceIds.count != before {
                            changed = true
                        }
                    }
                }
            }
        }
    }

    /// Total unread notifications across joined rooms.
    public var totalUnread: Int {
        joined.reduce(0) { $0 + $1.unreadCount }
    }

    /// Total highlighted notifications across joined rooms.
    public var totalHighlights: Int {
        joined.reduce(0) { $0 + $1.highlightCount }
    }
}
