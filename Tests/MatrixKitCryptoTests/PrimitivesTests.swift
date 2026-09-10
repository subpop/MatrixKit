import Foundation
import Testing

@testable import MatrixKitCrypto

func hex(_ string: String) -> Data {
    var data = Data()
    var i = string.startIndex
    while i < string.endIndex {
        let j = string.index(i, offsetBy: 2)
        data.append(UInt8(string[i..<j], radix: 16)!)
        i = j
    }
    return data
}

@Suite("Primitives")
struct PrimitivesTests {
    @Test("Unpadded base64 round-trips and rejects bad input")
    func base64() {
        #expect(Primitives.base64UnpaddedEncode(Data("hello".utf8)) == "aGVsbG8")
        #expect(Primitives.base64UnpaddedDecode("aGVsbG8") == Data("hello".utf8))
        #expect(Primitives.base64UnpaddedDecode("aGVsbG8=") == Data("hello".utf8))
        #expect(Primitives.base64UnpaddedDecode("a") == nil)
        #expect(Primitives.base64UnpaddedDecode("!!!") == nil)
    }

    @Test("HMAC-SHA-256 matches RFC 4231 test case 1")
    func hmac() {
        let mac = Primitives.hmacSHA256(
            key: Data(repeating: 0x0B, count: 20),
            message: Data("Hi There".utf8))
        #expect(
            mac
                == hex(
                    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
                ))
    }

    @Test("HKDF-SHA-256 matches RFC 5869 cases 1 and 3")
    func hkdf() {
        let ikm = Data(repeating: 0x0B, count: 22)
        let okm1 = Primitives.hkdfSHA256(
            inputKeyMaterial: ikm,
            salt: hex("000102030405060708090a0b0c"),
            info: hex("f0f1f2f3f4f5f6f7f8f9"),
            outputByteCount: 42)
        #expect(
            okm1
                == hex(
                    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
                ))
        // Empty salt/info is the spec default (HashLen zero bytes).
        let okm3 = Primitives.hkdfSHA256(
            inputKeyMaterial: ikm, salt: Data(), info: Data(),
            outputByteCount: 42)
        #expect(
            okm3
                == hex(
                    "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
                ))
    }

    @Test("Varints round-trip, including spec boundary values")
    func varints() throws {
        #expect(ProtoCoding.encodeVarint(0) == Data([0x00]))
        #expect(ProtoCoding.encodeVarint(127) == Data([0x7F]))
        #expect(ProtoCoding.encodeVarint(300) == Data([0xAC, 0x02]))
        for value: UInt64 in [
            0, 1, 127, 128, 300, 16384, UInt64(UInt32.max), UInt64.max,
        ] {
            let encoded = ProtoCoding.encodeVarint(value)
            let (decoded, next) = try ProtoCoding.decodeVarint(
                encoded, from: 0)
            #expect(decoded == value)
            #expect(next == encoded.count)
        }
        let fields = ProtoCoding.intField(number: 2, value: 300)
            + ProtoCoding.bytesField(number: 4, value: Data([1, 2, 3]))
        let decoded = try ProtoCoding.decodeFields(fields)
        #expect(decoded.count == 2)
        guard case .int(300) = decoded[0].field else {
            Issue.record("int field misdecoded")
            return
        }
        guard case .bytes(let bytes) = decoded[1].field else {
            Issue.record("bytes field misdecoded")
            return
        }
        #expect(bytes == Data([1, 2, 3]))
    }

    @Test("AES-256-CBC matches FIPS-197 Appendix B (zero IV)")
    func aesVector() throws {
        // Sequential key/plaintext: unambiguous, cross-checked with
        // `openssl enc -aes-256-cbc` (CBC with a zero IV agrees with ECB
        // on the first block; the second block is the padding block).
        let key = hex(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let iv = Data(repeating: 0, count: 16)
        let plaintext = hex("00112233445566778899aabbccddeeff")
        let ciphertext = try AESCBC.encrypt(
            key: key, iv: iv, plaintext: plaintext)
        #expect(ciphertext.count == 32)
        #expect(
            ciphertext
                == hex(
                    "8ea2b7ca516745bfeafc49904b496089"
                        + "56423350859cf424d4459534a8f5aaf2"))
        #expect(
            try AESCBC.decrypt(key: key, iv: iv, ciphertext: ciphertext)
                == plaintext)
    }

    @Test("AES round-trips arbitrary lengths and rejects bad keys")
    func aesRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8($0) })
        for length in [0, 1, 15, 16, 17, 100] {
            let pt = Data((0..<length).map { UInt8($0 & 0xFF) })
            let ct = try AESCBC.encrypt(key: key, iv: iv, plaintext: pt)
            #expect(ct.count == ((length / 16) + 1) * 16)
            #expect(try AESCBC.decrypt(key: key, iv: iv, ciphertext: ct) == pt)
        }
        do {
            _ = try AESCBC.encrypt(
                key: Data(repeating: 0, count: 16), iv: iv,
                plaintext: Data())
            Issue.record("short key should throw")
        } catch let error {
            #expect(error == .invalidKey("AES-256 needs 32 bytes, got 16"))
        }
    }

    @Test("SigningKey signs and verifies; garbage fails")
    func signingKey() throws {        let key = SigningKey.generate()
        let message = Data("megolm session".utf8)
        let signature = try key.sign(message)
        #expect(signature.count == 64)
        #expect(
            SigningKey.verify(
                signature: signature, for: message,
                publicKey: key.publicKeyBytes))
        #expect(
            !SigningKey.verify(
                signature: signature, for: Data("tampered".utf8),
                publicKey: key.publicKeyBytes))
        var badSig = signature
        badSig[0] ^= 0xFF
        #expect(
            !SigningKey.verify(
                signature: badSig, for: message,
                publicKey: key.publicKeyBytes))
        let restored = try SigningKey.restore(
            privateKeyBytes: Primitives.base64UnpaddedDecode(
                key.privateKeyBase64)!)
        #expect(restored.publicKeyBytes == key.publicKeyBytes)
    }

    @Test("X25519 matches RFC 7748 section 6.1, both directions")
    func x25519Vectors() throws {
        let aliceSecret = hex(
            "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let alicePublic = hex(
            "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bobSecret = hex(
            "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let bobPublic = hex(
            "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = hex(
            "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        #expect(
            try Primitives.x25519(private: aliceSecret, public: bobPublic)
                == shared)
        #expect(
            try Primitives.x25519(private: bobSecret, public: alicePublic)
                == shared)
    }

    // swift-crypto's `signature(for:)` deliberately randomizes (per
    // CryptoKit docs), so byte-exact signing is untestable through it.
    // Instead: the RFC public keys derive from the seeds, the published
    // RFC signatures verify through our `verify` path, and our own
    // sign→verify round-trip is covered elsewhere.
    @Test("Ed25519 RFC 8032 pubkeys derive; published sigs verify")
    func ed25519Vectors() throws {
        let vectors: [(secret: String, public: String, message: String, sig: String)] = [
            (
                "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
                "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                "",
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                    + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
            ),
            (
                "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
                "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                "72",
                "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                    + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
            ),
            (
                "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
                "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
                "af82",
                "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
                    + "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
            ),
        ]
        for vector in vectors {
            let key = try SigningKey.restore(
                privateKeyBytes: hex(vector.secret))
            #expect(key.publicKeyBytes == hex(vector.public))
            #expect(
                SigningKey.verify(
                    signature: hex(vector.sig),
                    for: hex(vector.message),
                    publicKey: hex(vector.public)))
            // Our own signatures verify too (value randomized, but valid).
            let ours = try key.sign(hex(vector.message))
            #expect(ours.count == 64)
            #expect(
                SigningKey.verify(
                    signature: ours, for: hex(vector.message),
                    publicKey: key.publicKeyBytes))
        }
    }

    @Test("PBKDF2-SHA-512 matches Python hashlib vectors")
    func pbkdf2() {
        let vectors: [(password: String, salt: String, iterations: Int, dk: String)] = [
            (
                "password", "73616c74", 1,
                "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252"
            ),
            (
                "password", "73616c74", 2,
                "e1d9c16aa681708a45f5c7c4e215ceb66e011a2e9f0040713f18aefdb866d53c"
            ),
            (
                "correct horse battery staple", "0011223344556677", 500000,
                "36f70be54949ad7bab1492e7fb6ca5006fc48de93d0b27369d25401db7da08b6"
            ),
        ]
        for vector in vectors {
            #expect(
                Primitives.pbkdf2SHA512(
                    password: Data(vector.password.utf8), salt: hex(vector.salt),
                    iterations: vector.iterations, outputByteCount: 32)
                    == hex(vector.dk))
        }
    }
}
