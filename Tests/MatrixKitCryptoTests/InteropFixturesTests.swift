import Crypto
import Foundation
import Testing

@testable import MatrixKitCrypto

/// Hermetic vodozemac cross-checks: committed fixtures produced with
/// fixed keys, verified against vodozemac 0.10 at harvest time. No
/// harness binary needed — `swift test` stays hermetic. See
/// `Tools/OlmInteropHarness` for the live counterparts.
@Suite("InteropFixtures")
struct InteropFixturesTests {
    private func fixture(_ name: String) throws -> [String: Any] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("InteropFixtures")
        let data = try Data(
            contentsOf: dir.appendingPathComponent(name))
        guard
            let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw HarnessError(message: "fixture \(name) is not an object")
        }
        return json
    }

    struct HarnessError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func hex(_ string: String) -> Data {
        var data = Data()
        var i = string.startIndex
        while i < string.endIndex {
            let j = string.index(i, offsetBy: 2)
            data.append(UInt8(string[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    private func curvePrivate(_ f: [String: Any], _ key: String) throws
        -> Curve25519.KeyAgreement.PrivateKey
    {
        try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hex(f[key] as! String))
    }

    private func curvePublic(
        _ key: Curve25519.KeyAgreement.PrivateKey
    ) -> Data {
        Data(key.publicKey.rawRepresentation)
    }

    @Test("Olm pre-key reproduces vodozemac-verified bytes exactly")
    func olmPrekey() throws {
        let f = try fixture("olm-prekey.json")
        let aliceID = try curvePrivate(f, "alice_id_priv")
        let bobID = try curvePrivate(f, "bob_id_priv")
        let bobOTK = try curvePrivate(f, "bob_otk_priv")
        let eph = try curvePrivate(f, "alice_eph_priv")
        let t0 = try curvePrivate(f, "first_ratchet_priv")
        var alice = try OlmSession.createOutbound(
            ourIdentity: aliceID,
            theirIdentityKey: curvePublic(bobID),
            theirOneTimeKey: curvePublic(bobOTK),
            ephemeral: eph, firstRatchet: t0)
        let plaintext = Data((f["plaintext"] as! String).utf8)
        let (type, body) = try alice.encrypt(plaintext)
        #expect(type == .preKey)
        // Byte-identical: deterministic IV (HKDF) + fixed keys.
        #expect(
            body.base64EncodedString() == (f["prekey_b64"] as! String))
        // And the message round-trips through our own inbound path.
        var bob = try OlmSession.createInbound(
            ourIdentity: bobID, oneTimeKeys: [bobOTK], message: body)
        #expect(try bob.decrypt(body) == plaintext)
    }

    @Test("Megolm decrypts vodozemac message, reproduces payload+MAC")
    func megolmFixed() throws {
        let f = try fixture("megolm-fixed.json")
        let parts = (f["parts"] as! [String]).map { hex($0) }
        var outbound = try MegolmSession.createDeterministic(
            counter: 0, parts: parts,
            ed25519PrivateKey: hex(f["ed25519_seed"] as! String))
        let plaintext = Data((f["plaintext"] as! String).utf8)
        // Our session key imports (signature verifies); ID matches.
        var inbound = try MegolmSession.importSessionKey(
            Data(base64Encoded: f["session_key_b64"] as! String)!)
        #expect(inbound.id == (f["session_id"] as! String))
        // vodozemac's message decrypts to the plaintext.
        let mereka = Data(
            base64Encoded: f["vodozemac_message_b64"] as! String)!
        #expect(try inbound.decrypt(mereka) == plaintext)
        // Our encryption reproduces payload+MAC byte-identically
        // (trailing 64-byte Ed25519 signature excluded: randomized).
        let ours = try outbound.encrypt(plaintext)
        #expect(ours.dropLast(64) == mereka.dropLast(64))
    }
}
