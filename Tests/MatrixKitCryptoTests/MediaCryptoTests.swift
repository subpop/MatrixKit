import Foundation
import Testing

@testable import MatrixKitCrypto

@Suite("AES-CTR")
struct AESCTRTests {
    @Test("Round-trips arbitrary lengths")
    func roundTrip() throws {
        let key = Data(repeating: 0x42, count: 32)
        let iv = Data(repeating: 0x07, count: 16)
        for length in [0, 1, 15, 16, 17, 100] {
            let plaintext = Data((0..<length).map { UInt8($0 & 0xFF) })
            let ciphertext = try AESCTR.encrypt(key: key, iv: iv, plaintext: plaintext)
            #expect(ciphertext.count == length)
            #expect(try AESCTR.decrypt(key: key, iv: iv, ciphertext: ciphertext) == plaintext)
        }
    }

    @Test("Keystream varies with key and IV")
    func uniqueness() throws {
        let plaintext = Data(repeating: 0x00, count: 32)
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x43, count: 32)
        let iv = Data(repeating: 0x07, count: 16)
        let otherIv = Data(repeating: 0x08, count: 16)
        let base = try AESCTR.encrypt(key: key, iv: iv, plaintext: plaintext)
        #expect(try AESCTR.encrypt(key: otherKey, iv: iv, plaintext: plaintext) != base)
        #expect(try AESCTR.encrypt(key: key, iv: otherIv, plaintext: plaintext) != base)
    }

    @Test("Rejects bad key and IV sizes")
    func sizes() {
        #expect(throws: CryptoError.self) {
            try AESCTR.encrypt(
                key: Data(repeating: 0, count: 16), iv: Data(repeating: 0, count: 16),
                plaintext: Data([1]))
        }
        #expect(throws: CryptoError.self) {
            try AESCTR.encrypt(
                key: Data(repeating: 0, count: 32), iv: Data(repeating: 0, count: 8),
                plaintext: Data([1]))
        }
    }
}

@Suite("Base64URL")
struct Base64URLTests {
    @Test("Round-trips with URL-safe alphabet")
    func roundTrip() {
        let data = Data([0xFB, 0xFF, 0xBE, 0x00, 0x80])
        let encoded = Primitives.base64URLEncode(data)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(Primitives.base64URLDecode(encoded) == data)
    }

    @Test("Known vector")
    func vector() {
        // {"kty":"oct"} -> base64url (unpadded).
        #expect(Primitives.base64URLEncode(Data("{\"kty\":\"oct\"}".utf8)) == "eyJrdHkiOiJvY3QifQ")
    }
}
