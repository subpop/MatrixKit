#if canImport(CommonCrypto)
import CommonCrypto
#else
#error("MatrixKitCrypto requires CommonCrypto (Apple platforms only)")
#endif
import Foundation

/// AES-256-CTR via CommonCrypto (no padding).
///
/// - Parameter counterBits: width of the advancing counter. `64` uses
///   CommonCrypto's CTR mode, which advances only the low 64 bits of the
///   16-byte block (verified empirically, including across the low-half
///   wrap) — exactly WebCrypto AES-CTR (`length: 64`) as used by attachment
///   protocol v1/v2. `128` advances the full block big-endian by hand for
///   attachment protocol v0 (and secret storage), which CommonCrypto
///   cannot express.
/// Keys are 32 bytes, IVs 16.
public enum AESCTR {
    /// Encrypt or decrypt (CTR is symmetric).
    public static func crypt(
        key: Data, iv: Data, input: Data, counterBits: Int = 128
    ) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw .invalidKey("AES-256 needs 32 bytes, got \(key.count)")
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw .invalidKey("AES-CTR needs a 16-byte IV, got \(iv.count)")
        }
        guard counterBits == 64 || counterBits == 128 else {
            throw .invalidKey("AES-CTR counter is 64 or 128 bits, got \(counterBits)")
        }
        guard !input.isEmpty else { return Data() }
        if counterBits == 64 {
            return try cryptCommonCrypto(key: key, iv: iv, input: input)
        }
        return try cryptFull128(key: key, iv: iv, input: input)
    }

    /// CommonCrypto CTR: advances the low 64 bits only.
    private static func cryptCommonCrypto(
        key: Data, iv: Data, input: Data
    ) throws(CryptoError) -> Data {
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
        key: Data, iv: Data, plaintext: Data, counterBits: Int = 128
    ) throws(CryptoError) -> Data {
        try crypt(key: key, iv: iv, input: plaintext, counterBits: counterBits)
    }

    /// Decrypt (identical to encrypt for CTR).
    public static func decrypt(
        key: Data, iv: Data, ciphertext: Data, counterBits: Int = 128
    ) throws(CryptoError) -> Data {
        try crypt(key: key, iv: iv, input: ciphertext, counterBits: counterBits)
    }

    /// CTR with a full 128-bit big-endian counter: the keystream block is
    /// `AES-ECB(key, counter)` with the whole 16-byte counter advancing.
    /// CommonCrypto's CTR mode only advances the low 64 bits, so v0 (and
    /// secret storage) encrypt each counter value by hand.
    private static func cryptFull128(
        key: Data, iv: Data, input: Data
    ) throws(CryptoError) -> Data {
        var cryptor: CCCryptorRef?
        let create = key.withUnsafeBytes { keyPtr in
            CCCryptorCreateWithMode(
                UInt32(kCCEncrypt),
                UInt32(kCCModeECB),
                UInt32(kCCAlgorithmAES),
                UInt32(ccNoPadding),
                nil,
                keyPtr.baseAddress, kCCKeySizeAES256,
                nil, 0, 0, 0,
                &cryptor)
        }
        guard create == CCCryptorStatus(kCCSuccess), let cryptor else {
            throw .encryptionFailed("CCCryptorCreate status \(create)")
        }
        defer { CCCryptorRelease(cryptor) }
        var counter = [UInt8](iv)
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var offset = input.startIndex
        while offset < input.endIndex {
            var block = Data(count: kCCBlockSizeAES128)
            var moved = 0
            let status = block.withUnsafeMutableBytes { blockPtr in
                counter.withUnsafeBytes { counterPtr in
                    CCCryptorUpdate(
                        cryptor,
                        counterPtr.baseAddress, kCCBlockSizeAES128,
                        blockPtr.baseAddress, kCCBlockSizeAES128,
                        &moved)
                }
            }
            guard status == CCCryptorStatus(kCCSuccess), moved == kCCBlockSizeAES128 else {
                throw .encryptionFailed("CCCryptorUpdate status \(status)")
            }
            let end = input.index(offset, offsetBy: kCCBlockSizeAES128, limitedBy: input.endIndex) ?? input.endIndex
            out.append(contentsOf: zip(block, input[offset..<end]).map { $0 ^ $1 })
            incrementFull128(&counter)
            offset = end
        }
        return Data(out)
    }

    /// Big-endian increment over the full 16-byte counter.
    private static func incrementFull128(_ counter: inout [UInt8]) {
        var index = 15
        while index >= 0 {
            counter[index] &+= 1
            if counter[index] != 0 { break }
            index -= 1
        }
    }
}
