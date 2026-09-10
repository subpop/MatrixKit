import Crypto
import Foundation
import MatrixKitCrypto

/// Low-level cryptographic primitives for E2EE verification.
///
/// Wraps `swift-crypto` (SHA-256) and implements the Matrix wire
/// encodings it lacks: base58 (recovery keys), canonical JSON
/// (signing), and the SAS emoji/decimal tables. Ed25519 signing,
/// unpadded base64, and HKDF live in `MatrixKitCrypto`.
public enum CryptoPrimitives {}

// MARK: - Base58

extension CryptoPrimitives {
    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// Bitcoin-alphabet base58 (recovery-key display).
    public static func base58Encode(_ data: Data) -> String {
        var bytes = [UInt8](data)
        // Count leading zero bytes (each becomes a leading "1").
        let leadingZeros = bytes.prefix(while: { $0 == 0 }).count
        bytes.removeFirst(leadingZeros)
        var digits: [Int] = []
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        let encoded = digits.reversed().map { String(base58Alphabet[$0]) }.joined()
        return String(repeating: "1", count: leadingZeros) + encoded
    }

    /// Decode base58. Nil on invalid characters.
    public static func base58Decode(_ string: String) -> Data? {
        let leadingOnes = string.prefix(while: { $0 == "1" }).count
        var bytes: [UInt8] = []
        for char in string {
            guard let value = base58Alphabet.firstIndex(of: char) else { return nil }
            var carry = value
            for i in bytes.indices {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        bytes.reverse()
        return Data(repeating: 0, count: leadingOnes) + bytes
    }
}

// MARK: - Canonical JSON

extension CryptoPrimitives {
    /// Matrix canonical JSON: object keys sorted by codepoint, no
    /// whitespace, UTF-8. Only `String`/`Int`/`Bool`/null/array/object
    /// values are permitted (floats are rejected — signatures must be
    /// exact). Throws on unrepresentable values.
    public static func canonicalJSON(_ value: Any) throws(MatrixError) -> Data {
        guard let text = canonicalize(value) else {
            throw .encodingError("Value is not canonical-JSON encodable")
        }
        return Data(text.utf8)
    }

    private static func canonicalize(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return quoted(s)
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return String(i)
        case is NSNull:
            return "null"
        case let array as [Any]:
            let items = array.compactMap(canonicalize)
            guard items.count == array.count else { return nil }
            return "[" + items.joined(separator: ",") + "]"
        case let dict as [String: Any]:
            var parts: [String] = []
            for key in dict.keys.sorted() {
                guard let encoded = canonicalize(dict[key]!) else { return nil }
                guard let quotedKey = quoted(key) else { return nil }
                parts.append("\(quotedKey):\(encoded)")
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            return nil
        }
    }

    private static func quoted(_ string: String) -> String? {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: return nil
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

// MARK: - SAS emoji + decimals

/// One SAS emoji: the glyph plus its English description.
public struct SASEmoji: Hashable, Sendable {
    public let emoji: String
    public let description: String

    public init(emoji: String, description: String) {
        self.emoji = emoji
        self.description = description
    }
}

extension CryptoPrimitives {
    /// The 64-entry Matrix SAS emoji table (index = 6-bit value).
    public static let sasEmojiTable: [SASEmoji] = [
        SASEmoji(emoji: "🐶", description: "dog"),
        SASEmoji(emoji: "🐱", description: "cat"),
        SASEmoji(emoji: "🦁", description: "lion"),
        SASEmoji(emoji: "🐎", description: "horse"),
        SASEmoji(emoji: "🦄", description: "unicorn"),
        SASEmoji(emoji: "🐷", description: "pig"),
        SASEmoji(emoji: "🐘", description: "elephant"),
        SASEmoji(emoji: "🐰", description: "rabbit"),
        SASEmoji(emoji: "🐼", description: "panda"),
        SASEmoji(emoji: "🐓", description: "rooster"),
        SASEmoji(emoji: "🐧", description: "penguin"),
        SASEmoji(emoji: "🐢", description: "turtle"),
        SASEmoji(emoji: "🐟", description: "fish"),
        SASEmoji(emoji: "🐙", description: "octopus"),
        SASEmoji(emoji: "🦋", description: "butterfly"),
        SASEmoji(emoji: "🌷", description: "flower"),
        SASEmoji(emoji: "🌳", description: "tree"),
        SASEmoji(emoji: "🌵", description: "cactus"),
        SASEmoji(emoji: "🍄", description: "mushroom"),
        SASEmoji(emoji: "🌏", description: "globe"),
        SASEmoji(emoji: "🌙", description: "moon"),
        SASEmoji(emoji: "☁️", description: "cloud"),
        SASEmoji(emoji: "🔥", description: "fire"),
        SASEmoji(emoji: "🍌", description: "banana"),
        SASEmoji(emoji: "🍎", description: "apple"),
        SASEmoji(emoji: "🍓", description: "strawberry"),
        SASEmoji(emoji: "🌽", description: "corn"),
        SASEmoji(emoji: "🍕", description: "pizza"),
        SASEmoji(emoji: "🎂", description: "cake"),
        SASEmoji(emoji: "❤️", description: "heart"),
        SASEmoji(emoji: "😀", description: "smiley"),
        SASEmoji(emoji: "🤖", description: "robot"),
        SASEmoji(emoji: "🎩", description: "hat"),
        SASEmoji(emoji: "👓", description: "glasses"),
        SASEmoji(emoji: "🔧", description: "wrench"),
        SASEmoji(emoji: "🎅", description: "santa"),
        SASEmoji(emoji: "👍", description: "thumbs up"),
        SASEmoji(emoji: "☂️", description: "umbrella"),
        SASEmoji(emoji: "⌛", description: "hourglass"),
        SASEmoji(emoji: "⏰", description: "clock"),
        SASEmoji(emoji: "🎁", description: "gift"),
        SASEmoji(emoji: "💡", description: "light bulb"),
        SASEmoji(emoji: "📕", description: "book"),
        SASEmoji(emoji: "✏️", description: "pencil"),
        SASEmoji(emoji: "📎", description: "paperclip"),
        SASEmoji(emoji: "✂️", description: "scissors"),
        SASEmoji(emoji: "🔒", description: "lock"),
        SASEmoji(emoji: "🔑", description: "key"),
        SASEmoji(emoji: "🔨", description: "hammer"),
        SASEmoji(emoji: "☎️", description: "telephone"),
        SASEmoji(emoji: "🏁", description: "flag"),
        SASEmoji(emoji: "🚂", description: "train"),
        SASEmoji(emoji: "🚲", description: "bicycle"),
        SASEmoji(emoji: "✈️", description: "airplane"),
        SASEmoji(emoji: "🚀", description: "rocket"),
        SASEmoji(emoji: "🏆", description: "trophy"),
        SASEmoji(emoji: "⚽", description: "ball"),
        SASEmoji(emoji: "🎸", description: "guitar"),
        SASEmoji(emoji: "🎺", description: "trumpet"),
        SASEmoji(emoji: "🔔", description: "bell"),
        SASEmoji(emoji: "⚓️", description: "anchor"),
        SASEmoji(emoji: "🎧", description: "headphones"),
        SASEmoji(emoji: "📁", description: "folder"),
        SASEmoji(emoji: "📌", description: "pin"),
    ]

    /// Map 7 six-bit SAS values (from 6 SAS bytes) to emoji.
    public static func sasEmoji(indices: [UInt8]) -> [SASEmoji] {
        indices.prefix(7).map { sasEmojiTable[Int($0 & 0x3F)] }
    }

    /// Split 6 SAS bytes into 7 six-bit indices (42 bits, big-endian).
    public static func sasIndices(bytes: Data) -> [UInt8] {
        precondition(bytes.count >= 6)
        var indices: [UInt8] = []
        var acc = 0
        var bits = 0
        for byte in bytes.prefix(6) {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 6, indices.count < 7 {
                bits -= 6
                indices.append(UInt8((acc >> bits) & 0x3F))
            }
        }
        return indices
    }

    /// Decimal SAS: 5 bytes → three 13-bit numbers, each + 1000
    /// (displayed zero-padded to 4 digits).
    public static func sasDecimals(bytes: Data) -> [Int] {
        precondition(bytes.count >= 5)
        let b = Array(bytes.prefix(5))
        return [
            ((Int(b[0]) << 5) | (Int(b[1]) >> 3)) + 1000,
            (((Int(b[1]) & 0x07) << 10) | (Int(b[2]) << 2) | (Int(b[3]) >> 6)) + 1000,
            (((Int(b[3]) & 0x3F) << 7) | (Int(b[4]) >> 1)) + 1000,
        ]
    }
}
