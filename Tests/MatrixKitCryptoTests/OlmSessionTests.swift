import Crypto
import Foundation
import Testing

@testable import MatrixKitCrypto

// `Crypto` (swift-crypto) also exports a `CryptoError` typealias;
// pin the name to ours in this file.
typealias CryptoError = MatrixKitCrypto.CryptoError

/// Alice↔Bob Double-Ratchet flows over real X25519 keys.
@Suite("OlmSession")
struct OlmSessionTests {
    private func identities() -> (
        alice: Curve25519.KeyAgreement.PrivateKey,
        bob: Curve25519.KeyAgreement.PrivateKey,
        bobOneTime: Curve25519.KeyAgreement.PrivateKey
    ) {
        (
            Curve25519.KeyAgreement.PrivateKey(),
            Curve25519.KeyAgreement.PrivateKey(),
            Curve25519.KeyAgreement.PrivateKey()
        )
    }

    private func pub(
        _ key: Curve25519.KeyAgreement.PrivateKey
    ) -> Data {
        Data(key.publicKey.rawRepresentation)
    }

    private func handshake() throws -> (
        alice: OlmSession, bob: OlmSession,
        aliceID: Curve25519.KeyAgreement.PrivateKey,
        bobID: Curve25519.KeyAgreement.PrivateKey
    ) {
        let ids = identities()
        var alice = try OlmSession.createOutbound(
            ourIdentity: ids.alice, theirIdentityKey: pub(ids.bob),
            theirOneTimeKey: pub(ids.bobOneTime))
        let (type, first) = try alice.encrypt(Data("hello bob".utf8))
        #expect(type == .preKey)
        var bob = try OlmSession.createInbound(
            ourIdentity: ids.bob, oneTimeKeys: [ids.bobOneTime],
            message: first)
        #expect(try bob.decrypt(first) == Data("hello bob".utf8))
        return (alice, bob, ids.alice, ids.bob)
    }

    @Test("Pre-key handshake then alternating conversation")
    func conversation() throws {
        var (alice, bob, _, _) = try handshake()
        for i in 0..<20 {
            let text = Data("a\(i)".utf8)
            let (typeA, bodyA) = try alice.encrypt(text)
            // Alice's sends stay pre-key until Bob's first reply lands.
            #expect(typeA == (i == 0 ? .preKey : .normal))
            #expect(try bob.decrypt(bodyA) == text)
            let reply = Data("b\(i)".utf8)
            let (typeB, bodyB) = try bob.encrypt(reply)
            #expect(typeB == .normal)
            #expect(try alice.decrypt(bodyB) == reply)
        }
    }

    @Test("Out-of-order messages decrypt via skipped keys")
    func outOfOrder() throws {
        var (alice, bob, _, _) = try handshake()
        var bodies: [Data] = []
        for i in 0..<3 {
            bodies.append(try alice.encrypt(Data("m\(i)".utf8)).body)
        }
        #expect(try bob.decrypt(bodies[2]) == Data("m2".utf8))
        #expect(try bob.decrypt(bodies[0]) == Data("m0".utf8))
        #expect(try bob.decrypt(bodies[1]) == Data("m1".utf8))
    }

    @Test("Replays are rejected")
    func replay() throws {
        var (alice, bob, _, _) = try handshake()
        let body = try alice.encrypt(Data("once".utf8)).body
        #expect(try bob.decrypt(body) == Data("once".utf8))
        do {
            _ = try bob.decrypt(body)
            Issue.record("replay should throw")
        } catch let error {
            #expect(error == .replayDetected)
        }
    }

    @Test("Tampered MAC and ciphertext are rejected")
    func tamper() throws {
        var (alice, bob, _, _) = try handshake()
        // Advance past the pre-key phase so the tampered message is a
        // normal one (flipping envelope bytes would trip the identity
        // check instead of the MAC).
        let firstReply = try bob.encrypt(Data("ack".utf8)).body
        #expect(try alice.decrypt(firstReply) == Data("ack".utf8))
        let body = try alice.encrypt(Data("secret".utf8)).body
        var badMAC = body
        badMAC[badMAC.count - 1] ^= 0xFF
        do {
            _ = try bob.decrypt(badMAC)
            Issue.record("bad MAC should throw")
        } catch let error {
            #expect(error == .macMismatch)
        }
        var badCt = body
        badCt[badCt.count / 2] ^= 0xFF
        do {
            _ = try bob.decrypt(badCt)
            Issue.record("bad ciphertext should throw")
        } catch let error {
            #expect(error == .macMismatch)
        }
    }

    @Test("Unknown one-time key fails inbound setup")
    func unknownOneTimeKey() throws {
        let ids = identities()
        var alice = try OlmSession.createOutbound(
            ourIdentity: ids.alice, theirIdentityKey: pub(ids.bob),
            theirOneTimeKey: pub(ids.bobOneTime))
        let first = try alice.encrypt(Data("hi".utf8)).body
        do {
            _ = try OlmSession.createInbound(
                ourIdentity: ids.bob,
                oneTimeKeys: [Curve25519.KeyAgreement.PrivateKey()],
                message: first)
            Issue.record("unknown one-time key should throw")
        } catch let error {
            #expect(error == .unknownOneTimeKey)
        }
    }

    @Test("Pre-key from a third party fails the identity check")
    func identityMismatch() throws {
        var (_, bob, _, bobID) = try handshake()
        // Carol starts her own session with Bob's device.
        let carol = Curve25519.KeyAgreement.PrivateKey()
        let carolOT = Curve25519.KeyAgreement.PrivateKey()
        var carolSession = try OlmSession.createOutbound(
            ourIdentity: carol, theirIdentityKey: pub(bobID),
            theirOneTimeKey: pub(carolOT))
        let carolMsg = try carolSession.encrypt(Data("hi bob".utf8)).body
        // Bob's Alice-session must reject Carol's identity key.
        do {
            _ = try bob.decrypt(carolMsg)
            Issue.record("foreign identity should throw")
        } catch let error {
            #expect(error == .identityMismatch)
        }
    }

    @Test("Excessive gaps are rejected")
    func gapTooLarge() throws {
        let ids = identities()
        var alice = try OlmSession.createOutbound(
            ourIdentity: ids.alice, theirIdentityKey: pub(ids.bob),
            theirOneTimeKey: pub(ids.bobOneTime))
        let first = try alice.encrypt(Data("hello".utf8)).body
        var bob = try OlmSession.createInbound(
            ourIdentity: ids.bob, oneTimeKeys: [ids.bobOneTime],
            message: first)
        _ = try bob.decrypt(first)
        var late = Data()
        for i in 0...1001 {
            late = try alice.encrypt(Data("m\(i)".utf8)).body
        }
        do {
            _ = try bob.decrypt(late)
            Issue.record("gap over bound should throw")
        } catch let error {
            #expect(error == .gapTooLarge)
        }
    }

    @Test("Session ID is the base64 identity public key")
    func sessionID() throws {
        let ids = identities()
        let alice = try OlmSession.createOutbound(
            ourIdentity: ids.alice, theirIdentityKey: pub(ids.bob),
            theirOneTimeKey: pub(ids.bobOneTime))
        #expect(alice.id == Primitives.base64UnpaddedEncode(pub(ids.alice)))
    }

    @Test("Pickle round-trips mid-conversation state")
    func pickleRoundTrip() throws {
        var (alice, bob, _, _) = try handshake()
        // Advance both ratchets so the snapshot covers live chains.
        for i in 0..<3 {
            let a = try alice.encrypt(Data("a\(i)".utf8)).body
            #expect(try bob.decrypt(a) == Data("a\(i)".utf8))
            let b = try bob.encrypt(Data("b\(i)".utf8)).body
            #expect(try alice.decrypt(b) == Data("b\(i)".utf8))
        }
        // Hold one message back so Bob banks a skipped key.
        let held = try alice.encrypt(Data("held".utf8)).body
        let next = try alice.encrypt(Data("next".utf8)).body
        #expect(try bob.decrypt(next) == Data("next".utf8))
        // Snapshot Bob mid-stream; the restored copy picks up exactly.
        var bob2 = try OlmSession.restore(from: try bob.pickle())
        #expect(try bob2.decrypt(held) == Data("held".utf8))
        let after = try alice.encrypt(Data("after".utf8)).body
        #expect(try bob2.decrypt(after) == Data("after".utf8))
        let back = try bob2.encrypt(Data("back".utf8)).body
        #expect(try alice.decrypt(back) == Data("back".utf8))
    }

    @Test("Corrupt pickles are rejected")
    func pickleRejectsGarbage() throws {
        let (_, bob, _, _) = try handshake()
        let good = try bob.pickle()
        #expect(throws: CryptoError.self) {
            try OlmSession.restore(from: Data("not a pickle".utf8))
        }
        var obj = try #require(
            try JSONSerialization.jsonObject(with: good) as? [String: Any])
        obj["v"] = 99
        let badVersion = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: CryptoError.self) {
            try OlmSession.restore(from: badVersion)
        }
        obj["v"] = 1
        obj["rootKey"] = Data([1, 2, 3]).base64EncodedString()
        let shortKey = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: CryptoError.self) {
            try OlmSession.restore(from: shortKey)
        }
    }
}
