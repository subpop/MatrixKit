#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// Whole-snapshot metadata (single row, `id == "meta"`).
@Model
final class CachedMeta {
    @Attribute(.unique) var id: String
    var version: Int
    var syncToken: String?
    var localUser: String?

    init(version: Int = SnapshotVersion.current) {
        self.id = "meta"
        self.version = version
    }
}

/// Account-data entry (one row per type, JSON content).
@Model
final class CachedAccountData {
    @Attribute(.unique) var type: String
    var content: Data

    init(type: String, content: Data) {
        self.type = type
        self.content = content
    }
}

/// Room scalars (one row per room).
@Model
final class CachedRoom {
    @Attribute(.unique) var roomId: String
    var name: String?
    var topic: String?
    var avatarURL: String?
    var membership: String
    var unread: Int = 0
    var highlight: Int = 0
    var prevBatch: String?
    var fullyRead: String?
    /// Client-side read-marker timestamp (ms since epoch), if known.
    /// Nil for snapshots written before this field existed.
    var readMarkerTs: Int?
    /// JSON-encoded effective notification mode, if hydrated.
    /// Nil for snapshots written before this field existed.
    var notificationMode: Data?
    var isSpace: Bool = false
    var isFavourite: Bool = false
    var isEncrypted: Bool = false
    var isDirect: Bool = false
    var canonicalAlias: String?
    var successorRoomId: String?
    /// JSON-encoded child room IDs (`m.space.child`).
    var spaceChildren: Data?
    /// JSON-encoded parent space IDs (`m.space.parent`).
    var spaceParents: Data?
    /// JSON-encoded canonical parent space IDs (`m.space.parent`,
    /// `canonical: true`).
    var canonicalParentIds: Data?
    /// JSON-encoded `m.room.power_levels` content.
    var powerLevelsContent: Data?
    /// JSON-encoded hero user IDs for the display-name fallback.
    var heroes: Data?
    /// JSON-encoded last-fetched hierarchy rows (`[SpaceChild]`), so a
    /// space's detail renders instantly. Nil for rows written before this
    /// field existed, or when no hierarchy was fetched yet.
    var hierarchyChildren: Data?
    /// JSON-encoded direct-child edges (`[SpaceChildEdge]`, ordering),
    /// persisted alongside the rows.
    var hierarchyDirectChildren: Data?
    /// Cursor for the next hierarchy page, if any.
    var hierarchyNextBatch: String?

    init(roomId: String, membership: String) {
        self.roomId = roomId
        self.membership = membership
    }
}

/// Room member (one row per room/user, JSON content).
@Model
final class CachedMember {
    var roomId: String
    var userId: String
    var content: Data

    init(roomId: String, userId: String, content: Data) {
        self.roomId = roomId
        self.userId = userId
        self.content = content
    }
}

/// Timeline event (one row per room/event, JSON payload).
@Model
final class CachedEvent {
    var roomId: String
    var eventId: String
    var ts: Int
    var payload: Data

    init(roomId: String, eventId: String, ts: Int, payload: Data) {
        self.roomId = roomId
        self.eventId = eventId
        self.ts = ts
        self.payload = payload
    }
}

/// `SnapshotCache` backend over SwiftData (Apple platforms only).
///
/// Same whole-snapshot replace semantics as `SQLiteCache`: `save` deletes
/// everything and re-inserts in one `save()`. Version mismatches wipe.
public actor SwiftDataCache: SnapshotCache {
    private let modelContainer: ModelContainer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// A fresh context per operation (contexts are not shared across calls).
    private func newContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    /// Open (creating) the store at `file`.
    public init(database file: URL) throws {
        // CoreData does not create intermediate directories: without this,
        // a first launch (or a new user) fails with ENOENT on the store path.
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            try self.init(modelContainer: Self.open(file: file))
        } catch {
            // The store predates the schema (or is corrupt): wipe it and
            // start over — a full sync rebuilds the cache, same as a
            // version-mismatched snapshot. Without this, a schema change
            // would leave the cache permanently unusable.
            Self.removeStoreFiles(file: file)
            try self.init(modelContainer: Self.open(file: file))
        }
    }

    private static func open(file: URL) throws -> ModelContainer {
        let schema = Schema([
            CachedMeta.self, CachedAccountData.self, CachedRoom.self,
            CachedMember.self, CachedEvent.self,
        ])
        let configuration = ModelConfiguration(schema: schema, url: file)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Delete the store file and its SQLite sidecars (`-wal`, `-shm`).
    private static func removeStoreFiles(file: URL) {
        let base = file.path
        for path in [base, base + "-wal", base + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Use an existing container (in-memory stores in tests, app groups, …).
    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Per-user store file under the user caches folder (coexists with the
    /// SQLite file — different filename). Nil when unavailable.
    public static func databaseURL(for userId: UserId) -> URL? {
        guard let base = OIDCAccountStore.defaultDirectory() else { return nil }
        let safe = userId.value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return base
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("store.swiftdata")
    }

    // MARK: - SnapshotCache

    public func save(_ snapshot: StoreSnapshot) throws {
        let context = newContext()
        try clear(context: context)
        let meta = CachedMeta()
        meta.syncToken = snapshot.syncToken?.value
        meta.localUser = snapshot.localUser?.value
        context.insert(meta)
        for (type, content) in snapshot.accountData {
            context.insert(
                CachedAccountData(
                    type: type,
                    content: try encoder.encode(content)))
        }
        for room in snapshot.rooms {
            let row = CachedRoom(
                roomId: room.roomId.value,
                membership: room.membership.rawValue)
            row.name = room.name
            row.topic = room.topic
            row.avatarURL = room.avatarURL?.value
            row.unread = room.unreadCount
            row.highlight = room.highlightCount
            row.prevBatch = room.prevBatch?.value
            row.fullyRead = room.fullyReadEventId?.value
            row.readMarkerTs = room.readMarkerTsMs
            row.notificationMode = room.notificationMode.flatMap { try? encoder.encode($0) }
            row.isSpace = room.isSpace
            row.isFavourite = room.isFavourite
            row.isEncrypted = room.isEncrypted
            row.isDirect = room.isDirect
            row.canonicalAlias = room.canonicalAlias
            row.successorRoomId = room.successorRoomId
            row.spaceChildren = try? encoder.encode(room.spaceChildren.map(\.value))
            row.spaceParents = try? encoder.encode(room.spaceParents.map(\.value))
            row.canonicalParentIds = try? encoder.encode(room.canonicalParentIds.map(\.value))
            row.powerLevelsContent = try? encoder.encode(room.powerLevelsContent)
            row.heroes = try? encoder.encode(room.heroes.map(\.value))
            row.hierarchyChildren = try? encoder.encode(room.hierarchyChildren)
            row.hierarchyDirectChildren = try? encoder.encode(room.hierarchyDirectChildren)
            row.hierarchyNextBatch = room.hierarchyNextBatch?.value
            context.insert(row)
            for (userId, content) in room.members {
                context.insert(
                    CachedMember(
                        roomId: room.roomId.value, userId: userId.value,
                        content: try encoder.encode(content)))
            }
            for event in room.timeline {
                context.insert(
                    CachedEvent(
                        roomId: room.roomId.value,
                        eventId: event.eventId.value,
                        ts: event.originServerTs,
                        payload: try encoder.encode(event)))
            }
        }
        try context.save()
    }

    public func load() -> StoreSnapshot? {
        let context = newContext()
        guard
            let meta = try? context.fetch(
                FetchDescriptor<CachedMeta>(
                    predicate: #Predicate { $0.id == "meta" })
            ).first,
            meta.version == SnapshotVersion.current
        else { return nil }
        var snapshot = StoreSnapshot()
        snapshot.syncToken = meta.syncToken.map { BatchToken($0) }
        snapshot.localUser = meta.localUser.map { UserId(unchecked: $0) }
        if let accountRows = try? context.fetch(FetchDescriptor<CachedAccountData>()) {
            for row in accountRows {
                if let content = try? decoder.decode(
                    [String: AnyCodable].self, from: row.content)
                {
                    snapshot.accountData[row.type] = content
                }
            }
        }
        guard let roomRows = try? context.fetch(FetchDescriptor<CachedRoom>()) else {
            return snapshot
        }
        let memberRows =
            (try? context.fetch(FetchDescriptor<CachedMember>())) ?? []
        let eventRows =
            (try? context.fetch(FetchDescriptor<CachedEvent>())) ?? []
        for row in roomRows {
            var room = RoomSnapshot(
                roomId: RoomId(unchecked: row.roomId),
                name: row.name,
                topic: row.topic,
                membership: Membership(rawValue: row.membership) ?? .join,
                unreadCount: row.unread,
                highlightCount: row.highlight,
                isEncrypted: row.isEncrypted,
                canonicalAlias: row.canonicalAlias,
                successorRoomId: row.successorRoomId,
                isSpace: row.isSpace,
                isDirect: row.isDirect,
                isFavourite: row.isFavourite)
            if let data = row.spaceChildren,
               let ids = try? decoder.decode([String].self, from: data) {
                room.spaceChildren = ids.map(RoomId.init(unchecked:))
            }
            if let data = row.spaceParents,
               let ids = try? decoder.decode([String].self, from: data) {
                room.spaceParents = ids.map(RoomId.init(unchecked:))
            }
            if let data = row.canonicalParentIds,
               let ids = try? decoder.decode([String].self, from: data) {
                room.canonicalParentIds = ids.map(RoomId.init(unchecked:))
            }
            if let data = row.powerLevelsContent,
               let content = try? decoder.decode([String: AnyCodable].self, from: data) {
                room.powerLevelsContent = content
            }
            if let data = row.heroes,
               let ids = try? decoder.decode([String].self, from: data) {
                room.heroes = ids.map(UserId.init(unchecked:))
            }
            if let data = row.hierarchyChildren,
               let children = try? decoder.decode([SpaceChild].self, from: data) {
                room.hierarchyChildren = children
            }
            if let data = row.hierarchyDirectChildren,
               let edges = try? decoder.decode([SpaceChildEdge].self, from: data) {
                room.hierarchyDirectChildren = edges
            }
            room.hierarchyNextBatch = row.hierarchyNextBatch.map { BatchToken($0) }
            room.avatarURL = row.avatarURL.flatMap { try? MXCURI($0) }
            room.prevBatch = row.prevBatch.map { BatchToken($0) }
            room.fullyReadEventId = row.fullyRead.map { EventId(unchecked: $0) }
            room.readMarkerTsMs = row.readMarkerTs
            if let data = row.notificationMode,
                let mode = try? decoder.decode(RoomNotificationMode.self, from: data)
            {
                room.notificationMode = mode
            }
            for member in memberRows where member.roomId == row.roomId {
                if let content = try? decoder.decode(
                    MemberContent.self, from: member.content)
                {
                    room.members[UserId(unchecked: member.userId)] = content
                }
            }
            let events = eventRows
                .filter { $0.roomId == row.roomId }
                .sorted { $0.ts < $1.ts }
                .compactMap {
                    try? decoder.decode(MessageEvent.self, from: $0.payload)
                }
            // Same newest-window trim as `RoomSnapshot.init`.
            room.timeline = Array(events.suffix(RoomSnapshot.maxTimelineEvents))
            snapshot.rooms.append(room)
        }
        return snapshot
    }

    public func clear() throws {
        let context = newContext()
        try clear(context: context)
        try context.save()
    }

    private func clear(context: ModelContext) throws {
        for type in [
            CachedEvent.self, CachedMember.self, CachedRoom.self,
            CachedAccountData.self, CachedMeta.self,
        ] as [any PersistentModel.Type] {
            try context.delete(model: type)
        }
    }
}
#endif
