import Foundation

/// Errors thrown by `MatrixKitCrypto` operations.
///
/// Sessions use typed `throws(CryptoError)` throughout; the `KeyStore`
/// protocol deliberately uses untyped `throws` so each implementation
/// defines its own error type.
public enum CryptoError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A key was the wrong length or failed to parse.
    case invalidKey(String)
    /// A message failed structural parsing (truncation, bad varints, …).
    case malformedMessage(String)
    /// Message version byte other than `0x03` (Olm/Megolm) or unexpected
    /// session blob version.
    case unsupportedVersion(UInt8)
    /// The 8-byte HMAC did not match (tamper or wrong key).
    case macMismatch
    /// An Ed25519 signature did not verify.
    case invalidSignature
    /// A message index was already decrypted (replay).
    case replayDetected
    /// A message index predates the earliest retained ratchet state.
    case indexTooOld
    /// An inbound skip gap exceeds the safety bound.
    case gapTooLarge
    /// A pre-key message names a one-time key we do not hold.
    case unknownOneTimeKey
    /// A pre-key message names an identity key that does not match
    /// this session's peer.
    case identityMismatch
    /// An outbound-only operation (e.g. `sessionKey()`) on an inbound session.
    case notOutbound
    /// AES-CBC encryption/decryption failed at the CommonCrypto layer.
    case encryptionFailed(String)

    public var description: String {
        switch self {
        case .invalidKey(let why): return "Invalid key: \(why)"
        case .malformedMessage(let why): return "Malformed message: \(why)"
        case .unsupportedVersion(let v):
            return "Unsupported version: 0x\(String(v, radix: 16))"
        case .macMismatch: return "Message authentication failed"
        case .invalidSignature: return "Signature verification failed"
        case .replayDetected: return "Message index already decrypted"
        case .indexTooOld:
            return "Message predates earliest retained ratchet state"
        case .gapTooLarge: return "Inbound skip gap exceeds safety bound"
        case .unknownOneTimeKey: return "Unknown one-time key"
        case .identityMismatch:
            return "Pre-key identity does not match session peer"
        case .notOutbound:
            return "Operation requires an outbound session"
        case .encryptionFailed(let why): return "Encryption failed: \(why)"
        }
    }
}
