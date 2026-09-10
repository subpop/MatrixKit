#if canImport(CommonCrypto)
import CommonCrypto
#else
#error("MatrixKitCrypto requires CommonCrypto (Apple platforms only)")
#endif
import Foundation

/// AES-256-CBC with PKCS#7 padding via CommonCrypto.
///
/// This is the one primitive the Olm/Megolm specs need that `swift-crypto`
/// does not provide (it offers AES-GCM only). Keys are 32 bytes, IVs 16.
public enum AESCBC {
    /// Encrypt. Output length is input rounded up to the 16-byte block.
    public static func encrypt(
        key: Data, iv: Data, plaintext: Data
    ) throws(CryptoError) -> Data {
        try crypt(
            op: UInt32(kCCEncrypt), key: key, iv: iv, input: plaintext)
    }

    /// Decrypt. Throws on padding errors (tamper/wrong key).
    public static func decrypt(
        key: Data, iv: Data, ciphertext: Data
    ) throws(CryptoError) -> Data {
        try crypt(
            op: UInt32(kCCDecrypt), key: key, iv: iv, input: ciphertext)
    }

    private static func crypt(
        op: UInt32, key: Data, iv: Data, input: Data
    ) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw .invalidKey("AES-256 needs 32 bytes, got \(key.count)")
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw .invalidKey("AES-CBC needs a 16-byte IV, got \(iv.count)")
        }
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            op == UInt32(kCCEncrypt)
                                ? UInt32(kCCEncrypt) : UInt32(kCCDecrypt),
                            UInt32(kCCAlgorithmAES),
                            UInt32(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES256,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outCapacity,
                            &outLength)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw .encryptionFailed("CCCrypt status \(status)")
        }
        return out.prefix(outLength)
    }
}
