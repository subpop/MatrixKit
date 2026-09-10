import Foundation

/// Base58 codec (Bitcoin alphabet), for recovery keys.
public enum Base58 {
    private static let alphabet =
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private static let ring: [Character: Int] = {
        var ring: [Character: Int] = [:]
        for (index, char) in alphabet.enumerated() {
            ring[char] = index
        }
        return ring
    }()

    /// Encode bytes (leading zero bytes become `1`s).
    public static func encode(_ data: Data) -> String {
        var zeros = 0
        for byte in data {
            guard byte == 0 else { break }
            zeros += 1
        }
        var number = Array(data)
        var encoded: [Character] = []
        var start = zeros
        while start < number.count {
            var remainder = 0
            for index in start..<number.count {
                let digit = remainder * 256 + Int(number[index])
                number[index] = UInt8(digit / 58)
                remainder = digit % 58
            }
            encoded.append(alphabet[alphabet.index(
                alphabet.startIndex, offsetBy: remainder)])
            while start < number.count && number[start] == 0 {
                start += 1
            }
        }
        return String(repeating: "1", count: zeros) + String(encoded.reversed())
    }

    /// Decode (nil on invalid characters).
    public static func decode(_ string: String) -> Data? {
        var zeros = 0
        for char in string {
            guard char == "1" else { break }
            zeros += 1
        }
        var number = Array(repeating: 0, count: string.count)
        var length = 0
        for char in string {
            guard let digit = ring[char] else { return nil }
            var carry = digit
            var index = 0
            while index < length || carry > 0 {
                let value = number[index] * 58 + carry
                number[index] = value & 0xFF
                carry = value >> 8
                index += 1
            }
            length = index
        }
        let body = number.prefix(length).reversed().map { UInt8($0) }
        return Data(repeating: 0, count: zeros) + body
    }
}
