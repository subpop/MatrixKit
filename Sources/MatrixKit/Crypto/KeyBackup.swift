/// Server-side key backup (`m.megolm_backup.v1.curve25519-aes-sha2`):
/// version management plus session upload, download, and restore.
/// Session payloads encrypt through `BackupCrypto`; forwarding counts
/// and verification flags are approximations (0/false) — trust metadata
/// for recipients, not decryption inputs.
import Foundation
import MatrixKitCrypto

/// Backup and recovery state for settings UI.
public struct EncryptionStatus: Hashable, Sendable {
    /// A server-side key backup exists.
    public var backupEnabled: Bool
    /// Cross-signing keys exist for this account.
    public var recoveryEnabled: Bool

    public init(backupEnabled: Bool = false, recoveryEnabled: Bool = false) {
        self.backupEnabled = backupEnabled
        self.recoveryEnabled = recoveryEnabled
    }
}

/// `GET /room_keys/version` response body.
public struct BackupVersionInfo: Hashable, Sendable, Codable {
    /// Version identifier, absent when no backup exists.
    public var version: String?
    /// Backup algorithm.
    public var algorithm: String
    /// Algorithm auth data (backup public key, signatures).
    public var authData: [String: AnyCodable]?
    /// Backed-up session count, if reported.
    public var count: Int?
    /// Opaque etag, if reported.
    public var etag: String?

    public init(
        version: String? = nil, algorithm: String,
        authData: [String: AnyCodable]? = nil, count: Int? = nil, etag: String? = nil
    ) {
        self.version = version
        self.algorithm = algorithm
        self.authData = authData
        self.count = count
        self.etag = etag
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case algorithm
        case authData = "auth_data"
        case count
        case etag
    }
}

/// One backed-up session (`session_data` of a `PUT /room_keys/keys` entry).
public struct BackupSessionPayload: Hashable, Sendable, Codable {
    /// Ephemeral Curve25519 key (unpadded base64).
    public var ephemeral: String
    /// Ciphertext (unpadded base64).
    public var ciphertext: String
    /// Truncated MAC (unpadded base64).
    public var mac: String

    public init(ephemeral: String, ciphertext: String, mac: String) {
        self.ephemeral = ephemeral
        self.ciphertext = ciphertext
        self.mac = mac
    }
}

/// One uploaded session entry.
public struct BackupSessionData: Hashable, Sendable, Codable {
    /// First decryptable message index.
    public var firstMessageIndex: Int
    /// Forwarding hops (always 0 from this client).
    public var forwardedCount: Int
    /// Sender-trust flag (always false from this client).
    public var isVerified: Bool
    /// Encrypted payload.
    public var sessionData: BackupSessionPayload

    public init(
        firstMessageIndex: Int, forwardedCount: Int = 0, isVerified: Bool = false,
        sessionData: BackupSessionPayload
    ) {
        self.firstMessageIndex = firstMessageIndex
        self.forwardedCount = forwardedCount
        self.isVerified = isVerified
        self.sessionData = sessionData
    }

    private enum CodingKeys: String, CodingKey {
        case firstMessageIndex = "first_message_index"
        case forwardedCount = "forwarded_count"
        case isVerified = "is_verified"
        case sessionData = "session_data"
    }
}

/// One room's worth of backed-up sessions: the `{"sessions": {...}}`
/// wrapper of a `PUT/GET /room_keys/keys` entry.
public struct BackupRoomSessions: Hashable, Sendable, Codable {
    /// Session ID to entry.
    public var sessions: [String: BackupSessionData]

    public init(sessions: [String: BackupSessionData] = [:]) {
        self.sessions = sessions
    }
}

/// Plaintext encrypted into `session_data` (decrypted on restore).
struct BackupPlaintext: Codable {
    var algorithm: String = "m.megolm.v1.aes-sha2"
    var sessionKey: String

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case sessionKey = "session_key"
    }
}

public actor KeyBackup {
    /// Backup algorithm this client speaks.
    public static let algorithm = "m.megolm_backup.v1.curve25519-aes-sha2"

    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Versions

    /// Current backup version info, or nil when no backup exists.
    public func backupInfo() async throws(MatrixError) -> BackupVersionInfo? {
        do {
            return try await transport.send(
                .get, path: "/_matrix/client/v3/room_keys/version",
                accessToken: try await token()
            )
        } catch MatrixError.serverError(let code, _, _) where code == "M_NOT_FOUND" {
            return nil
        }
    }

    /// Create a backup version for a backup public key. Returns the version.
    public func createBackup(publicKey: Data) async throws(MatrixError) -> String {
        struct Response: Decodable {
            var version: String
        }
        let response: Response = try await transport.send(
            .post, path: "/_matrix/client/v3/room_keys/version",
            body: [
                "algorithm": AnyCodable.string(Self.algorithm),
                "auth_data": .object([
                    "public_key": .string(Primitives.base64UnpaddedEncode(publicKey)),
                ]),
            ],
            accessToken: try await token()
        )
        return response.version
    }

    /// Delete a backup version and its keys.
    public func deleteBackup(version: String) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .delete,
            path: "/_matrix/client/v3/room_keys/version/\(version.pathSegmentEncoded)",
            accessToken: try await token()
        )
    }

    // MARK: - Keys

    /// Upload session exports encrypted for the backup public key.
    /// Malformed exports are skipped.
    public func uploadSessions(
        _ sessions: [(roomId: RoomId, sessionId: String, export: Data)],
        publicKey: Data, version: String
    ) async throws(MatrixError) {
        var rooms: [String: BackupRoomSessions] = [:]
        for session in sessions {
            guard
                let imported = try? MegolmSession.importSessionKey(session.export),
                let firstIndex = imported.firstMessageIndex,
                let entry = try? backupEntry(
                    export: session.export, publicKey: publicKey,
                    firstIndex: Int(firstIndex))
            else { continue }
            rooms[session.roomId.value, default: BackupRoomSessions()].sessions[
                session.sessionId] = entry
        }
        guard !rooms.isEmpty else { return }
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/room_keys/keys",
            query: ["version": version],
            body: ["rooms": rooms],
            accessToken: try await token()
        )
    }

    /// Download and decrypt every backed-up session. Undecryptable or
    /// malformed entries are skipped.
    public func downloadSessions(
        version: String, privateKey: Data
    ) async throws(MatrixError) -> [(roomId: RoomId, sessionId: String, export: Data)] {
        struct Response: Decodable {
            var rooms: [String: BackupRoomSessions]
        }
        let response: Response = try await transport.send(
            .get,
            path: "/_matrix/client/v3/room_keys/keys",
            query: ["version": version],
            accessToken: try await token()
        )
        var out: [(RoomId, String, Data)] = []
        for (roomId, room) in response.rooms {
            for (sessionId, entry) in room.sessions {
                guard let export = try? decryptEntry(entry, privateKey: privateKey) else {
                    continue
                }
                out.append((RoomId(unchecked: roomId), sessionId, export))
            }
        }
        return out
    }

    /// Download and decrypt one backed-up session.
    public func downloadSession(
        roomId: RoomId, sessionId: String, version: String, privateKey: Data
    ) async throws(MatrixError) -> Data {
        let entry: BackupSessionData = try await transport.send(
            .get,
            path: "/_matrix/client/v3/room_keys/keys/\(roomId.pathSegmentEncoded)/\(sessionId.pathSegmentEncoded)",
            query: ["version": version],
            accessToken: try await token()
        )
        guard let export = try? decryptEntry(entry, privateKey: privateKey) else {
            throw .encodingError("Cannot decrypt backed-up session \(sessionId)")
        }
        return export
    }

    // MARK: - Private

    private func backupEntry(
        export: Data, publicKey: Data, firstIndex: Int
    ) throws(MatrixError) -> BackupSessionData {
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(
                BackupPlaintext(sessionKey: Primitives.base64UnpaddedEncode(export)))
        } catch {
            throw .encodingError("Cannot encode session export: \(error.localizedDescription)")
        }
        let encrypted: (ciphertext: Data, mac: Data, ephemeral: Data)
        do {
            encrypted = try BackupCrypto.encryptSession(plaintext, publicKey: publicKey)
        } catch {
            throw .encodingError("Cannot encrypt session for backup: \(error)")
        }
        return BackupSessionData(
            firstMessageIndex: firstIndex,
            sessionData: BackupSessionPayload(
                ephemeral: Primitives.base64UnpaddedEncode(encrypted.ephemeral),
                ciphertext: Primitives.base64UnpaddedEncode(encrypted.ciphertext),
                mac: Primitives.base64UnpaddedEncode(encrypted.mac)))
    }

    private func decryptEntry(
        _ entry: BackupSessionData, privateKey: Data
    ) throws(MatrixError) -> Data {
        func decode(_ string: String, what: String) throws(MatrixError) -> Data {
            guard let data = Primitives.base64UnpaddedDecode(string) else {
                throw .encodingError("Backed-up session has malformed \(what)")
            }
            return data
        }
        let decrypted: Data
        do {
            decrypted = try BackupCrypto.decryptSession(
                ciphertext: decode(entry.sessionData.ciphertext, what: "ciphertext"),
                mac: decode(entry.sessionData.mac, what: "mac"),
                ephemeral: decode(entry.sessionData.ephemeral, what: "ephemeral key"),
                privateKey: privateKey)
        } catch {
            throw .encodingError("Cannot decrypt backed-up session: \(error)")
        }
        struct Plaintext: Decodable {
            var sessionKey: String
            private enum CodingKeys: String, CodingKey {
                case sessionKey = "session_key"
            }
        }
        guard
            let json = try? JSONDecoder().decode(Plaintext.self, from: decrypted),
            let blob = Primitives.base64UnpaddedDecode(json.sessionKey),
            (try? MegolmSession.importSessionKey(blob)) != nil
        else {
            throw .encodingError("Backed-up session has malformed plaintext")
        }
        return blob
    }
}
