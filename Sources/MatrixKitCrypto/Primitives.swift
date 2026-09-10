#if canImport(CommonCrypto)
import CommonCrypto
#else
#error("MatrixKitCrypto requires CommonCrypto (Apple platforms only)")
#endif
import Crypto
import Foundation

/// Shared low-level primitives for the Olm/Megolm ratchets.
///
/// Wraps `swift-crypto` (HMAC-SHA-256, HKDF-SHA-256) and implements the
/// Matrix wire encodings it lacks: unpadded base64 and the protobuf-like
/// varint field encoding used by Olm/Megolm payloads.
public enum Primitives {}

// MARK: - Base64 (unpadded)

extension Primitives {
    /// Matrix base64: standard alphabet, no `=` padding.
    public static func base64UnpaddedEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Decode unpadded (or padded) base64. Nil on malformed input.
    public static func base64UnpaddedDecode(_ string: String) -> Data? {
        var padded = string
        let remainder = padded.count % 4
        if remainder == 1 { return nil }
        padded += String(repeating: "=", count: (4 - remainder) % 4)
        return Data(base64Encoded: padded)
    }

    /// JWK base64url: URL-safe alphabet, no `=` padding.
    public static func base64URLEncode(_ data: Data) -> String {
        base64UnpaddedEncode(data)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Decode base64url (unpadded). Nil on malformed input.
    public static func base64URLDecode(_ string: String) -> Data? {
        base64UnpaddedDecode(
            string
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/"))
    }
}

// MARK: - HMAC-SHA256 / HKDF-SHA256

extension Primitives {
    /// Raw SHA-256 digest.
    public static func sha256(_ data: Data) -> Data {
        Data(Crypto.SHA256.hash(data: data))
    }
    /// `HMAC-SHA-256(key, message)`.
    public static func hmacSHA256(key: Data, message: Data) -> Data {
        let code = Crypto.HMAC<Crypto.SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }

    /// `HKDF-SHA256(ikm, salt, info)` → `outputByteCount` bytes.
    ///
    /// Pass an empty `salt` for the spec's "0"/default salt (RFC 5869:
    /// HashLen zero bytes).
    public static func hkdfSHA256(
        inputKeyMaterial: Data, salt: Data, info: Data, outputByteCount: Int
    ) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Constant-time equality (MAC/signature comparison).
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
    }

    /// `PBKDF2-HMAC-SHA-512(password, salt, iterations)` → `outputByteCount`
    /// bytes (RFC 2898). Used to stretch a 4S security passphrase into the
    /// 32-byte secret-storage key; recovery keys skip this step.
    public static func pbkdf2SHA512(
        password: Data, salt: Data, iterations: Int, outputByteCount: Int
    ) -> Data {
        var out = Data(count: outputByteCount)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputByteCount)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed with status \(status)")
        return out
    }

    /// Raw X25519 Diffie-Hellman: the 32-byte shared secret for a
    /// private key and a peer public key (RFC 7748).
    ///
    /// Internal seam for vector tests; sessions use this same path
    /// through `OlmSession`.
    static func x25519(
        private privateBytes: Data, public publicBytes: Data
    ) throws(CryptoError) -> Data {
        do {
            let `private` = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateBytes)
            let publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: publicBytes)
            let secret = try `private`.sharedSecretFromKeyAgreement(
                with: publicKey)
            return secret.withUnsafeBytes { Data($0) }
        } catch let error as CryptoError {
            throw error
        } catch {
            throw .invalidKey("X25519 failed: \(error)")
        }
    }
}

// MARK: - Varint field encoding (Olm/Megolm payloads)

/// A decoded protobuf-like field value: integer or length-delimited bytes.
public enum ProtoField: Sendable, Hashable {
    case int(UInt64)
    case bytes(Data)
}

/// Encode/decode for the Olm/Megolm payload format: each value is a
/// variable-length integer tag `(fieldNumber << 3) | wireType` (`0` = int,
/// `2` = string) followed by the value. Integers are 7-bit groups,
/// least-significant first, with the high bit as continuation flag.
public enum ProtoCoding {
    /// Encode an unsigned integer, 7 bits per byte, MSB continuation.
    public static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Decode one varint at `offset`. Returns the value and next offset.
    ///
    /// The input is normalized first: `Data` slices (e.g. from
    /// `dropFirst`) carry a non-zero `startIndex`, which would trap
    /// integer-offset subscripting.
    public static func decodeVarint(
        _ data: Data, from offset: Int
    ) throws(CryptoError) -> (value: UInt64, next: Int) {
        let data = Data(data)
        var result: UInt64 = 0
        var shift = 0
        var i = offset
        while true {
            guard i < data.count else {
                throw .malformedMessage("Truncated varint")
            }
            guard shift < 64 else {
                throw .malformedMessage("Varint overflow")
            }
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { return (result, i) }
        }
    }

    /// Encode an integer field (`wire type 0`).
    public static func intField(number: UInt8, value: UInt64) -> Data {
        encodeVarint((UInt64(number) << 3) | 0) + encodeVarint(value)
    }

    /// Encode a byte-string field (`wire type 2`).
    public static func bytesField(number: UInt8, value: Data) -> Data {
        encodeVarint((UInt64(number) << 3) | 2)
            + encodeVarint(UInt64(value.count)) + value
    }

    /// Decode all fields of a payload. Unknown wire types throw.
    /// Normalizes `Data` slices (see `decodeVarint`).
    public static func decodeFields(
        _ data: Data
    ) throws(CryptoError) -> [(number: UInt8, field: ProtoField)] {
        let data = Data(data)
        var out: [(UInt8, ProtoField)] = []
        var i = 0
        while i < data.count {
            let (tag, afterTag) = try decodeVarint(data, from: i)
            i = afterTag
            let rawNumber = tag >> 3
            guard rawNumber <= UInt64(UInt8.max) else {
                throw .malformedMessage("Field number out of range")
            }
            let number = UInt8(rawNumber)
            switch tag & 0x07 {
            case 0:
                let (value, next) = try decodeVarint(data, from: i)
                i = next
                out.append((number, .int(value)))
            case 2:
                let (length, afterLength) = try decodeVarint(data, from: i)
                i = afterLength
                guard length <= UInt64(data.count - i) else {
                    throw .malformedMessage("Truncated string field")
                }
                let end = i + Int(length)
                out.append((number, .bytes(data[i..<end])))
                i = end
            default:
                throw .malformedMessage("Unsupported wire type")
            }
        }
        return out
    }
}
