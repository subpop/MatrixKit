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
    public var fullyRead: String?
    public var firstUnreadEventId: String?
    public var memberCount: Int
    public var isSpace: Bool
    public var isDirect: Bool
    public var isFavourite: Bool
    public var isEncrypted: Bool
    public var canonicalAlias: String?
    public var successorRoomId: String?
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
            fullyRead: room.fullyRead,
            firstUnreadEventId: room.firstUnreadEventId,
            memberCount: members.count,
            isSpace: room.isSpace,
            isDirect: room.isDirect,
            isFavourite: room.isFavourite,
            isEncrypted: room.isEncrypted,
            canonicalAlias: room.canonicalAlias,
            successorRoomId: room.successorRoomId)
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

    /// Joined rooms flagged as spaces.
    public func spaceRoomIds() throws -> [RoomId] {
        let context = ModelContext(modelContainer)
        return try context.fetch(SDRoom.spacesDescriptor())
            .map { RoomId(unchecked: $0.roomId) }
    }

    // MARK: - Private

    /// Best-effort display name: explicit name, else other members'
    /// IDs, else the room ID.
    private static func displayName(
        room: SDRoom, members: [SDRoomMember], localUser: String?
    ) -> String {
        if let name = room.name, !name.isEmpty { return name }
        let others = members.map(\.userId).filter { $0 != localUser }
        if !others.isEmpty { return others.sorted().joined(separator: ", ") }
        return room.roomId
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
