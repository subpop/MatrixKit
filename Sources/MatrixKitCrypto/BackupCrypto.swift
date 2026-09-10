import Crypto
import Foundation

/// Server-side key backup crypto
/// (`m.megolm_backup.v1.curve25519-aes-sha2`): recovery-key codec plus
/// public-key session encryption compatible with vodozemac/libolm
/// (X25519 ECDH → HKDF-SHA256 → AES-256-CBC, truncated HMAC over the
/// empty message per the known libolm quirk).
public enum BackupCrypto {
    // MARK: - Recovery key

    /// Recovery-key prefix bytes (`Es…`).
    static let recoveryPrefix: [UInt8] = [0x8B, 0x01]
    /// Display chunk size for recovery keys.
    static let recoveryChunkSize = 4

    /// Fresh 32-byte backup private key.
    public static func generatePrivateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    /// Curve25519 public key for a private key.
    public static func publicKey(privateKey: Data) throws(CryptoError) -> Data {
        do {
            let secret = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey)
            return Data(secret.publicKey.rawRepresentation)
        } catch {
            throw .invalidKey("Invalid backup private key: \(error.localizedDescription)")
        }
    }

    /// Base58 recovery key (`Es…`, spaced in fours for display).
    public static func recoveryKey(privateKey: Data) -> String {
        var bytes = recoveryPrefix
        bytes += privateKey
        bytes.append(parity(of: privateKey))
        return Base58.encode(Data(bytes))
            .enumerated()
            .map { $0.offset > 0 && $0.offset % recoveryChunkSize == 0 ? " \($0.element)" : "\($0.element)" }
            .joined()
    }

    /// Parse a recovery key (whitespace-tolerant) into private key bytes.
    public static func parseRecoveryKey(_ string: String) throws(CryptoError) -> Data {
        let stripped = string.filter { !$0.isWhitespace }
        guard let decoded = Base58.decode(stripped) else {
            throw .invalidKey("Recovery key is not valid base58")
        }
        guard decoded.count == 2 + 32 + 1 else {
            throw .invalidKey(
                "Recovery key has invalid length \(decoded.count), expected 35")
        }
        guard Array(decoded.prefix(2)) == recoveryPrefix else {
            throw .invalidKey("Recovery key has an invalid prefix")
        }
        let key = decoded.dropFirst(2).dropLast()
        guard decoded.last == parity(of: key) else {
            throw .invalidKey("Recovery key parity byte mismatch")
        }
        return Data(key)
    }

    private static func parity(of key: some Collection<UInt8>) -> UInt8 {
        key.reduce(recoveryPrefix[0] ^ recoveryPrefix[1], ^)
    }

    // MARK: - Session backup encryption

    /// Encrypt a session export for a backup public key.
    public static func encryptSession(
        _ plaintext: Data, publicKey: Data
    ) throws(CryptoError) -> (ciphertext: Data, mac: Data, ephemeral: Data) {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeral = Curve25519.KeyAgreement.PrivateKey()
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw .invalidKey("Invalid backup public key: \(error.localizedDescription)")
        }
        let keys = try exchangeKeys(ephemeral: ephemeral, peer: peer)
        guard let ciphertext = try? AESCBC.encrypt(
            key: keys.aes, iv: keys.iv, plaintext: plaintext)
        else {
            throw .encryptionFailed("Backup session encryption failed")
        }
        // Known libolm quirk, replicated for interop: the MAC covers the
        // empty message instead of the ciphertext.
        return (
            ciphertext,
            Data(Primitives.hmacSHA256(key: keys.mac, message: Data()).prefix(8)),
            Data(ephemeral.publicKey.rawRepresentation))
    }

    /// Decrypt a backed-up session with the backup private key.
    /// Ciphertext tampering surfaces as padding errors or garbage (the
    /// MAC covers the empty message per the libolm quirk); MAC tampering
    /// always throws.
    public static func decryptSession(
        ciphertext: Data, mac: Data, ephemeral: Data, privateKey: Data
    ) throws(CryptoError) -> Data {
        let secret: Curve25519.KeyAgreement.PrivateKey
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        } catch {
            throw .invalidKey("Invalid backup key: \(error.localizedDescription)")
        }
        let keys = try exchangeKeys(ephemeral: secret, peer: peer)
        let expected = Data(Primitives.hmacSHA256(key: keys.mac, message: Data()).prefix(8))
        guard Primitives.constantTimeEqual(expected, mac) else {
            throw .macMismatch
        }
        do {
            return try AESCBC.decrypt(key: keys.aes, iv: keys.iv, ciphertext: ciphertext)
        } catch {
            throw .malformedMessage("Backup session decrypt failed: \(error.localizedDescription)")
        }
    }

    private struct BackupKeys {
        var aes: Data
        var mac: Data
        var iv: Data
    }

    private static func exchangeKeys(
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        peer: Curve25519.KeyAgreement.PublicKey
    ) throws(CryptoError) -> BackupKeys {
        let shared: Data
        do {
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
            shared = secret.withUnsafeBytes { Data($0) }
        } catch {
            throw .invalidKey("Backup key agreement failed: \(error.localizedDescription)")
        }
        let derived = Primitives.hkdfSHA256(
            inputKeyMaterial: shared, salt: Data([0x00]),
            info: Data(), outputByteCount: 80)
        return BackupKeys(
            aes: derived.prefix(32),
            mac: derived.dropFirst(32).prefix(32),
            iv: derived.suffix(16))
    }
}
