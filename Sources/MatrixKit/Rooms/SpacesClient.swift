/// Space hierarchy, children management, and parent lookup.
public actor SpacesClient {
    private let transport: MatrixTransport
    private let session: Session
    private let roomState: RoomStateClient
    private let store: StateStore

    public init(transport: MatrixTransport, session: Session, store: StateStore) {
        self.transport = transport
        self.session = session
        self.roomState = RoomStateClient(transport: transport, session: session)
        self.store = store
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Hierarchy

    /// List a space's children (MSC2946), excluding the space itself.
    /// Returns one page plus the cursor for the next, if any, plus the
    /// current level's direct child IDs and edges (from the space's own
    /// entry) so callers can separate direct children from deeper
    /// descendants. `maxDepth` bounds recursion; once `from` is set it
    /// must stay fixed across pages.
    public func hierarchy(
        _ spaceId: RoomId, from: BatchToken? = nil, limit: Int = 100,
        suggestedOnly: Bool = false, maxDepth: Int? = nil
    ) async throws(MatrixError) -> (
        children: [SpaceChild], directChildIds: Set<RoomId>,
        directChildren: [SpaceChildEdge], nextBatch: BatchToken?
    ) {
        var query: [String: String] = ["limit": "\(limit)"]
        if let from { query["from"] = from.value }
        if suggestedOnly { query["suggested_only"] = "true" }
        if let maxDepth { query["max_depth"] = "\(maxDepth)" }
        let response: HierarchyResponse = try await transport.send(
            .get,
            path: "/_matrix/client/v1/rooms/\(spaceId.pathSegmentEncoded)/hierarchy",
            query: query,
            accessToken: try await token()
        )
        var children: [SpaceChild] = []
        var directChildIds = Set<RoomId>()
        var directChildren: [SpaceChildEdge] = []
        for dto in response.rooms {
            if dto.roomId == spaceId {
                directChildIds.formUnion(
                    (dto.childrenState ?? []).map { RoomId(unchecked: $0.stateKey) })
                directChildren = Self.mapEdges(dto.childrenState)
                continue
            }
            children.append(await makeChild(from: dto))
        }
        let nextBatch = response.nextBatch.map { BatchToken($0) }
        // Cache the page on the space's actor so the detail view's next
        // open renders from the on-disk snapshot. Fresh loads overwrite;
        // follow-up pages append to the stored rows. Edges update whenever
        // a page carries the space's own entry.
        if from == nil {
            await store.setHierarchy(
                children, directChildren: directChildren,
                nextBatch: nextBatch, for: spaceId)
        } else if let space = await store.existingRoom(spaceId) {
            await space.setHierarchy(
                children: space.hierarchyChildren + children,
                directChildren: directChildren.isEmpty
                    ? space.hierarchyDirectChildren : directChildren,
                nextBatch: nextBatch)
        }
        return (children, directChildIds, directChildren, nextBatch)
    }

    /// Map a hierarchy row, resolving local join state from the store.
    func makeChild(from dto: HierarchyRoom) async -> SpaceChild {
        let joined: Bool
        if let actor = await store.existingRoom(dto.roomId) {
            joined = await actor.membership == .join
        } else {
            joined = false
        }
        return Self.mapChild(from: dto, isJoined: joined)
    }

    /// Map a hierarchy row (pure; join state supplied by the caller).
    nonisolated static func mapChild(from dto: HierarchyRoom, isJoined: Bool) -> SpaceChild {
        SpaceChild(
            roomId: dto.roomId,
            name: dto.name,
            topic: dto.topic,
            avatarURL: dto.avatarURL.flatMap { try? MXCURI($0) },
            memberCount: dto.memberCount ?? 0,
            roomType: dto.roomType == "m.space" ? .space : .room,
            isJoined: isJoined,
            childrenCount: dto.childrenState?.count ?? 0,
            joinRule: SpaceChildJoinRule.parse(dto.joinRule),
            canonicalAlias: dto.canonicalAlias,
            childIds: (dto.childrenState ?? []).map { RoomId(unchecked: $0.stateKey) },
            worldReadable: dto.worldReadable,
            guestCanJoin: dto.guestCanJoin,
            allowedRoomIds: dto.allowedRoomIds ?? [],
            roomVersion: dto.roomVersion,
            encryption: dto.encryption,
            childEdges: mapEdges(dto.childrenState))
    }

    /// Map stripped child state into ordered-able edges, dropping edges
    /// whose content lacks `via` (spec: not part of the space).
    nonisolated static func mapEdges(_ state: [SpaceChildState]?) -> [SpaceChildEdge] {
        (state ?? []).compactMap { child in
            guard !child.content.via.isEmpty else { return nil }
            return SpaceChildEdge(
                roomId: RoomId(unchecked: child.stateKey),
                order: child.content.validOrder,
                via: child.content.via,
                suggested: child.content.suggested ?? false,
                originServerTs: child.originServerTs)
        }
    }

    /// Order a space's child edges per the spec: children with a valid
    /// `order` first (lexicographic by Unicode code points), the rest
    /// after by `origin_server_ts`, ties broken by room ID.
    public nonisolated static func orderedChildren(_ edges: [SpaceChildEdge]) -> [SpaceChildEdge] {
        edges.sorted { a, b in
            switch (a.order, b.order) {
            case let (aOrder?, bOrder?):
                if aOrder != bOrder { return codePointLessThan(aOrder, bOrder) }
            case (nil, _):
                return false
            case (_, nil):
                return true
            }
            let aTs = a.originServerTs ?? Int.max
            let bTs = b.originServerTs ?? Int.max
            if aTs != bTs { return aTs < bTs }
            return codePointLessThan(a.roomId.value, b.roomId.value)
        }
    }

    // MARK: - Children management

    /// Add a room or sub-space to a space (`m.space.child` state event).
    public func addChild(
        _ childId: RoomId, to spaceId: RoomId, via: [String] = [],
        order: String? = nil, suggested: Bool = false
    ) async throws(MatrixError) {
        var content: [String: AnyCodable] = ["via": .array(via.map(AnyCodable.string))]
        if let order { content["order"] = .string(order) }
        if suggested { content["suggested"] = .bool(true) }
        _ = try await roomState.sendStateEvent(
            spaceId, type: "m.space.child", stateKey: childId.value, content: content)
    }

    /// Remove a child from a space (empty `m.space.child` event).
    public func removeChild(_ childId: RoomId, from spaceId: RoomId) async throws(MatrixError) {
        _ = try await roomState.sendStateEvent(
            spaceId, type: "m.space.child", stateKey: childId.value, content: [:])
    }

    // MARK: - Parents

    /// Spaces a room belongs to, from its `m.space.parent` state.
    public func parents(of roomId: RoomId) async throws(MatrixError) -> Set<RoomId> {
        Self.parents(in: try await roomState.getState(roomId))
    }

    /// Parent space IDs in a state list (pure).
    nonisolated static func parents(in state: [MessageEvent]) -> Set<RoomId> {
        Set(state.compactMap { event in
            guard event.type == "m.space.parent" else { return nil }
            return RoomId(unchecked: event.stateKey ?? "")
        })
    }

    /// Declare `parentSpace` the parent of `child` (`m.space.parent` state
    /// event in the child room). The `via` servers route joins through the
    /// parent space's hierarchy.
    public func addParent(
        _ parentSpace: RoomId, of child: RoomId, via: [String] = [],
        canonical: Bool = false
    ) async throws(MatrixError) {
        var content: [String: AnyCodable] = ["via": .array(via.map(AnyCodable.string))]
        if canonical { content["canonical"] = .bool(true) }
        _ = try await roomState.sendStateEvent(
            child, type: "m.space.parent", stateKey: parentSpace.value, content: content)
    }

    /// Remove a space from a room's parents (empty `m.space.parent` event).
    public func removeParent(
        _ parentSpace: RoomId, from child: RoomId
    ) async throws(MatrixError) {
        _ = try await roomState.sendStateEvent(
            child, type: "m.space.parent", stateKey: parentSpace.value, content: [:])
    }

    /// Canonical parent IDs in a state list (pure).
    nonisolated static func canonicalParents(in state: [MessageEvent]) -> Set<RoomId> {
        Set(state.compactMap { event in
            guard
                event.type == "m.space.parent",
                event.content["canonical"]?.boolValue == true,
                let id = event.stateKey.map(RoomId.init(unchecked:))
            else { return nil }
            return id
        })
    }

    /// The canonical parent to use: the lowest room ID by Unicode code
    /// points, tiebreaking multiple canonical claims per the spec.
    nonisolated static func lowestCanonical(_ ids: Set<RoomId>) -> RoomId? {
        ids.min { codePointLessThan($0.value, $1.value) }
    }

    /// The room's canonical parent space, if one is declared.
    public func canonicalParent(of roomId: RoomId) async throws(MatrixError) -> RoomId? {
        Self.lowestCanonical(Self.canonicalParents(in: try await roomState.getState(roomId)))
    }

    /// Parent spaces whose claim is credible: either a matching
    /// `m.space.child` exists in the parent space, or the sender of the
    /// `m.space.parent` event may manage children there. Parents that
    /// cannot be inspected are dropped (spec: assumed invalid).
    public func validatedParents(of roomId: RoomId) async throws(MatrixError) -> Set<RoomId> {
        let state = try await roomState.getState(roomId)
        var result = Set<RoomId>()
        for event in state where event.type == "m.space.parent" {
            guard let parent = event.stateKey.map(RoomId.init(unchecked:)) else { continue }
            let sender = event.sender
            var childIds = Set<RoomId>()
            var isSpace = false
            var powerLevels: [String: AnyCodable]?
            if let known = await store.existingRoom(parent) {
                childIds = await known.spaceChildren
                isSpace = await known.isSpace
            }
            if !isSpace || !childIds.contains(roomId) {
                do {
                    let parentState = try await roomState.getState(parent)
                    isSpace = parentState.first { $0.type == "m.room.create" }?
                        .content["type"]?.stringValue == "m.space"
                    childIds = Set(parentState.compactMap {
                        guard
                            $0.type == "m.space.child",
                            let id = $0.stateKey.map(RoomId.init(unchecked:))
                        else { return nil }
                        return id
                    })
                    powerLevels = parentState.first { $0.type == "m.room.power_levels" }?.content
                } catch {
                    continue
                }
            }
            if Self.isValidParent(
                roomId: roomId,
                sender: sender,
                parentSpaceId: parent,
                knownChildIds: childIds,
                knownIsSpace: isSpace,
                knownPowerLevels: powerLevels) {
                result.insert(parent)
            }
        }
        return result
    }

    /// Whether a room's claim of parentage holds (pure): the parent space
    /// is a space and either lists the room as a child, or `sender` may
    /// send `m.space.child` there.
    nonisolated static func isValidParent(
        roomId: RoomId,
        sender: UserId,
        parentSpaceId: RoomId,
        knownChildIds: Set<RoomId>,
        knownIsSpace: Bool,
        knownPowerLevels: [String: AnyCodable]?
    ) -> Bool {
        guard knownIsSpace else { return false }
        if knownChildIds.contains(roomId) { return true }
        guard let knownPowerLevels else { return false }
        return canManageChildren(powerLevels: knownPowerLevels, userId: sender)
    }

    // MARK: - Editable spaces

    /// Joined spaces where the local user may add or remove children
    /// (power level suffices for `m.space.child` state events).
    public func editableSpaces() async throws(MatrixError) -> [EditableSpace] {
        let userId = await session.userId
        var result: [EditableSpace] = []
        for spaceId in await store.spaceRoomIds() {
            let actor = await store.room(spaceId)
            // Prefer the persisted power levels (disk-backed snapshot) —
            // `canManageChildren` then needs no per-space `getState` network
            // fan-out. Fall back to the network only when power levels have
            // never been captured (e.g. a freshly-joined space pre-sync).
            let content: [String: AnyCodable]?
            if let persisted = await actor.powerLevelsContent {
                content = persisted
            } else {
                let state = try await roomState.getState(spaceId)
                content = state.first(where: { $0.type == "m.room.power_levels" })?.content
            }
            guard
                let content,
                Self.canManageChildren(powerLevels: content, userId: userId)
            else { continue }
            result.append(EditableSpace(
                roomId: spaceId,
                name: await actor.name,
                avatarURL: await actor.avatarURL))
        }
        return result
    }

    /// Whether `userId` may send `m.space.child` under these power levels:
    /// own level meets the `m.space.child` event threshold (or
    /// `state_default`, default 50).
    nonisolated static func canManageChildren(
        powerLevels: [String: AnyCodable], userId: UserId
    ) -> Bool {
        let users = powerLevels["users"]?.objectValue ?? [:]
        let level = users[userId.value]?.intValue
            ?? powerLevels["users_default"]?.intValue ?? 0
        let required = powerLevels["events"]?.objectValue?["m.space.child"]?.intValue
            ?? powerLevels["state_default"]?.intValue ?? 50
        return level >= required
    }

    // MARK: - Leave

    /// Joined children of a space with last-owner warnings, for the
    /// leave-space confirmation UI. Pages the full hierarchy.
    public func leaveCandidates(spaceId: RoomId) async throws(MatrixError) -> [LeaveSpaceChild] {
        let userId = await session.userId
        var children: [SpaceChild] = []
        var from: BatchToken?
        repeat {
            let page = try await hierarchy(spaceId, from: from)
            children += page.children
            from = page.nextBatch
        } while from != nil
        var result: [LeaveSpaceChild] = []
        for child in children where child.isJoined {
            let state = try await roomState.getState(child.roomId)
            let power = state.first { $0.type == "m.room.power_levels" }?.content
            let owners = power?["users"]?.objectValue?.filter {
                $0.value.intValue ?? 0 >= 100
            }.map(\.key) ?? []
            result.append(LeaveSpaceChild(
                roomId: child.roomId,
                name: child.name,
                avatarURL: child.avatarURL,
                isLastOwner: owners == [userId.value],
                memberCount: child.memberCount,
                isSpace: child.roomType == .space))
        }
        return result
    }
}
