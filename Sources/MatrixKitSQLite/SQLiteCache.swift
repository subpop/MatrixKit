/// SQLite-backed cache for `StoreSnapshot`, replacing the JSON file cache.
///
/// Same interchange format (`StoreSnapshot`), same two operations
/// (`save`/`load`) — but partial-friendly: rooms, members, events, and
/// account data live in separate tables, so future readers can query
/// history windows without loading the whole snapshot.
///
/// Design notes:
/// - The schema stores scalar columns for querying plus full JSON payloads
///   for recomposition, so model changes rarely require migrations.
/// - Calls block the calling thread on SQLite I/O; the actor serializes
///   access. Fine for CLI scale; a high-throughput app would move I/O
///   off the cooperative pool.
/// - Never stores access tokens (session stays in memory) — same rule as
///   the cache it replaces.
import CSQLite
import Foundation
import MatrixKit

/// A SQLite failure (message from `sqlite3_errmsg`).
public struct SQLiteError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The `sqlite3_errmsg` text for the failed call.
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { "SQLite error: \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Owns the raw handle; closing in `deinit` (the actor can't touch
/// isolated state from its own `deinit`). All use is actor-serialized.
private final class DatabaseHandle: @unchecked Sendable {
    let db: OpaquePointer

    init(_ db: OpaquePointer) {
        self.db = db
    }

    deinit {
        sqlite3_close_v2(db)
    }
}

public actor SQLiteCache: SnapshotCache {
    private let handle: DatabaseHandle
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Setup

    /// Open (creating) the database at `file`, migrating/wiping on
    /// schema mismatch.
    public init(database file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw SQLiteError("Could not open \(file.path)")
        }
        let handle = DatabaseHandle(db)
        self.handle = handle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        try Self.exec(handle, "PRAGMA journal_mode=WAL;")
        try Self.exec(handle, "PRAGMA synchronous=NORMAL;")
        try Self.exec(handle, "PRAGMA busy_timeout=5000;")
        try Self.migrate(handle)
    }

    /// Per-user database file under the user caches folder.
    /// Returns nil when the caches directory is unavailable.
    public static func databaseURL(for userId: UserId) -> URL? {
        guard let base = OIDCAccountStore.defaultDirectory() else { return nil }
        let safe = userId.value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return base
            .appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("store.sqlite")
    }

    // MARK: - Save / load

    /// Atomically replace the cached snapshot (single transaction).
    public func save(_ snapshot: StoreSnapshot) throws {
        try Self.exec(handle, "BEGIN IMMEDIATE;")
        do {
            for table in ["events", "members", "rooms", "account_data", "kv"] {
                try Self.exec(handle, "DELETE FROM \(table);")
            }
            try Self.exec(
                handle,
                "INSERT INTO kv(key, value) VALUES ('schema_version', '\(SnapshotVersion.current)');"
            )
            if let token = snapshot.syncToken {
                try setKV("sync_token", token.value)
            }
            if let localUser = snapshot.localUser {
                try setKV("local_user", localUser.value)
            }
            for (type, content) in snapshot.accountData {
                try insertAccountData(
                    type: type, json: String(data: try encoder.encode(content), encoding: .utf8) ?? "{}")
            }
            for room in snapshot.rooms {
                try insertRoom(room)
            }
            try Self.exec(handle, "COMMIT;")
        } catch {
            try? Self.exec(handle, "ROLLBACK;")
            throw error
        }
    }

    /// Read the snapshot, or nil when absent, unreadable, undecodable,
    /// or from a different schema version (which is wiped).
    public func load() -> StoreSnapshot? {
        do {
            guard try Self.queryScalar(handle, "SELECT value FROM kv WHERE key='schema_version';")
                == "\(SnapshotVersion.current)"
            else {
                try clear()
                return nil
            }
            let token = try Self.queryScalar(handle, "SELECT value FROM kv WHERE key='sync_token';")
                .map { BatchToken($0) }
            let localUser = try Self.queryScalar(
                handle, "SELECT value FROM kv WHERE key='local_user';"
            ).map(UserId.init(unchecked:))
            var accountData: [String: [String: AnyCodable]] = [:]
            for row in try Self.query(handle, "SELECT type, content FROM account_data;") {
                if let content = decodeJSON([String: AnyCodable].self, row[1]) {
                    accountData[row[0]] = content
                }
            }
            var rooms: [RoomSnapshot] = []
            for row in try Self.query(
                handle,
                "SELECT room_id, name, topic, avatar_url, membership, unread, highlight, prev_batch, fully_read FROM rooms;"
            ) {
                let roomId = RoomId(unchecked: row[0])
                rooms.append(
                    RoomSnapshot(
                        roomId: roomId,
                        name: row[1].isEmpty ? nil : row[1],
                        topic: row[2].isEmpty ? nil : row[2],
                        avatarURL: row[3].isEmpty ? nil : MXCURI(unchecked: row[3]),
                        membership: Membership(rawValue: row[4]) ?? .join,
                        members: loadMembers(roomId),
                        timeline: loadEvents(roomId),
                        unreadCount: Int(row[5]) ?? 0,
                        highlightCount: Int(row[6]) ?? 0,
                        prevBatch: row[7].isEmpty ? nil : BatchToken(row[7]),
                        fullyReadEventId: row[8].isEmpty ? nil : EventId(unchecked: row[8])
                    ))
            }
            return StoreSnapshot(
                syncToken: token,
                localUser: localUser,
                accountData: accountData,
                rooms: rooms
            )
        } catch {
            return nil
        }
    }

    /// Delete all cached rows (schema reset, explicit sign-out, ...).
    public func clear() throws {
        for table in ["events", "members", "rooms", "account_data", "kv"] {
            try Self.exec(handle, "DELETE FROM \(table);")
        }
    }

    // MARK: - Reads

    private func loadMembers(_ roomId: RoomId) -> [UserId: MemberContent] {
        var members: [UserId: MemberContent] = [:]
        guard
            let rows = try? Self.query(
                handle,
                "SELECT user_id, content FROM members WHERE room_id=?;",
                bind: [roomId.value]
            )
        else { return members }
        for row in rows {
            if let content = decodeJSON(MemberContent.self, row[1]) {
                members[UserId(unchecked: row[0])] = content
            }
        }
        return members
    }

    private func loadEvents(_ roomId: RoomId) -> [MessageEvent] {
        guard
            let rows = try? Self.query(
                handle,
                "SELECT payload FROM events WHERE room_id=? ORDER BY ts ASC;",
                bind: [roomId.value]
            )
        else { return [] }
        return rows.compactMap { decodeJSON(MessageEvent.self, $0[0]) }
    }

    // MARK: - Writes

    private func setKV(_ key: String, _ value: String) throws {
        try Self.execute(
            handle, "INSERT INTO kv(key, value) VALUES (?, ?);", bind: [key, value])
    }

    private func insertAccountData(type: String, json: String) throws {
        try Self.execute(
            handle, "INSERT INTO account_data(type, content) VALUES (?, ?);",
            bind: [type, json])
    }

    private func insertRoom(_ room: RoomSnapshot) throws {
        try Self.execute(
            handle,
            """
            INSERT INTO rooms(room_id, name, topic, avatar_url, membership, unread, highlight, prev_batch, fully_read)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                room.roomId.value,
                room.name ?? "",
                room.topic ?? "",
                room.avatarURL?.value ?? "",
                room.membership.rawValue,
                "\(room.unreadCount)",
                "\(room.highlightCount)",
                room.prevBatch?.value ?? "",
                room.fullyReadEventId?.value ?? "",
            ]
        )
        for (userId, content) in room.members {
            let json = String(data: try encoder.encode(content), encoding: .utf8) ?? "{}"
            try Self.execute(
                handle,
                "INSERT INTO members(room_id, user_id, membership, content) VALUES (?, ?, ?, ?);",
                bind: [room.roomId.value, userId.value, content.membership.rawValue, json]
            )
        }
        for event in room.timeline {
            guard
                let data = try? encoder.encode(event),
                let json = String(data: data, encoding: .utf8)
            else {
                continue
            }
            try Self.execute(
                handle,
                "INSERT INTO events(room_id, event_id, ts, payload) VALUES (?, ?, ?, ?);",
                bind: [room.roomId.value, event.eventId.value, "\(event.originServerTs)", json]
            )
        }
    }

    // MARK: - Schema

    private static func migrate(_ handle: DatabaseHandle) throws {
        try exec(
            handle,
            """
            CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS account_data(type TEXT PRIMARY KEY, content TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS rooms(
                room_id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
                topic TEXT NOT NULL DEFAULT '', avatar_url TEXT NOT NULL DEFAULT '',
                membership TEXT NOT NULL, unread INTEGER NOT NULL DEFAULT 0,
                highlight INTEGER NOT NULL DEFAULT 0, prev_batch TEXT NOT NULL DEFAULT '',
                fully_read TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS members(
                room_id TEXT NOT NULL, user_id TEXT NOT NULL,
                membership TEXT NOT NULL, content TEXT NOT NULL,
                PRIMARY KEY (room_id, user_id)
            );
            CREATE TABLE IF NOT EXISTS events(
                room_id TEXT NOT NULL, event_id TEXT NOT NULL,
                ts INTEGER NOT NULL, payload TEXT NOT NULL,
                PRIMARY KEY (room_id, event_id)
            );
            CREATE INDEX IF NOT EXISTS idx_events_room_ts ON events(room_id, ts);
            CREATE INDEX IF NOT EXISTS idx_members_room ON members(room_id);
            """
        )
    }

    // MARK: - Raw helpers (static: explicit handle, no actor state)

    private static func lastError(_ handle: DatabaseHandle) -> String {
        String(cString: sqlite3_errmsg(handle.db))
    }

    private static func exec(_ handle: DatabaseHandle, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle.db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? lastError(handle)
            sqlite3_free(err)
            throw SQLiteError(message)
        }
    }

    private static func prepare(_ handle: DatabaseHandle, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(lastError(handle))
        }
        return stmt
    }

    private static func bind(_ stmt: OpaquePointer, _ values: [String]) throws {
        for (index, value) in values.enumerated() {
            let code = value.withCString { ptr in
                sqlite3_bind_text(stmt, Int32(index + 1), ptr, -1, sqliteTransient)
            }
            guard code == SQLITE_OK else {
                throw SQLiteError(String(cString: sqlite3_errstr(code)))
            }
        }
    }

    /// Run a statement that returns no rows (INSERT/DELETE/...).
    private static func execute(
        _ handle: DatabaseHandle, _ sql: String, bind values: [String] = []
    ) throws {
        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError(lastError(handle))
        }
    }

    /// Run a SELECT, returning rows as text columns (`""` for NULL).
    private static func query(
        _ handle: DatabaseHandle, _ sql: String, bind values: [String] = []
    ) throws -> [[String]] {
        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, values)
        var rows: [[String]] = []
        let columns = Int(sqlite3_column_count(stmt))
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                var row: [String] = []
                row.reserveCapacity(columns)
                for i in 0..<columns {
                    if let ptr = sqlite3_column_text(stmt, Int32(i)) {
                        row.append(String(cString: ptr))
                    } else {
                        row.append("")
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError(lastError(handle))
            }
        }
    }

    private static func queryScalar(
        _ handle: DatabaseHandle, _ sql: String, bind values: [String] = []
    ) throws -> String? {
        try query(handle, sql, bind: values).first?.first
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? decoder.decode(type, from: Data(json.utf8))
    }
}
