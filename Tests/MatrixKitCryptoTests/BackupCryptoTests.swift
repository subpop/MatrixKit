import Foundation
import Testing

@testable import MatrixKitCrypto

/// Recovery-key fixture from matrix-sdk-crypto (`base58_decoding` test).
private let fixtureKey: [UInt8] = [
    0x77, 0x07, 0x6D, 0x0A, 0x73, 0x18, 0xA5, 0x7D, 0x3C, 0x16, 0xC1, 0x72,
    0x51, 0xB2, 0x66, 0x45, 0xDF, 0x4C, 0x2F, 0x87, 0xEB, 0xC0, 0x99, 0x2A,
    0xB1, 0x77, 0xFB, 0xA5, 0x1D, 0xB9, 0x2C, 0x2A,
]
private let fixtureRecoveryKey = "EsTcLW2KPGiFwKEA3As5g5c4BXwkqeeJZJV8Q9fugUMNUE4d"

@Suite("Base58")
struct Base58Tests {
    @Test("Round-trips arbitrary bytes")
    func roundTrip() {
        let data = Data([0x00, 0x00, 0x01, 0x02, 0xFF, 0x00, 0x80])
        #expect(Base58.decode(Base58.encode(data)) == data)
    }

    @Test("Leading zeros encode as ones")
    func leadingZeros() {
        #expect(Base58.encode(Data([0x00, 0x00, 0x01])) == "112")
        #expect(Base58.decode("112") == Data([0x00, 0x00, 0x01]))
    }

    @Test("Invalid characters fail")
    func invalid() {
        #expect(Base58.decode("0OIl") == nil)
    }
}

@Suite("Backup recovery keys")
struct RecoveryKeyTests {
    @Test("Matches the reference vector, spaced or not")
    func referenceVector() throws {
        #expect(
            try BackupCrypto.parseRecoveryKey(fixtureRecoveryKey)
                == Data(fixtureKey))
        #expect(
            try BackupCrypto.parseRecoveryKey(
                "EsTc LW2K PGiF wKEA 3As5 g5c4 BXwk qeeJ ZJV8 Q9fu gUMN UE4d")
                == Data(fixtureKey))
    }

    @Test("Bad parity and prefix fail")
    func invalid() {
        #expect(throws: CryptoError.self) {
            try BackupCrypto.parseRecoveryKey(
                "EsTc LW2K PGiF wKEA 3As5 g5c4 BXwk qeeJ ZJV8 Q9fu gUMN UE4e")
        }
        #expect(throws: CryptoError.self) {
            try BackupCrypto.parseRecoveryKey("SSNc LW2K PGiF wKEA 3As5 g5c4 BXwk qeeJ ZJV8 Q9fu gUMN UE4d")
        }
    }

    @Test("Generated keys round-trip through display form")
    func roundTrip() throws {
        let privateKey = BackupCrypto.generatePrivateKey()
        let recovery = BackupCrypto.recoveryKey(privateKey: privateKey)
        #expect(try BackupCrypto.parseRecoveryKey(recovery) == privateKey)
        #expect(recovery.hasPrefix("Es"))
    }
}

@Suite("Backup session encryption")
struct BackupSessionTests {
    @Test("Encrypt/decrypt round-trips")
    func roundTrip() throws {
        let privateKey = BackupCrypto.generatePrivateKey()
        let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
        let plaintext = Data("backed-up session".utf8)
        let encrypted = try BackupCrypto.encryptSession(plaintext, publicKey: publicKey)
        let decrypted = try BackupCrypto.decryptSession(
            ciphertext: encrypted.ciphertext, mac: encrypted.mac,
            ephemeral: encrypted.ephemeral, privateKey: privateKey)
        #expect(decrypted == plaintext)
    }

    @Test("Tampered payload fails authentication")
    func tamper() throws {
        let privateKey = BackupCrypto.generatePrivateKey()
        let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
        let plaintext = Data("backed-up session".utf8)
        let encrypted = try BackupCrypto.encryptSession(plaintext, publicKey: publicKey)
        // The MAC covers the empty message (libolm quirk), so MAC
        // tampering throws while ciphertext tampering yields garbage.
        var badMac = encrypted
        badMac.mac[0] ^= 0xFF
        #expect(throws: CryptoError.self) {
            try BackupCrypto.decryptSession(
                ciphertext: badMac.ciphertext, mac: badMac.mac,
                ephemeral: badMac.ephemeral, privateKey: privateKey)
        }
        var badCiphertext = encrypted
        badCiphertext.ciphertext[0] ^= 0xFF
        let garbage = try? BackupCrypto.decryptSession(
            ciphertext: badCiphertext.ciphertext, mac: badCiphertext.mac,
            ephemeral: badCiphertext.ephemeral, privateKey: privateKey)
        #expect(garbage != plaintext)
    }

    @Test("Wrong key fails authentication")
    func wrongKey() throws {
        let privateKey = BackupCrypto.generatePrivateKey()
        let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
        let encrypted = try BackupCrypto.encryptSession(
            Data("backed-up session".utf8), publicKey: publicKey)
        #expect(throws: CryptoError.self) {
            try BackupCrypto.decryptSession(
                ciphertext: encrypted.ciphertext, mac: encrypted.mac,
                ephemeral: encrypted.ephemeral,
                privateKey: BackupCrypto.generatePrivateKey())
        }
    }

    @Test("Megolm exports survive backup encryption")
    func megolmExport() throws {
        var sender = MegolmSession.create()
        let blob = sender.export()
        let message = try sender.encrypt(Data("room message".utf8))

        let privateKey = BackupCrypto.generatePrivateKey()
        let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
        let encrypted = try BackupCrypto.encryptSession(blob, publicKey: publicKey)
        let decrypted = try BackupCrypto.decryptSession(
            ciphertext: encrypted.ciphertext, mac: encrypted.mac,
            ephemeral: encrypted.ephemeral, privateKey: privateKey)
        #expect(decrypted == blob)
        // The restored blob imports as a working session.
        var restored = try MegolmSession.importSessionKey(decrypted)
        #expect(try restored.decrypt(message) == Data("room message".utf8))
    }
}
