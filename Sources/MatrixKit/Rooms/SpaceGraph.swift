// Pure traversal over a parent-to-children space map. The map is the
// union of the child/parent edges any client knows (synced parent and
// child state, fetched hierarchy blobs). Pure so callers can drive the
// walks from any context and remain unit-testable; no fallbacks or
// network access here.

extension SpacesClient {
    // MARK: - Graph queries

    /// All room/space IDs contained in a space, transitively. Cycle-safe
    /// BFS over the parent-to-children map. Unjoined never-browsed
    /// branches are absent by construction: the map only contains IDs a
    /// client observed.
    public nonisolated static func descendantIds(
        of spaceId: RoomId, children: [RoomId: Set<RoomId>]
    ) -> Set<RoomId> {
        var seen: Set<RoomId> = [spaceId]
        var queue = [spaceId]
        var out = Set<RoomId>()
        while let current = queue.popLast() {
            for child in children[current] ?? [] where seen.insert(child).inserted {
                out.insert(child)
                queue.append(child)
            }
        }
        return out
    }

    /// The ancestor chain of a room, in breadcrumb order (`[topmost
    /// ancestor, …, direct parent]`, excluding the room itself), over
    /// the same parent-to-children map as ``descendantIds(of:children:)``.
    /// BFS upward so chains are shortest-first; cycle-safe (mutual
    /// child/parent edges yield a partial chain, loops yield `[]`).
    ///
    /// When multiple chains exist (a room can live under several
    /// spaces), the first ancestor found in `rootIds` wins — pass the
    /// reachable top-level spaces any UI context should prefer. With no
    /// rooted chain reachable, the shortest chain to any parentless
    /// ancestor is used, ties broken by ID order for determinism.
    public nonisolated static func ancestorPath(
        of roomId: RoomId, children: [RoomId: Set<RoomId>],
        rootedIn rootIds: Set<RoomId> = []
    ) -> [RoomId] {
        var parents: [RoomId: [RoomId]] = [:]
        for (parent, kids) in children {
            for kid in kids {
                parents[kid, default: []].append(parent)
            }
        }
        // Sorted so traversal decisions are deterministic across runs.
        parents = parents.mapValues { ids in ids.sorted { $0.value < $1.value } }
        // BFS upward: level by level, so the first match is also the
        // shortest chain.
        var visited: Set<RoomId> = [roomId]
        var queue: [(node: RoomId, path: [RoomId])] = [(roomId, [])]
        var index = 0
        var shortest: [RoomId]? = nil
        while index < queue.count {
            let (node, path) = queue[index]
            index += 1
            let chain = path + [node] // [roomId, …, node]
            if node != roomId {
                let ancestors = chain.dropFirst().reversed()
                if rootIds.contains(node) {
                    return Array(ancestors)
                }
                if shortest == nil, (parents[node] ?? []).isEmpty {
                    shortest = Array(ancestors)
                }
            }
            for parent in parents[node] ?? [] where visited.insert(parent).inserted {
                queue.append((parent, chain))
            }
        }
        return shortest ?? []
    }
}
