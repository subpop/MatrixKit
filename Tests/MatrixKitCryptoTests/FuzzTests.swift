import Crypto
import Foundation
import Testing

@testable import MatrixKitCrypto

/// Mutation fuzz over the decrypt paths: truncated, bit-flipped, and
/// random blobs must always throw `CryptoError` — never trap.
///
/// (A `Data`-slice subscript regression once crashed these paths with
/// SIGTRAP; this suite pins the fix.)
@Suite("Fuzz")
struct FuzzTests {
    /// One RNG stream per test keeps failures reproducible in logs.
    private func mutate(_ input: Data, rng: inout SystemRandomNumberGenerator)
        -> Data
    {
        let roll = Int.random(in: 0..<10, using: &rng)
        switch roll {
        case 0..<6 where !input.isEmpty:
            // Bit-flip 1-3 bytes of the real message.
            var out = input
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let i = Int.random(in: 0..<out.count, using: &rng)
                out[i] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            }
            return out
        case 6..<8:
            // Truncate to any prefix (including empty).
            return input.prefix(Int.random(in: 0...input.count, using: &rng))
        case 8 where !input.isEmpty:
            // Splice: prefix + random tail.
            let cut = Int.random(in: 0...input.count, using: &rng)
            var out = input.prefix(cut)
            out += Data(
                (0..<Int.random(in: 1...64, using: &rng)).map { _ in
                    UInt8.random(in: 0...255, using: &rng)
                })
            return out
        default:
            // Pure random blob.
            return Data(
                (0..<Int.random(in: 0...200, using: &rng)).map { _ in
                    UInt8.random(in: 0...255, using: &rng)
                })
        }
    }

    @Test(
        "Olm decrypt never traps on mutated input",
        .timeLimit(.minutes(2)))
    func olmFuzz() throws {
        let aliceID = Curve25519.KeyAgreement.PrivateKey()
        let bobID = Curve25519.KeyAgreement.PrivateKey()
        let bobOT = Curve25519.KeyAgreement.PrivateKey()
        var alice = try OlmSession.createOutbound(
            ourIdentity: aliceID,
            theirIdentityKey: Data(bobID.publicKey.rawRepresentation),
            theirOneTimeKey: Data(bobOT.publicKey.rawRepresentation))
        let first = try alice.encrypt(Data("hello".utf8)).body
        var bob = try OlmSession.createInbound(
            ourIdentity: bobID, oneTimeKeys: [bobOT], message: first)
        _ = try bob.decrypt(first)
        // A normal message so both wire types are exercised.
        let reply = try bob.encrypt(Data("hi alice".utf8)).body
        _ = try alice.decrypt(reply)
        let normal = try alice.encrypt(Data("again".utf8)).body

        var rng = SystemRandomNumberGenerator()
        for i in 0..<5000 {
            let seed = i % 3 == 0 ? first : (i % 3 == 1 ? reply : normal)
            do {
                _ = try bob.decrypt(mutate(seed, rng: &rng))
            } catch {
                // Any CryptoError is a pass. A trap would abort the run.
            }
        }
    }

    @Test(
        "Megolm decrypt never traps on mutated input",
        .timeLimit(.minutes(2)))
    func megolmFuzz() throws {
        var outbound = MegolmSession.create()
        let shared = try outbound.sessionKey()
        let real = try outbound.encrypt(Data("room message".utf8))
        var inbound = try MegolmSession.importSessionKey(shared)
        _ = try inbound.decrypt(real)

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            do {
                _ = try inbound.decrypt(mutate(real, rng: &rng))
            } catch {
                // Any CryptoError is a pass. A trap would abort the run.
            }
        }
    }
}
