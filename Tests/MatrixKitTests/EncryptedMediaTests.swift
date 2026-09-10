import Foundation
import Testing

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
            iv: "AAAAAAAAAAAAAAAAAAAAAA")
        #expect(throws: MatrixError.self) {
            try MediaClient.decryptFile(Data([1, 2, 3]), file: file)
        }
    }
}
