#if canImport(CommonCrypto)
import CommonCrypto
#else
#error("MatrixKitCrypto requires CommonCrypto (Apple platforms only)")
#endif
import Foundation

/// AES-256-CTR via CommonCrypto (no padding).
///
/// Counter block increments big-endian over the full 128-bit IV, matching
/// WebCrypto AES-CTR (`length: 64`) keystreams for all practical message
/// sizes (the low 64 bits cannot overflow). Keys are 32 bytes, IVs 16.
public enum AESCTR {
    /// Encrypt or decrypt (CTR is symmetric).
    public static func crypt(
        key: Data, iv: Data, input: Data
    ) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw .invalidKey("AES-256 needs 32 bytes, got \(key.count)")
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw .invalidKey("AES-CTR needs a 16-byte IV, got \(iv.count)")
        }
        guard !input.isEmpty else { return Data() }
        var cryptor: CCCryptorRef?
        let create = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    UInt32(kCCEncrypt),
                    UInt32(kCCModeCTR),
                    UInt32(kCCAlgorithmAES),
                    UInt32(ccNoPadding),
                    ivPtr.baseAddress, keyPtr.baseAddress, kCCKeySizeAES256,
                    nil, 0, 0, 0,
                    &cryptor)
            }
        }
        guard create == CCCryptorStatus(kCCSuccess), let cryptor else {
            throw .encryptionFailed("CCCryptorCreate status \(create)")
        }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: input.count)
        let outCapacity = out.count
        let inCount = input.count
        var moved = 0
        let update = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress, inCount,
                    outPtr.baseAddress, outCapacity,
                    &moved)
            }
        }
        guard update == CCCryptorStatus(kCCSuccess) else {
            throw .encryptionFailed("CCCryptorUpdate status \(update)")
        }
        var finalMoved = 0
        let final = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(
                cryptor,
                outPtr.baseAddress!.advanced(by: moved),
                outCapacity - moved,
                &finalMoved)
        }
        guard final == CCCryptorStatus(kCCSuccess) else {
            throw .encryptionFailed("CCCryptorFinal status \(final)")
        }
        return out.prefix(moved + finalMoved)
    }

    /// Encrypt (CTR has no padding; output matches input length).
    public static func encrypt(
        key: Data, iv: Data, plaintext: Data
    ) throws(CryptoError) -> Data {
        try crypt(key: key, iv: iv, input: plaintext)
    }

    /// Decrypt (identical to encrypt for CTR).
    public static func decrypt(
        key: Data, iv: Data, ciphertext: Data
    ) throws(CryptoError) -> Data {
        try crypt(key: key, iv: iv, input: ciphertext)
    }
}
