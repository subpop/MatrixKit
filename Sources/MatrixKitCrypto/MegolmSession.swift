import Crypto
import Foundation

/// A Megolm group session: the ratchet underneath
/// `m.megolm.v1.aes-sha2`.
///
/// A session is a 32-bit counter plus an Ed25519 keypair plus a ratchet
/// of four 256-bit values `R₀…R₃`. Outbound sessions (created with
/// `create()`) hold the private key and encrypt; inbound sessions
/// (from `importSessionKey`) hold the public key and decrypt.
///
/// Message keys come from `HKDF(0, R₀∥R₁∥R₂∥R₃, "MEGOLM_KEYS", 80)`
/// (32-byte AES key, 32-byte HMAC key, 16-byte IV). Messages carry an
/// 8-byte HMAC plus a 64-byte Ed25519 signature over
/// version + payload + MAC.
///
/// State is in memory only this milestone.
public struct MegolmSession: Sendable {
    public static let version: UInt8 = 0x03
    /// Version byte of the signed session-sharing blob (`m.room_key`).
    public static let sharingVersion: UInt8 = 0x02
    /// Version byte of the unsigned export blob (local persistence).
    public static let exportVersion: UInt8 = 0x01

    /// Next outbound message index / inbound ratchet position.
    public private(set) var counter: UInt32
    private var parts: [Data]
    private let signingKey: SigningKey?
    private let verifyKey: Data
    private var received: Set<UInt32> = []

    private init(
        counter: UInt32, parts: [Data], signingKey: SigningKey?,
        verifyKey: Data
    ) {
        self.counter = counter
        self.parts = parts
        self.signingKey = signingKey
        self.verifyKey = verifyKey
    }

    // MARK: - Setup

    /// Create a fresh outbound session: random ratchet + Ed25519 keypair.
    public static func create() -> MegolmSession {
        let key = SigningKey.generate()
        return MegolmSession(
            counter: 0,
            parts: (0..<4).map { _ in randomBytes(32) },
            signingKey: key,
            verifyKey: key.publicKeyBytes)
    }

    /// Deterministic seam for interop fixtures: outbound session from
    /// caller-supplied counter, ratchet parts, and Ed25519 private key.
    /// Internal — tests only, never for production sessions.
    internal static func createDeterministic(
        counter: UInt32, parts: [Data], ed25519PrivateKey: Data
    ) throws(CryptoError) -> MegolmSession {
        guard parts.count == 4, parts.allSatisfy({ $0.count == 32 }) else {
            throw .invalidKey("Megolm parts must be four 32-byte values")
        }
        let key = try SigningKey.restore(privateKeyBytes: ed25519PrivateKey)
        return MegolmSession(
            counter: counter, parts: parts.map { Data($0) },
            signingKey: key, verifyKey: key.publicKeyBytes)
    }

    /// Import a session-sharing blob (`m.room_key` `session_key`, 229
    /// bytes, signed) or an unsigned export blob (165 bytes, local
    /// trust). Returns an inbound session positioned at the blob's
    /// counter: earlier messages are undecryptable (`indexTooOld`).
    public static func importSessionKey(
        _ blob: Data
    ) throws(CryptoError) -> MegolmSession {
        // Normalize: callers may pass a `Data` slice whose indices do
        // not start at zero; the fixed offsets below assume they do.
        let blob = Data(blob)
        guard let version = blob.first else {
            throw .malformedMessage("Empty Megolm session blob")
        }
        switch version {
        case sharingVersion:
            guard blob.count == 1 + 4 + 128 + 32 + 64 else {
                throw .malformedMessage(
                    "Session-sharing blob must be 229 bytes")
            }
            let unsigned = blob.prefix(1 + 4 + 128 + 32)
            let publicKey = unsigned.suffix(32)
            guard SigningKey.verify(
                signature: blob.suffix(64), for: unsigned,
                publicKey: publicKey)
            else {
                throw .invalidSignature
            }
            return try inbound(
                counter: readCounter(blob, at: 1),
                parts: strideParts(blob, from: 5), verifyKey: publicKey)
        case exportVersion:
            guard blob.count == 1 + 4 + 128 + 32 else {
                throw .malformedMessage("Export blob must be 165 bytes")
            }
            return try inbound(
                counter: readCounter(blob, at: 1),
                parts: strideParts(blob, from: 5),
                verifyKey: blob.suffix(32))
        default:
            throw .unsupportedVersion(version)
        }
    }

    private static func inbound(
        counter: UInt32, parts: [Data], verifyKey: Data
    ) throws(CryptoError) -> MegolmSession {
        guard parts.allSatisfy({ $0.count == 32 }),
            verifyKey.count == 32
        else {
            throw .malformedMessage("Megolm session parts must be 32 bytes")
        }
        return MegolmSession(
            counter: counter, parts: parts, signingKey: nil,
            verifyKey: Data(verifyKey))
    }

    // MARK: - Encrypt / decrypt

    /// Encrypt for outbound index `counter`, then advance. Outbound only.
    public mutating func encrypt(
        _ plaintext: Data
    ) throws(CryptoError) -> Data {
        guard signingKey != nil else {
            throw .notOutbound
        }
        guard counter < UInt32.max else {
            throw .malformedMessage("Megolm counter exhausted")
        }
        let index = counter
        let keys = messageKeys()
        let ciphertext = try AESCBC.encrypt(
            key: keys.aes, iv: keys.iv, plaintext: plaintext)
        var payload = Data([Self.version])
        payload += ProtoCoding.intField(number: 1, value: UInt64(index))
        payload += ProtoCoding.bytesField(number: 2, value: ciphertext)
        let mac = Self.messageMAC(keys.hmac, payload: payload)
        let signed = payload + mac
        guard let signature = try signingKey?.sign(signed) else {
            throw .encryptionFailed("Megolm session lost its signing key")
        }
        advance()
        return signed + signature
    }

    /// Decrypt one wire message (payload + MAC + signature). Replays and
    /// messages older than the ratchet position are rejected.
    public mutating func decrypt(
        _ message: Data
    ) throws(CryptoError) -> Data {
        guard message.count >= 1 + 8 + 64 else {
            throw .malformedMessage("Megolm message too short")
        }
        guard message[message.startIndex] == Self.version else {
            throw .unsupportedVersion(message[message.startIndex])
        }
        let signed = message.prefix(message.count - 64)
        let signature = message.suffix(64)
        guard SigningKey.verify(
            signature: signature, for: signed, publicKey: verifyKey)
        else {
            throw .invalidSignature
        }
        let payload = signed.prefix(signed.count - 8)
        let mac = signed.suffix(8)
        let (index, ciphertext) = try Self.decodePayload(payload)
        guard !received.contains(index) else {
            throw .replayDetected
        }
        guard index >= UInt64(counter) else {
            throw .indexTooOld
        }
        var parts = parts
        Self.advanceParts(&parts, from: UInt64(counter), to: UInt64(index))
        let keys = Self.messageKeys(parts: parts)
        guard Primitives.constantTimeEqual(
            Self.messageMAC(keys.hmac, payload: payload), mac)
        else {
            throw .macMismatch
        }
        self.parts = parts
        counter = index
        received.insert(index)
        return try AESCBC.decrypt(
            key: keys.aes, iv: keys.iv, ciphertext: ciphertext)
    }

    // MARK: - Sharing / export

    /// Signed 229-byte session-sharing blob for `m.room_key`
    /// `session_key`: version `0x02` + big-endian counter + `R₀…R₃` +
    /// public key + signature. Outbound only.
    public func sessionKey() throws(CryptoError) -> Data {
        guard let signingKey else {
            throw .notOutbound
        }
        var out = Data([Self.sharingVersion])
        out += Self.writeCounter(counter)
        for part in parts { out += part }
        out += verifyKey
        out += try signingKey.sign(out)
        return out
    }

    /// Unsigned 165-byte export blob (local persistence): version
    /// `0x01` + counter + `R₀…R₃` + public key, no signature.
    /// Re-importable via `importSessionKey`.
    public func export() -> Data {        var out = Data([Self.exportVersion])
        out += Self.writeCounter(counter)
        for part in parts { out += part }
        out += verifyKey
        return out
    }

    /// Session ID: base64 of the Ed25519 session public key.
    public var id: String {
        Primitives.base64UnpaddedEncode(verifyKey)
    }

    /// Message index embedded in the export blob: the first index this
    /// session state can still decrypt (ratchet position at export).
    public var firstMessageIndex: UInt32? {
        let blob = export()
        guard blob.count >= 5, blob[blob.startIndex] == Self.exportVersion else {
            return nil
        }
        return blob[blob.startIndex + 1..<blob.startIndex + 5].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    // MARK: - Ratchet

    /// Advance our own parts by one step (post-encrypt).
    private mutating func advance() {
        Self.advanceParts(
            &parts, from: UInt64(counter), to: UInt64(counter) + 1)
        counter += 1
    }

    /// Step parts from index `from` to index `to`: at multiples of 2²⁴
    /// `R₀` reseeds and everything below follows; at 2¹⁶ `R₁…R₃`
    /// reseed from `R₀`; at 2⁸ `R₂…R₃` reseed from `R₁`; otherwise only
    /// `R₃` advances. `Hⱼ(A) = HMAC-SHA-256(A, j)`.
    private static func advanceParts(
        _ parts: inout [Data], from: UInt64, to: UInt64
    ) {
        var i = from
        while i < to {
            i += 1
            if i % (1 << 24) == 0 {
                parts[0] = hashPart(parts[0], 0x00)
                parts[1] = hashPart(parts[0], 0x01)
                parts[2] = hashPart(parts[1], 0x02)
                parts[3] = hashPart(parts[2], 0x03)
            } else if i % (1 << 16) == 0 {
                parts[1] = hashPart(parts[0], 0x01)
                parts[2] = hashPart(parts[1], 0x02)
                parts[3] = hashPart(parts[2], 0x03)
            } else if i % (1 << 8) == 0 {
                parts[2] = hashPart(parts[1], 0x02)
                parts[3] = hashPart(parts[2], 0x03)
            } else {
                parts[3] = hashPart(parts[3], 0x03)
            }
        }
    }

    private static func hashPart(_ part: Data, _ byte: UInt8) -> Data {
        Primitives.hmacSHA256(key: part, message: Data([byte]))
    }

    /// `AES ∥ HMAC ∥ IV = HKDF(0, R₀∥R₁∥R₂∥R₃, "MEGOLM_KEYS", 80)`.
    private func messageKeys() -> (aes: Data, hmac: Data, iv: Data) {
        Self.messageKeys(parts: parts)
    }

    private static func messageKeys(parts: [Data]) -> (
        aes: Data, hmac: Data, iv: Data
    ) {
        let out = Primitives.hkdfSHA256(
            inputKeyMaterial: parts.reduce(Data(), +), salt: Data(),
            info: Data("MEGOLM_KEYS".utf8), outputByteCount: 80)
        return (out.prefix(32), out[32..<64], out.suffix(16))
    }

    private static func messageMAC(
        _ hmacKey: Data, payload: Data
    ) -> Data {
        Primitives.hmacSHA256(key: hmacKey, message: payload).prefix(8)
    }

    // MARK: - Wire helpers

    private static func decodePayload(
        _ payload: Data
    ) throws(CryptoError) -> (index: UInt32, ciphertext: Data) {
        guard
            payload.count >= 1, payload[payload.startIndex] == version
        else {
            throw .malformedMessage("Megolm payload missing version byte")
        }
        let fields = try ProtoCoding.decodeFields(payload.dropFirst())
        var index: UInt64?
        var ciphertext: Data?
        for (number, field) in fields {
            switch (number, field) {
            case (1, .int(let value)): index = value
            case (2, .bytes(let value)): ciphertext = Data(value)
            default: break
            }
        }
        guard let index, let ciphertext else {
            throw .malformedMessage("Megolm payload missing fields")
        }
        guard index <= UInt64(UInt32.max) else {
            throw .malformedMessage("Megolm index exceeds 32 bits")
        }
        return (UInt32(index), ciphertext)
    }

    private static func readCounter(
        _ blob: Data, at offset: Int
    ) -> UInt32 {
        blob[offset..<offset + 4].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func strideParts(
        _ blob: Data, from offset: Int
    ) -> [Data] {
        (0..<4).map { blob[offset + $0 * 32..<offset + $0 * 32 + 32] }
    }

    private static func writeCounter(_ counter: UInt32) -> Data {
        Data([
            UInt8((counter >> 24) & 0xFF), UInt8((counter >> 16) & 0xFF),
            UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF),
        ])
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}
