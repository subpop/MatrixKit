#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// A room-list row for non-SwiftUI consumers (the `mx` CLI, widgets,
/// notification extensions). SwiftUI views should `@Query` `SDRoom`
/// directly (see the `SDRoom` descriptor factories).
public struct StoredRoomEntry: Hashable, Sendable {
    public var roomId: RoomId
    public var displayName: String
    public var name: String?
    public var topic: String?
    public var avatarURL: String?
    public var membership: Membership
    public var unread: Int
    public var isSpace: Bool
    public var isDirect: Bool
    public var isFavourite: Bool

    public init(
        roomId: RoomId, displayName: String, name: String? = nil,
        topic: String? = nil, avatarURL: String? = nil,
        membership: Membership, unread: Int = 0,
        isSpace: Bool = false, isDirect: Bool = false,
        isFavourite: Bool = false
    ) {
        self.roomId = roomId
        self.displayName = displayName
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.membership = membership
        self.unread = unread
        self.isSpace = isSpace
        self.isDirect = isDirect
        self.isFavourite = isFavourite
    }
}

/// Full scalar detail for one room.
public struct StoredRoomDetail: Hashable, Sendable {
    public var roomId: RoomId
    public var displayName: String
    public var name: String?
    public var topic: String?
    public var avatarURL: String?
    public var membership: Membership
    public var unread: Int
    public var highlight: Int
    public var effectiveUnread: Int
    public var prevBatch: String?
    /// When set, `prevBatch` is unusable for back-pagination; resume
    /// before this event using `/context`. See `SDRoom.historyGapEventId`.
    public var historyGapEventId: String?
    public var timelineGaps: [StoredTimelineGap]
    public var fullyRead: String?
    public var firstUnreadEventId: String?
    public var memberCount: Int
    public var roomVersion: String?
    public var isSpace: Bool
    public var isDirect: Bool
    public var isFavourite: Bool
    public var isEncrypted: Bool
    public var canonicalAlias: String?
    public var successorRoomId: String?
    /// Pinned event IDs from `m.room.pinned_events` state.
    public var pinnedEventIds: [String]
}

/// A bounded timeline window and the room markers needed to render it.
public struct StoredTimelinePayload: Sendable {
    public var snapshot: [MessageEvent]
    public var sendStates: [EventId: SendState]
    public var firstUnreadEventId: String?
    public var prevBatch: String?
    public var historyGapEventId: String?
    public var timelineGaps: [StoredTimelineGap]
    public var hasOlderStoredEvents: Bool
    public var hasNewerStoredEvents: Bool

    public init(
        snapshot: [MessageEvent],
        sendStates: [EventId: SendState],
        firstUnreadEventId: String?,
        prevBatch: String?,
        historyGapEventId: String?,
        timelineGaps: [StoredTimelineGap] = [],
        hasOlderStoredEvents: Bool = false,
        hasNewerStoredEvents: Bool = false
    ) {
        self.snapshot = snapshot
        self.sendStates = sendStates
        self.firstUnreadEventId = firstUnreadEventId
        self.prevBatch = prevBatch
        self.historyGapEventId = historyGapEventId
        self.timelineGaps = timelineGaps
        self.hasOlderStoredEvents = hasOlderStoredEvents
        self.hasNewerStoredEvents = hasNewerStoredEvents
    }

    public static let empty = StoredTimelinePayload(
        snapshot: [], sendStates: [:],
        firstUnreadEventId: nil, prevBatch: nil, historyGapEventId: nil)
}

/// One membership row.
public struct StoredMember: Hashable, Sendable {
    public var userId: UserId
    public var displayname: String?
    public var membership: Membership
    public var avatarUrl: String?

    public init(
        userId: UserId, displayname: String? = nil,
        membership: Membership, avatarUrl: String? = nil
    ) {
        self.userId = userId
        self.displayname = displayname
        self.membership = membership
        self.avatarUrl = avatarUrl
    }
}

/// Fetch-based reads over the normalized store for consumers that
/// cannot use `@Query`. Each call opens a short-lived `ModelContext`,
/// so reads never block sync writes.
public struct MatrixStoreReader: Sendable {
    public let modelContainer: ModelContainer
    public var localUser: UserId?

    public init(modelContainer: ModelContainer, localUser: UserId? = nil) {
        self.modelContainer = modelContainer
        self.localUser = localUser
    }

    /// Stored sync cursors for incremental launch (`since` / `pos`).
    public func syncCursors() throws -> (
        syncToken: String?, slidingPos: String?, localUser: String?
    ) {
        let context = ModelContext(modelContainer)
        let meta = try context.fetch(FetchDescriptor<SDStoreMeta>()).first
        return (
            syncToken: meta?.syncToken, slidingPos: meta?.slidingPos,
            localUser: meta?.localUser)
    }

    /// Joined and invited rooms with display names, sorted by display
    /// name for room lists.
    public func roomEntries() throws -> (
        joined: [StoredRoomEntry], invited: [StoredRoomEntry]
    ) {
        let context = ModelContext(modelContainer)
        let rooms = try context.fetch(FetchDescriptor<SDRoom>())
        let members = try context.fetch(FetchDescriptor<SDRoomMember>())
        let byRoom = Dictionary(grouping: members, by: \.roomId)
        let meta = try context.fetch(FetchDescriptor<SDStoreMeta>()).first
        let localId = localUser?.value ?? meta?.localUser
        func entry(_ room: SDRoom) -> StoredRoomEntry {
            StoredRoomEntry(
                roomId: RoomId(unchecked: room.roomId),
                displayName: Self.displayName(
                    room: room,
                    members: byRoom[room.roomId] ?? [],
                    localUser: localId),
                name: room.name,
                topic: room.topic,
                avatarURL: room.avatarURL,
                membership: Membership(rawValue: room.membership) ?? .join,
                unread: room.unread,
                isSpace: room.isSpace,
                isDirect: room.isDirect,
                isFavourite: room.isFavourite)
        }
        let joined = rooms.filter { $0.membership == Membership.join.rawValue }
            .map(entry)
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
        let invited = rooms.filter { $0.membership == Membership.invite.rawValue }
            .map(entry)
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
        return (joined, invited)
    }

    /// Scalar detail for one room, or nil when unknown.
    public func roomDetail(_ roomId: RoomId) throws -> StoredRoomDetail? {
        let context = ModelContext(modelContainer)
        let id = roomId.value
        guard let room = try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        else { return nil }
        let members = try context.fetch(
            SDRoomMember.membersDescriptor(roomId: roomId.value))
        let meta = try context.fetch(FetchDescriptor<SDStoreMeta>()).first
        let localId = localUser?.value ?? meta?.localUser
        return StoredRoomDetail(
            roomId: roomId,
            displayName: Self.displayName(
                room: room, members: members, localUser: localId),
            name: room.name,
            topic: room.topic,
            avatarURL: room.avatarURL,
            membership: Membership(rawValue: room.membership) ?? .join,
            unread: room.unread,
            highlight: room.highlight,
            effectiveUnread: room.effectiveUnread,
            prevBatch: room.prevBatch,
            historyGapEventId: room.historyGapEventId,
            timelineGaps: Self.decodeGaps(room.timelineGaps),
            fullyRead: room.fullyRead,
            firstUnreadEventId: room.firstUnreadEventId,
            memberCount: members.count,
            roomVersion: room.roomVersion,
            isSpace: room.isSpace,
            isDirect: room.isDirect,
            isFavourite: room.isFavourite,
            isEncrypted: room.isEncrypted,
            canonicalAlias: room.canonicalAlias,
            successorRoomId: room.successorRoomId,
            pinnedEventIds: room.decodedPinnedEventIds())
    }

    /// Room timeline, oldest first. With `limit`, the newest window
    /// (newest `limit` events, oldest-first).
    public func timeline(
        _ roomId: RoomId, limit: Int? = nil
    ) throws -> [MessageEvent] {
        let context = ModelContext(modelContainer)
        let decoder = JSONDecoder()
        if let limit {
            let id = roomId.value
            var descriptor = FetchDescriptor<SDRoomEvent>(
                predicate: #Predicate { $0.roomId == id },
                sortBy: [SortDescriptor(\.ts, order: .reverse)])
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor).reversed().compactMap {
                try? Self.decodeEvent($0, decoder: decoder)
            }
        }
        return try context.fetch(
            SDRoomEvent.timelineDescriptor(roomId: roomId.value))
            .compactMap { try? Self.decodeEvent($0, decoder: decoder) }
    }

    /// The newest stored event window, oldest first, including delivery
    /// states and room markers. Uses its own short-lived context so this
    /// read does not queue behind room-index work.
    public func timelinePayload(
        _ roomId: RoomId, limit: Int
    ) throws -> StoredTimelinePayload {
        let context = ModelContext(modelContainer)
        let id = roomId.value
        var descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.roomId == id },
            sortBy: [
                SortDescriptor(\.ts, order: .reverse),
                SortDescriptor(\.eventId, order: .reverse),
            ])
        descriptor.fetchLimit = max(limit, 0) + 1
        let fetched = try context.fetch(descriptor)
        let rows = Array(fetched.prefix(max(limit, 0)).reversed())
        let room = try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        return Self.timelinePayload(
            rows: rows, room: room,
            hasOlderStoredEvents: fetched.count > max(limit, 0))
    }

    /// A bounded event window around a stored anchor, oldest first.
    /// Returns nil when the anchor is not present in the store.
    public func timelinePayloadAround(
        _ roomId: RoomId,
        anchorEventId: EventId,
        olderLimit: Int,
        newerLimit: Int
    ) throws -> StoredTimelinePayload? {
        let context = ModelContext(modelContainer)
        let id = roomId.value
        let anchorId = anchorEventId.value
        guard let anchor = try context.fetch(FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate {
                $0.roomId == id && $0.eventId == anchorId
            })).first
        else { return nil }

        let olderCount = max(olderLimit, 0)
        let newerCount = max(newerLimit, 0)
        let olderRows = try context.fetch(Self.olderRows(
            roomId: id, before: anchor, limit: olderCount + 1))
        let newerRows = try context.fetch(Self.newerRows(
            roomId: id, after: anchor, limit: newerCount + 1))
        let hasOlder = olderRows.count > olderCount
        let hasNewer = newerRows.count > newerCount
        var rows = Array(olderRows.prefix(olderCount).reversed())
        rows.append(anchor)
        rows.append(contentsOf: newerRows.prefix(newerCount))
        let room = try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        return Self.timelinePayload(
            rows: rows, room: room,
            hasOlderStoredEvents: hasOlder,
            hasNewerStoredEvents: hasNewer)
    }

    /// Room markers and history cursors without fetching timeline events.
    public func markerSummary(_ roomId: RoomId) throws -> (
        firstUnreadEventId: String?, prevBatch: String?, historyGapEventId: String?
    ) {
        let context = ModelContext(modelContainer)
        let id = roomId.value
        let room = try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        return (room?.firstUnreadEventId, room?.prevBatch, room?.historyGapEventId)
    }

    /// One stored event, or nil when it isn't in the store. Event IDs are
    /// unique, so no room is needed to resolve it.
    public func event(_ eventId: EventId) throws -> MessageEvent? {
        let id = eventId.value
        var descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.eventId == id })
        descriptor.fetchLimit = 1
        let context = ModelContext(modelContainer)
        return try context.fetch(descriptor).first.map {
            try Self.decodeEvent($0, decoder: JSONDecoder())
        }
    }

    /// One stored event as pretty-printed JSON with sorted keys, or nil
    /// when it isn't in the store. Rebuilt from the normalized row, so it
    /// matches the event's wire shape but isn't the server's exact bytes.
    public func eventJSON(_ eventId: EventId) throws -> Data? {
        guard let event = try event(eventId) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event)
    }

    /// One stored event with its latest replacement bundled under
    /// `unsigned.m.relations.m.replace`, as returned by event-source APIs.
    public func eventSourceJSON(_ eventId: EventId) throws -> Data? {
        guard var event = try event(eventId) else { return nil }
        if let roomId = event.roomId?.value,
            let replacement = try latestReplacement(of: eventId, in: roomId)
        {
            var unsigned = event.unsigned ?? [:]
            var relations = unsigned["m.relations"]?.objectValue ?? [:]
            let replacementData = try JSONEncoder().encode(replacement)
            relations["m.replace"] = .object(
                try JSONDecoder().decode([String: AnyCodable].self, from: replacementData))
            unsigned["m.relations"] = .object(relations)
            event.unsigned = unsigned
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event)
    }

    private func latestReplacement(
        of eventId: EventId, in roomId: String
    ) throws -> MessageEvent? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate {
                $0.roomId == roomId && $0.relType == "m.replace"
            },
            sortBy: [
                SortDescriptor(\.ts, order: .reverse),
                SortDescriptor(\.eventId, order: .reverse),
            ])
        for row in try context.fetch(descriptor) {
            guard let replacement = row.messageEvent(),
                replacement.relatesTo?.relType == .replacement,
                replacement.relatesTo?.eventId == eventId
            else { continue }
            return replacement
        }
        return nil
    }

    /// Search stored message text, newest first. Edit hits navigate to the
    /// original event and display the matched replacement body.
    public func searchMessages(
        term: String, roomId: RoomId? = nil
    ) throws -> [MessageSearchResult] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let context = ModelContext(modelContainer)
        let rows = try context.fetch(
            SDRoomEvent.searchDescriptor(term: query, roomId: roomId?.value))
        let rooms = try context.fetch(FetchDescriptor<SDRoom>())
        let members = try context.fetch(FetchDescriptor<SDRoomMember>())
        let membersByRoom = Dictionary(grouping: members, by: \.roomId)
        let roomById = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomId, $0) })
        let meta = try context.fetch(FetchDescriptor<SDStoreMeta>()).first
        let localId = localUser?.value ?? meta?.localUser

        var seenTargets = Set<String>()
        return rows.compactMap { row in
            let targetEventId = row.relType == "m.replace"
                ? row.threadRootId ?? row.eventId
                : row.eventId
            let targetKey = "\(row.roomId)|\(targetEventId)"
            guard seenTargets.insert(targetKey).inserted else { return nil }
            let roomMembers = membersByRoom[row.roomId] ?? []
            let roomName = roomById[row.roomId].map {
                Self.displayName(room: $0, members: roomMembers, localUser: localId)
            }
            let senderName = roomMembers.first { $0.userId == row.sender }?.displayname
            return MessageSearchResult(
                eventId: EventId(unchecked: targetEventId),
                roomId: RoomId(unchecked: row.roomId),
                roomName: roomName,
                sender: UserId(unchecked: row.sender),
                senderDisplayName: senderName,
                body: row.searchableText,
                timestamp: Date(timeIntervalSince1970: TimeInterval(row.ts) / 1000),
                highlights: [query])
        }
    }

    /// Room members, sorted by user ID.
    public func members(_ roomId: RoomId) throws -> [StoredMember] {
        let context = ModelContext(modelContainer)
        return try context.fetch(
            SDRoomMember.membersDescriptor(roomId: roomId.value))
            .map {
                StoredMember(
                    userId: UserId(unchecked: $0.userId),
                    displayname: $0.displayname,
                    membership: Membership(rawValue: $0.membership) ?? .join,
                    avatarUrl: $0.avatarUrl)
            }
    }

    /// Cached state summary for API-client enrichment
    /// (`RoomStateProvider`), or nil when the room is unknown.
    public func roomStateSummary(
        _ roomId: RoomId
    ) throws -> RoomStateSummary? {
        let context = ModelContext(modelContainer)
        let decoder = JSONDecoder()
        let id = roomId.value
        guard let room = try context.fetch(
            FetchDescriptor<SDRoom>(
                predicate: #Predicate { $0.roomId == id })).first
        else { return nil }
        let edges = try context.fetch(
            FetchDescriptor<SDRoomEdge>(
                predicate: #Predicate { $0.ownerRoomId == id }))
        return RoomStateSummary(
            membership: Membership(rawValue: room.membership),
            name: room.name,
            avatarURL: room.avatarURL,
            isSpace: room.isSpace,
            spaceChildren: Set(edges.compactMap {
                $0.kind == SDEdgeKind.child.rawValue
                    ? RoomId(unchecked: $0.peerRoomId) : nil
            }),
            powerLevels: try room.powerLevelsContent.map {
                try decoder.decode([String: AnyCodable].self, from: $0)
            },
            createEventSender: room.createEventSender.map(UserId.init(unchecked:)),
            createEventContent: try room.createEventContent.map {
                try decoder.decode([String: AnyCodable].self, from: $0)
            },
            hierarchyChildren: try room.hierarchyChildren.map {
                try decoder.decode([SpaceChild].self, from: $0)
            } ?? [],
            hierarchyDirectChildren: try room.hierarchyDirectChildren.map {
                try decoder.decode([SpaceChildEdge].self, from: $0)
            } ?? [])
    }

    /// Membership details for one user, if known.
    public func memberContent(
        roomId: RoomId, userId: UserId
    ) throws -> MemberContent? {
        let context = ModelContext(modelContainer)
        let key = "\(roomId.value)|\(userId.value)"
        guard let row = try context.fetch(
            FetchDescriptor<SDRoomMember>(
                predicate: #Predicate { $0.key == key })).first
        else { return nil }
        return MemberContent(
            membership: Membership(rawValue: row.membership) ?? .join,
            displayname: row.displayname,
            avatarUrl: row.avatarUrl,
            reason: row.reason,
            isDirect: row.isDirect)
    }

    /// The stored content of a global account-data entry, or nil when the
    /// account has none of that type.
    public func accountData(_ type: String) throws -> [String: AnyCodable]? {
        let context = ModelContext(modelContainer)
        guard let data = try context.fetch(
            FetchDescriptor<SDAccountData>(
                predicate: #Predicate { $0.type == type })).first?.content
        else { return nil }
        return try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    /// Maximum canonical-space ancestors followed when collecting packs.
    private static let maxImagePackSpaceDepth = 5

    /// Image packs available when interacting in `roomId`, in the spec's
    /// priority order: packs the user enabled globally, then the room's own,
    /// then those of its canonical space ancestors the user has joined. A
    /// pack reachable from several sources appears once, at its highest
    /// priority.
    public func imagePacks(for roomId: RoomId) throws -> [ImagePack] {
        let context = ModelContext(modelContainer)
        let decoder = JSONDecoder()
        var packs: [ImagePack] = []
        var seen: Set<String> = []

        func append(_ row: SDRoomImagePack, source: ImagePackSource) throws {
            guard seen.insert(row.key).inserted,
                let content = try? decoder.decode(ImagePackContent.self, from: row.content)
            else { return }
            let defining = row.roomId
            let definingRoom = try context.fetch(
                FetchDescriptor<SDRoom>(
                    predicate: #Predicate { $0.roomId == defining })).first
            packs.append(
                ImagePack(
                    roomId: RoomId(unchecked: row.roomId), stateKey: row.stateKey,
                    source: source, content: content,
                    displayName: content.pack?.displayName ?? definingRoom?.name,
                    avatarUrl: content.pack?.avatarUrl ?? definingRoom?.avatarURL))
        }

        func rows(in id: String) throws -> [SDRoomImagePack] {
            try context.fetch(
                FetchDescriptor<SDRoomImagePack>(
                    predicate: #Predicate { $0.roomId == id },
                    sortBy: [SortDescriptor(\.stateKey)]))
        }

        func isJoined(_ id: String) throws -> Bool {
            let joined = Membership.join.rawValue
            return try context.fetchCount(
                FetchDescriptor<SDRoom>(
                    predicate: #Predicate { $0.roomId == id && $0.membership == joined })) > 0
        }

        // The user's global packs. A room listed without state keys has no
        // defined meaning, and rooms the user has left expose no images.
        let accountType = ImagePack.userAccountDataType
        if let data = try context.fetch(
            FetchDescriptor<SDAccountData>(
                predicate: #Predicate { $0.type == accountType })).first?.content,
            let references = try? decoder.decode([String: AnyCodable].self, from: data)["rooms"]?.objectValue
        {
            for (referencedRoom, stateKeys) in references.sorted(by: { $0.key < $1.key }) {
                guard try isJoined(referencedRoom) else { continue }
                let wanted = Set((stateKeys.objectValue ?? [:]).keys)
                for row in try rows(in: referencedRoom) where wanted.contains(row.stateKey) {
                    try append(row, source: .user)
                }
            }
        }

        for row in try rows(in: roomId.value) {
            try append(row, source: .room)
        }

        // Canonical space ancestors, nearest first. The visited set guards
        // against cycles in the space graph.
        let canonical = SDEdgeKind.canonicalParent.rawValue
        var visited: Set<String> = [roomId.value]
        var frontier = [roomId.value]
        for _ in 0..<Self.maxImagePackSpaceDepth {
            var next: [String] = []
            for owner in frontier {
                let parents = try context.fetch(
                    FetchDescriptor<SDRoomEdge>(
                        predicate: #Predicate { $0.ownerRoomId == owner && $0.kind == canonical },
                        sortBy: [SortDescriptor(\.peerRoomId)]))
                for edge in parents where visited.insert(edge.peerRoomId).inserted {
                    guard try isJoined(edge.peerRoomId) else { continue }
                    for row in try rows(in: edge.peerRoomId) {
                        try append(row, source: .space)
                    }
                    next.append(edge.peerRoomId)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return packs
    }

    /// Joined rooms flagged as spaces.
    public func spaceRoomIds() throws -> [RoomId] {
        let context = ModelContext(modelContainer)
        return try context.fetch(SDRoom.spacesDescriptor())
            .map { RoomId(unchecked: $0.roomId) }
    }

    // MARK: - Room names

    /// Best-effort display name: explicit name, else other joined
    /// members' display names, else sync heroes, else the room ID.
    ///
    /// Public so app layers reuse the canonical fallback instead of
    /// reimplementing (and drifting from) it.
    public static func displayName(
        room: SDRoom, members: [SDRoomMember], localUser: String?
    ) -> String {
        if let name = room.name, !name.isEmpty { return name }
        let byId = Dictionary(grouping: members, by: \.userId)
        let others = members
            .filter { $0.userId != localUser && $0.membership == Membership.join.rawValue }
            .sorted {
                ($0.displayname ?? $0.userId) < ($1.displayname ?? $1.userId)
            }
            .prefix(3)
            .map { $0.displayname ?? $0.userId }
        if !others.isEmpty { return others.joined(separator: ", ") }
        let heroes = room.decodedHeroes()
            .filter { $0 != localUser }
            .prefix(3)
            .map { byId[$0]?.first?.displayname ?? $0 }
        if !heroes.isEmpty { return heroes.joined(separator: ", ") }
        return room.roomId
    }

    private static func timelinePayload(
        rows: [SDRoomEvent],
        room: SDRoom?,
        hasOlderStoredEvents: Bool = false,
        hasNewerStoredEvents: Bool = false
    ) -> StoredTimelinePayload {
        let decoder = JSONDecoder()
        var snapshot: [MessageEvent] = []
        snapshot.reserveCapacity(rows.count)
        var sendStates: [EventId: SendState] = [:]
        for row in rows {
            if let event = try? decodeEvent(row, decoder: decoder) {
                snapshot.append(event)
            }
            switch row.sendState {
            case "pending":
                sendStates[EventId(unchecked: row.eventId)] = .pending
            case "failed":
                sendStates[EventId(unchecked: row.eventId)] = .failed(
                    row.sendFailureReason ?? "Send failed")
            default:
                break
            }
        }
        return StoredTimelinePayload(
            snapshot: snapshot,
            sendStates: sendStates,
            firstUnreadEventId: room?.firstUnreadEventId,
            prevBatch: room?.prevBatch,
            historyGapEventId: room?.historyGapEventId,
            timelineGaps: Self.decodeGaps(room?.timelineGaps),
            hasOlderStoredEvents: hasOlderStoredEvents,
            hasNewerStoredEvents: hasNewerStoredEvents)
    }

    private static func decodeGaps(_ data: Data?) -> [StoredTimelineGap] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([StoredTimelineGap].self, from: data)) ?? []
    }

    private static func olderRows(
        roomId: String, before event: SDRoomEvent, limit: Int
    ) -> FetchDescriptor<SDRoomEvent> {
        let id = roomId
        let ts = event.ts
        let eventId = event.eventId
        var descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate {
                $0.roomId == id && ($0.ts < ts || ($0.ts == ts && $0.eventId < eventId))
            },
            sortBy: [
                SortDescriptor(\.ts, order: .reverse),
                SortDescriptor(\.eventId, order: .reverse),
            ])
        descriptor.fetchLimit = max(limit, 0)
        return descriptor
    }

    private static func newerRows(
        roomId: String, after event: SDRoomEvent, limit: Int
    ) -> FetchDescriptor<SDRoomEvent> {
        let id = roomId
        let ts = event.ts
        let eventId = event.eventId
        var descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate {
                $0.roomId == id && ($0.ts > ts || ($0.ts == ts && $0.eventId > eventId))
            },
            sortBy: [
                SortDescriptor(\.ts, order: .forward),
                SortDescriptor(\.eventId, order: .forward),
            ])
        descriptor.fetchLimit = max(limit, 0)
        return descriptor
    }

    private static func decodeEvent(
        _ row: SDRoomEvent, decoder: JSONDecoder
    ) throws -> MessageEvent {
        let content = try decoder.decode(
            [String: AnyCodable].self, from: row.content)
        let unsigned = try row.unsigned.map {
            try decoder.decode([String: AnyCodable].self, from: $0)
        }
        return MessageEvent(
            type: row.type,
            eventId: EventId(unchecked: row.eventId),
            sender: UserId(unchecked: row.sender),
            roomId: RoomId(unchecked: row.roomId),
            stateKey: row.stateKey,
            redacts: row.redacts.map(EventId.init(unchecked:)),
            originServerTs: row.ts,
            content: content,
            unsigned: unsigned)
    }
}
#endif
