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

/// How this device stands with the account's server-side key backup, for
/// settings UI.
public struct KeyBackupStatus: Hashable, Sendable {
    /// A server-side key backup exists.
    public var exists: Bool
    /// This device adds keys to the backup: it is signed by this device,
    /// or by keys of ours this verified session trusts.
    public var isTrusted: Bool
    /// This device holds the private key for the backup, so it can
    /// restore from it without asking another device.
    public var hasKey: Bool
    /// Sessions held here that the backup already stores.
    public var backedUpSessions: Int
    /// Sessions held here waiting to be uploaded.
    public var pendingSessions: Int
    /// Sessions held here that cannot be uploaded: their origin is
    /// unknown, which backup entries require.
    public var unattributedSessions: Int

    public init(
        exists: Bool = false, isTrusted: Bool = false, hasKey: Bool = false,
        backedUpSessions: Int = 0, pendingSessions: Int = 0,
        unattributedSessions: Int = 0
    ) {
        self.exists = exists
        self.isTrusted = isTrusted
        self.hasKey = hasKey
        self.backedUpSessions = backedUpSessions
        self.pendingSessions = pendingSessions
        self.unattributedSessions = unattributedSessions
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

extension BackupVersionInfo {
    /// Unpadded-base64 Curve25519 backup public key from `auth_data`.
    public var publicKey: String? {
        authData?["public_key"]?.stringValue
    }

    /// Whether this is a backup this client can use `privateKey` with:
    /// a supported algorithm whose `auth_data` public key is the public
    /// half of `privateKey`. A mismatched key decrypts nothing, so
    /// restore paths check this before downloading.
    public func accepts(privateKey: Data) -> Bool {
        guard
            algorithm == KeyBackup.algorithm, let publicKey,
            let derived = try? BackupCrypto.publicKey(privateKey: privateKey)
        else { return false }
        return publicKey == Primitives.base64UnpaddedEncode(derived)
    }

    /// Whether `auth_data` carries a valid Ed25519 signature from
    /// `signingKey` for `userId` under `keyId` (`ed25519:<device or
    /// cross-signing key>`), over the canonical `auth_data` minus
    /// `signatures` and `unsigned`. Trust in the signing key itself is
    /// the caller's decision.
    public func isSigned(userId: UserId, keyId: String, by signingKey: Data) -> Bool {
        guard
            let signature = authData?["signatures"]?.objectValue?[userId.value]?
                .objectValue?[keyId]?.stringValue,
            let signatureBytes = Primitives.base64UnpaddedDecode(signature),
            let signed = KeyBackup.signedAuthData(authData ?? [:])
        else { return false }
        return SigningKey.verify(
            signature: signatureBytes, for: signed, publicKey: signingKey)
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

/// Where a Megolm session came from: the originating device's keys and
/// the devices it was forwarded through. Backup entries carry it so a
/// restoring device can attribute the session.
public struct SessionOrigin: Hashable, Sendable, Codable {
    /// Curve25519 identity key of the device that created the session.
    public var senderKey: String
    /// Ed25519 key that device claims.
    public var claimedEd25519: String
    /// Curve25519 keys of the devices the session was forwarded
    /// through, oldest first. Empty when received directly.
    public var forwardingChain: [String]

    public init(
        senderKey: String, claimedEd25519: String, forwardingChain: [String] = []
    ) {
        self.senderKey = senderKey
        self.claimedEd25519 = claimedEd25519
        self.forwardingChain = forwardingChain
    }
}

/// One Megolm session as stored in a key backup.
public struct BackedUpSession: Hashable, Sendable {
    public var roomId: RoomId
    public var sessionId: String
    /// Unsigned export blob (`MegolmSession.export()`).
    public var export: Data
    /// Origin recorded with the session; nil for entries without it.
    /// Uploads skip sessions without an origin: restoring clients need
    /// `sender_key` to decrypt.
    public var origin: SessionOrigin?

    public init(
        roomId: RoomId, sessionId: String, export: Data, origin: SessionOrigin?
    ) {
        self.roomId = roomId
        self.sessionId = sessionId
        self.export = export
        self.origin = origin
    }
}

/// Plaintext encrypted into `session_data` (decrypted on restore).
struct BackupPlaintext: Codable {
    /// Optional so entries from clients that omit it still restore.
    var algorithm: String? = "m.megolm.v1.aes-sha2"
    var sessionKey: String
    var senderKey: String?
    var senderClaimedKeys: [String: String]?
    var forwardingChain: [String]?

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case sessionKey = "session_key"
        case senderKey = "sender_key"
        case senderClaimedKeys = "sender_claimed_keys"
        case forwardingChain = "forwarding_curve25519_key_chain"
    }
}

public actor KeyBackup {
    /// Backup algorithm this client speaks.
    public static let algorithm = "m.megolm_backup.v1.curve25519-aes-sha2"

    private let transport: MatrixTransport
    private let session: Session

    /// Memoized backup for the automatic recovery path (see
    /// `cachedBackupVersion`). `.none` means unchecked.
    private var backupCache: BackupVersionInfo?? = nil

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

    /// Backup version for automatic recovery with `privateKey`,
    /// memoized per launch so every undecryptable session does not cost
    /// a `GET` (users without a backup pay exactly one). Nil when there
    /// is no backup or the key does not belong to it (see
    /// `BackupVersionInfo.accepts(privateKey:)`). Explicit version
    /// changes through this actor refresh the memo; versions created
    /// elsewhere apply on the next launch.
    public func cachedBackupVersion(
        for privateKey: Data
    ) async throws(MatrixError) -> String? {
        let info: BackupVersionInfo?
        if let cached = backupCache {
            info = cached
        } else {
            info = try await backupInfo()
            backupCache = .some(info)
        }
        guard let info, info.accepts(privateKey: privateKey) else { return nil }
        return info.version
    }

    /// Canonical JSON signed in backup `auth_data`: the object without
    /// `signatures` and `unsigned`. Nil when it holds a value canonical
    /// JSON cannot represent (floats).
    static func signedAuthData(_ authData: [String: AnyCodable]) -> Data? {
        var unsigned = authData
        unsigned["signatures"] = nil
        unsigned["unsigned"] = nil
        guard let object = jsonObject(.object(unsigned)) else { return nil }
        return try? CryptoPrimitives.canonicalJSON(object)
    }

    private static func jsonObject(_ value: AnyCodable) -> Any? {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .bool(let b): return b
        case .null: return NSNull()
        case .double: return nil
        case .array(let items):
            let converted = items.compactMap(jsonObject)
            return converted.count == items.count ? converted : nil
        case .object(let fields):
            var out: [String: Any] = [:]
            for (key, field) in fields {
                guard let converted = jsonObject(field) else { return nil }
                out[key] = converted
            }
            return out
        }
    }

    /// `auth_data` for a backup public key, before signing. Sign
    /// `signedAuthData(_:)` of it and pass the signatures to
    /// `createBackup(publicKey:signatures:)`.
    public static func authData(publicKey: Data) -> [String: AnyCodable] {
        ["public_key": .string(Primitives.base64UnpaddedEncode(publicKey))]
    }

    /// Create a backup version for a backup public key. `signatures`
    /// (user ID to `ed25519:<key ID>` to unpadded-base64 signature over
    /// `signedAuthData(authData(publicKey:))`) go into `auth_data` so
    /// other devices can establish trust in the backup. Returns the
    /// version.
    public func createBackup(
        publicKey: Data, signatures: [String: [String: String]] = [:]
    ) async throws(MatrixError) -> String {
        struct Response: Decodable {
            var version: String
        }
        var authData = Self.authData(publicKey: publicKey)
        if !signatures.isEmpty {
            authData["signatures"] = .object(signatures.mapValues { keyed in
                .object(keyed.mapValues { .string($0) })
            })
        }
        let response: Response = try await transport.send(
            .post, path: "/_matrix/client/v3/room_keys/version",
            body: [
                "algorithm": AnyCodable.string(Self.algorithm),
                "auth_data": .object(authData),
            ],
            accessToken: try await token()
        )
        backupCache = .some(BackupVersionInfo(
            version: response.version, algorithm: Self.algorithm,
            authData: authData))
        return response.version
    }

    /// Delete a backup version and its keys.
    public func deleteBackup(version: String) async throws(MatrixError) {
        let _: EmptyResponse = try await transport.send(
            .delete,
            path: "/_matrix/client/v3/room_keys/version/\(version.pathSegmentEncoded)",
            accessToken: try await token()
        )
        backupCache = nil
    }

    // MARK: - Keys

    /// Upload sessions encrypted for the backup public key. Sessions
    /// without an origin and malformed exports are skipped.
    public func uploadSessions(
        _ sessions: [BackedUpSession], publicKey: Data, version: String
    ) async throws(MatrixError) {
        var rooms: [String: BackupRoomSessions] = [:]
        for session in sessions {
            guard
                let origin = session.origin,
                let imported = try? MegolmSession.importSessionKey(session.export),
                let firstIndex = imported.firstMessageIndex,
                let entry = try? backupEntry(
                    export: session.export, origin: origin, publicKey: publicKey,
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
    ) async throws(MatrixError) -> [BackedUpSession] {
        struct Response: Decodable {
            var rooms: [String: BackupRoomSessions]
        }
        let response: Response = try await transport.send(
            .get,
            path: "/_matrix/client/v3/room_keys/keys",
            query: ["version": version],
            accessToken: try await token()
        )
        var out: [BackedUpSession] = []
        for (roomId, room) in response.rooms {
            for (sessionId, entry) in room.sessions {
                guard let decrypted = try? decryptEntry(entry, privateKey: privateKey) else {
                    continue
                }
                out.append(BackedUpSession(
                    roomId: RoomId(unchecked: roomId), sessionId: sessionId,
                    export: decrypted.export, origin: decrypted.origin))
            }
        }
        return out
    }

    /// Download and decrypt one backed-up session.
    public func downloadSession(
        roomId: RoomId, sessionId: String, version: String, privateKey: Data
    ) async throws(MatrixError) -> BackedUpSession {
        let entry: BackupSessionData = try await transport.send(
            .get,
            path: "/_matrix/client/v3/room_keys/keys/\(roomId.pathSegmentEncoded)/\(sessionId.pathSegmentEncoded)",
            query: ["version": version],
            accessToken: try await token()
        )
        guard let decrypted = try? decryptEntry(entry, privateKey: privateKey) else {
            throw .encodingError("Cannot decrypt backed-up session \(sessionId)")
        }
        return BackedUpSession(
            roomId: roomId, sessionId: sessionId,
            export: decrypted.export, origin: decrypted.origin)
    }

    // MARK: - Private

    private func backupEntry(
        export: Data, origin: SessionOrigin, publicKey: Data, firstIndex: Int
    ) throws(MatrixError) -> BackupSessionData {
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(
                BackupPlaintext(
                    sessionKey: Primitives.base64UnpaddedEncode(export),
                    senderKey: origin.senderKey,
                    senderClaimedKeys: ["ed25519": origin.claimedEd25519],
                    forwardingChain: origin.forwardingChain))
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
            forwardedCount: origin.forwardingChain.count,
            sessionData: BackupSessionPayload(
                ephemeral: Primitives.base64UnpaddedEncode(encrypted.ephemeral),
                ciphertext: Primitives.base64UnpaddedEncode(encrypted.ciphertext),
                mac: Primitives.base64UnpaddedEncode(encrypted.mac)))
    }

    private func decryptEntry(
        _ entry: BackupSessionData, privateKey: Data
    ) throws(MatrixError) -> (export: Data, origin: SessionOrigin?) {
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
        guard
            let json = try? JSONDecoder().decode(BackupPlaintext.self, from: decrypted),
            let blob = Primitives.base64UnpaddedDecode(json.sessionKey),
            (try? MegolmSession.importSessionKey(blob)) != nil
        else {
            throw .encodingError("Backed-up session has malformed plaintext")
        }
        var origin: SessionOrigin?
        if let senderKey = json.senderKey,
            let claimed = json.senderClaimedKeys?["ed25519"]
        {
            origin = SessionOrigin(
                senderKey: senderKey, claimedEd25519: claimed,
                forwardingChain: json.forwardingChain ?? [])
        }
        return (blob, origin)
    }
}
