import Foundation
import Testing

import MatrixKitCrypto

@testable import MatrixKit

@Suite("Encrypted media")
struct EncryptedMediaTests {
    @Test("File dict decodes the wire shape")
    func fileDecode() throws {
        let json = """
        {"body": "pic.png", "msgtype": "m.image",
         "file": {"url": "mxc://x/enc", "v": "v2",
                  "key": {"kty": "oct", "key_ops": ["encrypt", "decrypt"],
                          "alg": "A256CTR", "k": "key", "ext": true},
                  "iv": "AAAAAAAAAAAAAAAAAAAAAA",
                  "hashes": {"sha256": "hash"}},
         "info": {"mimetype": "image/png", "w": 100, "h": 50,
                  "thumbnail_file": {"url": "mxc://x/thumb", "v": "v2",
                    "key": {"kty": "oct", "key_ops": ["encrypt", "decrypt"],
                            "alg": "A256CTR", "k": "key", "ext": true},
                    "iv": "AAAAAAAAAAAAAAAAAAAAAA",
                    "hashes": {"sha256": "thash"}}}}
        """.data(using: .utf8)!
        let content = try JSONDecoder().decode(MessageContent.self, from: json)
        #expect(content.msgtype == .image)
        #expect(content.url == nil)
        #expect(content.file?.url == "mxc://x/enc")
        #expect(content.file?.key.algorithm == "A256CTR")
        #expect(content.file?.hashes["sha256"] == "hash")
        #expect(content.info?.thumbnailFile?.url == "mxc://x/thumb")
    }

    @Test("Encrypt then decrypt round-trips bytes")
    func roundTrip() throws {
        let plaintext = Data("encrypted pixels".utf8)
        let encrypted = try MediaClient.encryptFile(plaintext)
        #expect(encrypted.key.algorithm == "A256CTR")
        #expect(encrypted.key.keyType == "oct")
        #expect(encrypted.key.extractable)
        let file = EncryptedFile(
            url: "mxc://x/enc", key: encrypted.key, iv: encrypted.iv,
            hashes: ["sha256": encrypted.hash])
        #expect(try MediaClient.decryptFile(encrypted.ciphertext, file: file) == plaintext)
    }

    @Test("Hash mismatch throws")
    func hashMismatch() throws {
        let encrypted = try MediaClient.encryptFile(Data("pixels".utf8))
        let file = EncryptedFile(
            url: "mxc://x/enc", key: encrypted.key, iv: encrypted.iv,
            hashes: ["sha256": encrypted.hash])
        var tampered = encrypted.ciphertext
        tampered[0] ^= 0xFF
        #expect(throws: MatrixError.self) {
            try MediaClient.decryptFile(tampered, file: file)
        }
    }

    @Test("Malformed keys throw")
    func malformed() {
        let file = EncryptedFile(
            url: "mxc://x/enc",
            key: AttachmentKey(key: "!!!"),
            iv: "AgMEBQYHCAk")
        #expect(throws: MatrixError.self) {
            try MediaClient.decryptFile(Data([1, 2, 3]), file: file)
        }
    }

    @Test("Encrypt emits wire-shaped v2: 16-byte IV, standard base64")
    func encryptIsV2() throws {
        let plaintext = Data((0..<100).map { UInt8($0 & 0xFF) })
        let encrypted = try MediaClient.encryptFile(plaintext)
        // The reference library uses standard (not URL-safe) base64 for
        // iv/hash, and a 16-byte counter block with the low half zeroed.
        let standard = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/"))
        #expect(encrypted.iv.unicodeScalars.allSatisfy { standard.contains($0) })
        #expect(encrypted.hash.unicodeScalars.allSatisfy { standard.contains($0) })
        let iv = Primitives.base64UnpaddedDecode(encrypted.iv)
        #expect(iv?.count == 16)
        #expect(iv?.suffix(8) == Data(repeating: 0, count: 8))
        // Keystream matches the v2 construction over our CTR primitive.
        let key = Primitives.base64URLDecode(encrypted.key.key)!
        #expect(
            try AESCTR.encrypt(key: key, iv: iv!, plaintext: plaintext, counterBits: 64)
                == encrypted.ciphertext)
        let file = EncryptedFile(
            url: "mxc://x/enc", key: encrypted.key, iv: encrypted.iv,
            hashes: ["sha256": encrypted.hash])
        #expect(try MediaClient.decryptFile(encrypted.ciphertext, file: file) == plaintext)
    }

    /// Verbatim from matrix-encrypt-attachment/test/decrypt.Spec.js.
    /// The v1/v0 pair shares IV and plaintext but not ciphertext: the
    /// counter width is load-bearing, so this pins it exactly.
    struct DecryptVector: Sendable {
        var ciphertext: String
        var iv: String
        var key: String
        var sha256: String
        var plaintext: String
        var version: String
    }

    static let decryptVectors: [DecryptVector] = [
        DecryptVector(
            ciphertext: "",
            iv: "AAAAAAAAAAAAAAAAAAAAAA",
            key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            sha256: "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
            plaintext: "", version: "v2"),
        DecryptVector(
            ciphertext: "5xJZTt5cQicm+9f4",
            iv: "//////////8AAAAAAAAAAA",
            key: "__________________________________________8",
            sha256: "YzF08lARDdOCzJpzuSwsjTNlQc4pHxpdHcXiD/wpK6k",
            plaintext: "SGVsbG8sIFdvcmxk", version: "v2"),
        DecryptVector(
            ciphertext: "zhtFStAeFx0s+9L/sSQO+WQMtldqYEHqTxMduJrCIpnkyer09kxJJuA4K+adQE4w+7jZe/vR9kIcqj9rOhDR8Q",
            iv: "//////////8AAAAAAAAAAA",
            key: "__________________________________________8",
            sha256: "IOq7/dHHB+mfHfxlRY5XMeCWEwTPmlf4cJcgrkf6fVU",
            plaintext: "YWxwaGFudW1lcmljYWxseWFscGhhbnVtZXJpY2FsbHlhbHBoYW51bWVyaWNhbGx5YWxwaGFudW1lcmljYWxseQ",
            version: "v2"),
        DecryptVector(
            ciphertext: "tJVNBVJ/vl36UQt4Y5e5m84bRUrQHhcdLPvS/7EkDvlkDLZXamBB6k8THbiawiKZ5Mnq9PZMSSbgOCvmnUBOMA",
            iv: "/////////////////////w",
            key: "__________________________________________8",
            sha256: "LYG/orOViuFwovJpv2YMLSsmVKwLt7pY3f8SYM7KU5E",
            plaintext: "YWxwaGFudW1lcmljYWxseWFscGhhbnVtZXJpY2FsbHlhbHBoYW51bWVyaWNhbGx5YWxwaGFudW1lcmljYWxseQ",
            version: "v1"),
        DecryptVector(
            ciphertext: "tJVNBVJ/vl36UQt4Y5e5myqUL3M8OtjRVQljZ+LlwbJeucRIM7CeKDJGGOjlJ1bqpqUdl6zytXJ3dCyvnUi4eQ",
            iv: "/////////////////////w",
            key: "__________________________________________8",
            sha256: "/K4w3G4zlLK312k66KxNPKDkWCn2QAH5aphAkuncTrQ",
            plaintext: "YWxwaGFudW1lcmljYWxseWFscGhhbnVtZXJpY2FsbHlhbHBoYW51bWVyaWNhbGx5YWxwaGFudW1lcmljYWxseQ",
            version: "v0"),
    ]

    @Test("Decrypts matrix-encrypt-attachment official vectors", arguments: decryptVectors)
    func decryptOfficialVectors(_ vector: DecryptVector) throws {
        let file = EncryptedFile(
            url: "mxc://x/enc",
            key: AttachmentKey(key: vector.key),
            iv: vector.iv,
            hashes: ["sha256": vector.sha256],
            version: vector.version)
        #expect(
            try MediaClient.decryptFile(
                Primitives.base64UnpaddedDecode(vector.ciphertext)!,
                file: file)
                == Primitives.base64UnpaddedDecode(vector.plaintext)!)
    }

    @Test("File dict without v decodes as v0")
    func missingVersionIsV0() throws {
        let json = """
        {"url": "mxc://x/enc",
         "key": {"kty": "oct", "key_ops": ["encrypt", "decrypt"],
                 "alg": "A256CTR", "k": "key", "ext": true},
         "iv": "/////////////////////w",
         "hashes": {"sha256": "hash"}}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(EncryptedFile.self, from: json)
        #expect(file.version == "v0")
    }

}
