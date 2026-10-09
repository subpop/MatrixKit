#if canImport(SwiftData)
import Foundation
import MatrixKit
import SwiftData

/// Container factory for the normalized store.
///
/// The store lives beside the legacy snapshot files under the same
/// per-user directory but with its own filename, so dual-run stages can
/// keep both. Corrupt/predating stores are wiped and reopened — a full
/// sync rebuilds them.
public enum MatrixStore {
    /// All normalized `@Model` types.
    public static var schema: Schema {
        Schema([
            SDStoreMeta.self,
            SDRoom.self,
            SDRoomMember.self,
            SDRoomEvent.self,
            SDRoomEdge.self,
            SDAccountData.self,
            SDRoomAccountData.self,
        ])
    }

    /// Open (creating) the store at `file`.
    public static func makeContainer(at file: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            return try open(file: file)
        } catch {
            removeStoreFiles(file: file)
            return try open(file: file)
        }
    }

    /// In-memory container for tests and previews.
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func open(file: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: file)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Delete the store file and its SQLite sidecars (`-wal`, `-shm`).
    public static func removeStoreFiles(file: URL) {
        let base = file.path
        for path in [base, base + "-wal", base + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Per-user store file under the user caches folder. Distinct filename
    /// from both legacy caches (`store.sqlite`, `store.swiftdata`).
    public static func databaseURL(for userId: UserId) -> URL? {
        guard let base = OIDCAccountStore.defaultDirectory() else { return nil }
        return databaseURL(for: userId, in: base)
    }

    /// Per-user store file under an explicit directory (e.g. a
    /// `ClientInstanceDirectory` root), keeping instances isolated.
    public static func databaseURL(for userId: UserId, in directory: URL) -> URL {
        directory
            .appendingPathComponent(
                ClientInstanceDirectory.safe(userId.value),
                isDirectory: true)
            .appendingPathComponent("matrix-store.swiftdata")
    }
}

// MARK: - Query helpers

/// Factory predicates so apps don't hand-write fragile `@Query` filters.
public extension SDRoom {
    /// Joined rooms, newest activity first.
    static func joinedDescriptor() -> FetchDescriptor<SDRoom> {
        FetchDescriptor<SDRoom>(
            predicate: #Predicate { $0.membership == "join" },
            sortBy: [SortDescriptor(\.latestMessageTs, order: .reverse)])
    }

    /// Pending invites, sorted by room ID.
    static func invitedDescriptor() -> FetchDescriptor<SDRoom> {
        FetchDescriptor<SDRoom>(
            predicate: #Predicate { $0.membership == "invite" },
            sortBy: [SortDescriptor(\.roomId)])
    }

    /// Joined spaces only.
    static func spacesDescriptor() -> FetchDescriptor<SDRoom> {
        FetchDescriptor<SDRoom>(
            predicate: #Predicate { $0.membership == "join" && $0.isSpace },
            sortBy: [SortDescriptor(\.latestMessageTs, order: .reverse)])
    }
}

public extension SDRoomEvent {
    /// Full timeline for a room, oldest first. Full history is kept;
    /// pass `fetchLimit` for a newest-window view.
    static func timelineDescriptor(
        roomId: String, fetchLimit: Int? = nil
    ) -> FetchDescriptor<SDRoomEvent> {
        var descriptor = FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.roomId == roomId },
            sortBy: [SortDescriptor(\.ts)])
        descriptor.fetchLimit = fetchLimit
        return descriptor
    }

    /// Message-like events for previews and unread estimates.
    static func messageLikeDescriptor(roomId: String) -> FetchDescriptor<SDRoomEvent> {
        FetchDescriptor<SDRoomEvent>(
            predicate: #Predicate { $0.roomId == roomId && $0.isMessageLike },
            sortBy: [SortDescriptor(\.ts)])
    }
}

public extension SDRoomMember {
    /// Members of a room, sorted by user ID.
    static func membersDescriptor(roomId: String) -> FetchDescriptor<SDRoomMember> {
        FetchDescriptor<SDRoomMember>(
            predicate: #Predicate { $0.roomId == roomId },
            sortBy: [SortDescriptor(\.userId)])
    }
}
#endif
