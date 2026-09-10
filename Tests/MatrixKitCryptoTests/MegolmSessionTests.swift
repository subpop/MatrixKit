import Foundation
import Testing

@testable import MatrixKitCrypto

/// Outbound→inbound group-ratchet flows.
@Suite("MegolmSession")
struct MegolmSessionTests {
    @Test("Round-trip: encrypt, share, import, decrypt in order")
    func roundTrip() throws {
        var outbound = MegolmSession.create()
        // Share first (counter 0), as in the real `m.room_key` flow.
        let blob = try outbound.sessionKey()
        #expect(blob.count == 229)
        #expect(blob[blob.startIndex] == 0x02)
        var inbound = try MegolmSession.importSessionKey(blob)
        #expect(inbound.id == outbound.id)
        #expect(inbound.counter == 0)
        var bodies: [Data] = []
        for i in 0..<5 {
            bodies.append(try outbound.encrypt(Data("m\(i)".utf8)))
        }
        #expect(outbound.counter == 5)
        for (i, body) in bodies.enumerated() {
            #expect(try inbound.decrypt(body) == Data("m\(i)".utf8))
        }
        #expect(inbound.counter == 4)
    }

    @Test("Skipped-forward then late and replayed messages")
    func gapsAndReplays() throws {
        var outbound = MegolmSession.create()
        let blob = try outbound.sessionKey()
        let bodies = try (0..<3).map { try outbound.encrypt(Data("m\($0)".utf8)) }
        var inbound = try MegolmSession.importSessionKey(blob)
        #expect(try inbound.decrypt(bodies[0]) == Data("m0".utf8))
        #expect(try inbound.decrypt(bodies[2]) == Data("m2".utf8))
        // Index 1 is older than the ratchet position: unrecoverable.
        do {
            _ = try inbound.decrypt(bodies[1])
            Issue.record("late message should throw")
        } catch let error {
            #expect(error == .indexTooOld)
        }
        // Index 2 was already decrypted.
        do {
            _ = try inbound.decrypt(bodies[2])
            Issue.record("replay should throw")
        } catch let error {
            #expect(error == .replayDetected)
        }
    }

    @Test("Any wire tamper fails the signature check")
    func tamper() throws {
        var outbound = MegolmSession.create()
        let body = try outbound.encrypt(Data("secret".utf8))
        var inbound = try MegolmSession.importSessionKey(
            try outbound.sessionKey())
        // The Ed25519 signature covers payload + MAC, so content flips
        // surface as invalidSignature (the HMAC is defense in depth);
        // flipping the version byte fails the version check first.
        for offset in [body.count / 2, body.count - 1] {
            var bad = body
            bad[offset] ^= 0xFF
            do {
                _ = try inbound.decrypt(bad)
                Issue.record("tamper at \(offset) should throw")
            } catch let error {
                #expect(error == .invalidSignature)
            }
        }
        var badVersion = body
        badVersion[badVersion.startIndex] ^= 0xFF
        do {
            _ = try inbound.decrypt(badVersion)
            Issue.record("version tamper should throw")
        } catch let error {
            #expect(error == .unsupportedVersion(0xFC))
        }
    }

    @Test("Malformed session blobs are rejected")
    func badSessionKey() throws {
        var outbound = MegolmSession.create()
        _ = try outbound.encrypt(Data("x".utf8))
        let blob = try outbound.sessionKey()
        do {
            _ = try MegolmSession.importSessionKey(blob.prefix(100))
            Issue.record("truncated blob should throw")
        } catch let error {
            #expect(error == .malformedMessage("Session-sharing blob must be 229 bytes"))
        }
        var badVersion = blob
        badVersion[badVersion.startIndex] = 0x09
        do {
            _ = try MegolmSession.importSessionKey(badVersion)
            Issue.record("bad version should throw")
        } catch let error {
            #expect(error == .unsupportedVersion(0x09))
        }
        var badSig = blob
        badSig[badSig.count - 1] ^= 0xFF
        do {
            _ = try MegolmSession.importSessionKey(badSig)
            Issue.record("bad signature should throw")
        } catch let error {
            #expect(error == .invalidSignature)
        }
    }

    @Test("Export round-trips position through the unsigned blob")
    func exportImport() throws {
        var outbound = MegolmSession.create()
        for i in 0..<3 {
            _ = try outbound.encrypt(Data("m\(i)".utf8))
        }
        let exported = outbound.export()
        #expect(exported.count == 165)
        #expect(exported[exported.startIndex] == 0x01)
        var inbound = try MegolmSession.importSessionKey(exported)
        #expect(inbound.counter == 3)
        #expect(inbound.id == outbound.id)
        let m3 = try outbound.encrypt(Data("m3".utf8))
        let m4 = try outbound.encrypt(Data("m4".utf8))
        #expect(try inbound.decrypt(m3) == Data("m3".utf8))
        #expect(try inbound.decrypt(m4) == Data("m4".utf8))
    }

    @Test("Mid-history sharing starts the inbound session at the counter")
    func midHistoryShare() throws {
        var outbound = MegolmSession.create()
        var bodies: [Data] = []
        for i in 0..<6 {
            bodies.append(try outbound.encrypt(Data("m\(i)".utf8)))
        }
        var inbound = try MegolmSession.importSessionKey(
            try outbound.sessionKey())
        #expect(inbound.counter == 6)
        do {
            _ = try inbound.decrypt(bodies[3])
            Issue.record("pre-counter message should throw")
        } catch let error {
            #expect(error == .indexTooOld)
        }
        // Messages sent after the share still decrypt.
        let m6 = try outbound.encrypt(Data("m6".utf8))
        let m7 = try outbound.encrypt(Data("m7".utf8))
        #expect(try inbound.decrypt(m6) == Data("m6".utf8))
        #expect(try inbound.decrypt(m7) == Data("m7".utf8))
    }

    @Test("Inbound sessions cannot encrypt or share")
    func notOutbound() throws {
        var outbound = MegolmSession.create()
        _ = try outbound.encrypt(Data("x".utf8))
        var inbound = try MegolmSession.importSessionKey(
            try outbound.sessionKey())
        do {
            _ = try inbound.encrypt(Data("nope".utf8))
            Issue.record("inbound encrypt should throw")
        } catch let error {
            #expect(error == .notOutbound)
        }
        do {
            _ = try inbound.sessionKey()
            Issue.record("inbound sessionKey should throw")
        } catch let error {
            #expect(error == .notOutbound)
        }
    }

    @Test("Ratchet crosses the 2^8 reseed boundary cleanly")
    func ratchetBoundary() throws {
        var outbound = MegolmSession.create()
        // Share before any message is sent: the inbound session steps
        // across the 256 reseed boundary while decrypting.
        let earlyBlob = try outbound.sessionKey()
        var bodies: [Data] = []
        for i in 0..<300 {
            bodies.append(try outbound.encrypt(Data("m\(i)".utf8)))
        }
        var inbound = try MegolmSession.importSessionKey(earlyBlob)
        for (i, body) in bodies.enumerated() {
            #expect(try inbound.decrypt(body) == Data("m\(i)".utf8))
        }
        #expect(inbound.counter == 299)
    }
}
