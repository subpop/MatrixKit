import Foundation

/// Pure `m.secret_storage.v1.aes-hmac-sha2` math: key derivation, secret
/// encryption/decryption, and the zero-block key check.
///
/// For a 32-byte storage key `K` and secret name `N`:
/// `(aes, hmac) = HKDF-SHA256(ikm: K, salt: 32 zero bytes, info: N)` →
/// 64 bytes, split in half. Secrets encrypt with AES-256-CTR using the
/// stored 16-byte IV directly as the counter block (key creators clear
/// bit 63 of generated IVs) and authenticate with full HMAC-SHA-256
/// over the ciphertext. The key check encrypts 32 zero bytes under the
/// empty-name keys and compares the stored MAC.
public enum SecretStorageCrypto {
    /// HKDF salt: 32 zero bytes.
    static let hkdfSalt = Data(repeating: 0, count: 32)
    /// Zero-block length for key checks.
    static let checkPlaintextLength = 32
    /// Stored IV length: the full 16-byte AES counter block.
    static let ivLength = 16

    /// Derive the `(aes, hmac)` keypair for a secret name.
    public static func deriveKeys(
        storageKey: Data, name: String
    ) -> (aes: Data, hmac: Data) {
        let okm = Primitives.hkdfSHA256(
            inputKeyMaterial: storageKey, salt: hkdfSalt,
            info: Data(name.utf8), outputByteCount: 64)
        return (okm.prefix(32), okm.suffix(32))
    }

    /// Validate a stored IV: the full 16-byte counter block, used as-is.
    static func checkedIv(_ iv: Data) throws(CryptoError) -> Data {
        guard iv.count == ivLength else {
            throw .invalidKey(
                "Secret-storage IV must be 16 bytes, got \(iv.count)")
        }
        return iv
    }

    /// Encrypt plaintext for a secret name under the storage key. Fresh
    /// IVs must be 16 random bytes with bit 63 cleared (byte 7 `&= 0x7F`).
    public static func encrypt(
        _ plaintext: Data, name: String, storageKey: Data, iv: Data
    ) throws(CryptoError) -> (ciphertext: Data, mac: Data) {
        let keys = deriveKeys(storageKey: storageKey, name: name)
        let ciphertext = try AESCTR.encrypt(
            key: keys.aes, iv: checkedIv(iv), plaintext: plaintext)
        return (
            ciphertext,
            Primitives.hmacSHA256(key: keys.hmac, message: ciphertext))
    }

    /// Decrypt a stored secret, verifying its MAC first.
    public static func decrypt(
        ciphertext: Data, mac: Data, iv: Data,
        name: String, storageKey: Data
    ) throws(CryptoError) -> Data {
        let keys = deriveKeys(storageKey: storageKey, name: name)
        let expected = Primitives.hmacSHA256(key: keys.hmac, message: ciphertext)
        guard Primitives.constantTimeEqual(expected, mac) else {
            throw .macMismatch
        }
        do {
            return try AESCTR.decrypt(
                key: keys.aes, iv: checkedIv(iv), ciphertext: ciphertext)
        } catch {
            throw .encryptionFailed("Secret-storage decrypt failed: \(error)")
        }
    }

    /// Compute the key-check MAC for a storage key and IV (the MAC the
    /// server stores in `m.secret_storage.key.<id>`): HMAC over the
    /// encryption of 32 zero bytes under the empty-name keys.
    public static func keyCheckMac(
        storageKey: Data, iv: Data
    ) throws(CryptoError) -> Data {
        let keys = deriveKeys(storageKey: storageKey, name: "")
        let ciphertext = try AESCTR.encrypt(
            key: keys.aes, iv: checkedIv(iv),
            plaintext: Data(repeating: 0, count: checkPlaintextLength))
        return Primitives.hmacSHA256(key: keys.hmac, message: ciphertext)
    }

    /// Whether a storage key matches a stored check `(iv, mac)` pair.
    public static func verifyKey(
        storageKey: Data, iv: Data, mac: Data
    ) -> Bool {
        guard
            let expected = try? keyCheckMac(storageKey: storageKey, iv: iv)
        else { return false }
        return Primitives.constantTimeEqual(expected, mac)
    }
}
