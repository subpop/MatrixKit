import Crypto
import Foundation

/// An Olm Double-Ratchet session: the 1:1 encrypted channel underneath
/// `m.olm.v1.curve25519-aes-sha2`.
///
/// Setup is Triple Diffie-Hellman over the two identity keys and one
/// one-time key:
///
/// ```text
/// S = ECDH(IA, EB) ∥ ECDH(EA, IB) ∥ ECDH(EA, EB)
/// R₀ ∥ C₀,₀ = HKDF(0, S, "OLM_ROOT", 64)
/// ```
///
/// Root advances on every new peer ratchet key
/// (`HKDF(Rᵢ₋₁, ECDH(Tᵢ₋₁, Tᵢ), "OLM_RATCHET", 64)`); chains advance with
/// `HMAC(key, 0x02)` and message keys come from `HMAC(chain, 0x01)`, fed
/// into `HKDF(0, M, "OLM_KEYS", 80)` for AES/HMAC/IV.
///
/// State is in memory only this milestone. `encrypt`/`decrypt` are
/// `mutating`: every message advances the ratchet.
public struct OlmSession: Sendable {
    /// Bound on forward skips when a message arrives ahead of the chain.
    public static let maxGap: UInt64 = 1000
    /// Bound on retained skipped message keys (oldest evicted first).
    public static let maxSkippedKeys = 4096

    private let ourIdentity: Curve25519.KeyAgreement.PrivateKey
    private let theirIdentity: Data

    private var rootKey: Data
    private var ourRatchet: Curve25519.KeyAgreement.PrivateKey
    private var theirRatchet: Data?
    private var sendChainKey: Data
    private var sendIndex: UInt64
    private var recvChainKey: Data
    private var recvIndex: UInt64
    private var previousRecv:
        (ratchet: Data, chainKey: Data, index: UInt64)?
    /// Our sender chain is stale once the peer ratchets: the next
    /// `encrypt` generates a fresh ratchet key and DH-advances first.
    private var senderStale: Bool
    /// False until a message is received: outbound sessions emit
    /// pre-key messages until the peer answers with a normal one.
    private var receivedAny: Bool
    /// Pre-key envelope material (outbound only): their one-time key EB
    /// and our ephemeral EA.
    private let oneTimeKey: Data?
    private let baseKey: Data?

    private var skipped: [SkippedID: Data] = [:]
    private var skippedOrder: [SkippedID] = []

    private struct SkippedID: Hashable {
        let ratchet: Data
        let index: UInt64
    }

    // MARK: - Setup

    /// Alice side: start a session from the peer's identity key and a
    /// claimed one-time key. The first `encrypt` emits a pre-key message.
    public static func createOutbound(
        ourIdentity: Curve25519.KeyAgreement.PrivateKey,
        theirIdentityKey: Data,
        theirOneTimeKey: Data
    ) throws(CryptoError) -> OlmSession {
        try createOutbound(
            ourIdentity: ourIdentity, theirIdentityKey: theirIdentityKey,
            theirOneTimeKey: theirOneTimeKey,
            ephemeral: Curve25519.KeyAgreement.PrivateKey(),
            firstRatchet: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Deterministic seam for interop fixtures: same as `createOutbound`
    /// but with caller-supplied ephemeral + first ratchet keys.
    /// Internal — tests only, never for production sessions.
    internal static func createOutbound(
        ourIdentity: Curve25519.KeyAgreement.PrivateKey,
        theirIdentityKey: Data,
        theirOneTimeKey: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        firstRatchet: Curve25519.KeyAgreement.PrivateKey
    ) throws(CryptoError) -> OlmSession {
        guard
            theirIdentityKey.count == 32, theirOneTimeKey.count == 32
        else {
            throw .invalidKey("Olm peer keys must be 32 bytes")
        }
        let shared =
            try ecdh(ourIdentity, theirOneTimeKey)
            + ecdh(ephemeral, theirIdentityKey)
            + ecdh(ephemeral, theirOneTimeKey)
        let (root, chain) = setupKDF(dh: shared)
        return OlmSession(
            ourIdentity: ourIdentity,
            theirIdentity: theirIdentityKey,
            rootKey: root,
            ourRatchet: firstRatchet,
            theirRatchet: nil,
            sendChainKey: chain,
            sendIndex: 0,
            recvChainKey: chain,
            recvIndex: 0,
            previousRecv: nil,
            senderStale: false,
            receivedAny: false,
            oneTimeKey: theirOneTimeKey,
            baseKey: Data(ephemeral.publicKey.rawRepresentation))
    }

    /// Bob side: start a session from an incoming pre-key message,
    /// selecting the named one-time private key. Does not decrypt —
    /// call `decrypt` with the same message afterwards.
    public static func createInbound(
        ourIdentity: Curve25519.KeyAgreement.PrivateKey,
        oneTimeKeys: [Curve25519.KeyAgreement.PrivateKey],
        message: Data
    ) throws(CryptoError) -> OlmSession {
        // Full wire parse, no MAC strip: pre-key messages carry none.
        let preKey = try OlmMessageCoder.decodePreKeyBody(message: message)
        guard
            let oneTime = oneTimeKeys.first(where: {
                Data($0.publicKey.rawRepresentation) == preKey.oneTimeKey
            })
        else {
            throw .unknownOneTimeKey
        }
        let baseKey = try publicKey(preKey.baseKey, what: "base key")
        let shared =
            try ecdh(oneTime, preKey.identityKey)
            + ecdh(ourIdentity, Data(baseKey.rawRepresentation))
            + ecdh(oneTime, Data(baseKey.rawRepresentation))
        let (root, chain) = setupKDF(dh: shared)
        return OlmSession(
            ourIdentity: ourIdentity,
            theirIdentity: preKey.identityKey,
            rootKey: root,
            ourRatchet: Curve25519.KeyAgreement.PrivateKey(),
            theirRatchet: nil,
            sendChainKey: chain,
            sendIndex: 0,
            recvChainKey: chain,
            recvIndex: 0,
            previousRecv: nil,
            // Bob must ratchet before his first send: C₀,₀ already
            // belongs to Alice's sending chain.
            senderStale: true,
            receivedAny: true,
            oneTimeKey: nil,
            baseKey: nil)
    }

    // MARK: - Encrypt / decrypt

    /// Encrypt. Returns the wire type (`0` pre-key until a message has
    /// been received, `1` after) and the full wire bytes (normal:
    /// payload + MAC; pre-key: version + fields, no outer MAC).
    public mutating func encrypt(
        _ plaintext: Data
    ) throws(CryptoError) -> (type: OlmWireType, body: Data) {
        if senderStale {
            guard let their = theirRatchet else {
                throw .malformedMessage(
                    "Sender ratchet stale with no peer ratchet key")
            }
            ourRatchet = Curve25519.KeyAgreement.PrivateKey()
            let (root, chain) = try Self.rootKDF(
                root: rootKey, dh: Self.ecdh(ourRatchet, their))
            rootKey = root
            sendChainKey = chain
            sendIndex = 0
            senderStale = false
        }
        // Message keys come from the CURRENT chain key
        // (Mᵢ = HMAC(Cᵢ, 0x01)); the chain steps after.
        let messageKey = Self.messageKey(sendChainKey)
        sendChainKey = Self.stepChain(sendChainKey)
        let messageIndex = sendIndex
        sendIndex += 1
        let keys = Self.messageKeys(messageKey)
        let ciphertext = try AESCBC.encrypt(
            key: keys.aes, iv: keys.iv, plaintext: plaintext)
        let ratchetPub = Data(ourRatchet.publicKey.rawRepresentation)
        let inner = OlmMessageCoder.encodeNormal(
            OlmNormalMessage(
                ratchetKey: ratchetPub, chainIndex: messageIndex,
                ciphertext: ciphertext))
        if !receivedAny {
            guard let eb = oneTimeKey, let ea = baseKey else {
                throw .malformedMessage(
                    "Pre-key send without one-time/ephemeral keys")
            }
            // The inner message is the full normal wire (payload + its
            // MAC); the outer pre-key message carries no MAC of its own.
            let innerMAC = Self.messageMAC(keys.hmac, payload: inner)
            let outer = OlmMessageCoder.encodePreKey(
                oneTimeKey: eb, baseKey: ea,
                identityKey: Data(
                    ourIdentity.publicKey.rawRepresentation),
                innerWire: inner + innerMAC)
            return (.preKey, outer)
        }
        let mac = Self.messageMAC(keys.hmac, payload: inner)
        return (.normal, inner + mac)
    }

    /// Decrypt one wire message. Accepts pre-key messages (version +
    /// fields, no outer MAC — the embedded inner carries its own) and
    /// normal messages (payload + MAC); out-of-order messages bank
    /// skipped keys.
    public mutating func decrypt(
        _ message: Data
    ) throws(CryptoError) -> Data {
        let payload: Data
        let mac: Data
        let inner: OlmNormalMessage
        if let preKey = try? OlmMessageCoder.decodePreKeyBody(
            message: message)
        {
            guard preKey.identityKey == theirIdentity else {
                throw .identityMismatch
            }
            (payload, mac) = try OlmMessageCoder.split(
                message: preKey.inner)
            guard
                case .normal(let normal) = try OlmMessageCoder.decode(
                    payload: payload)
            else {
                throw .malformedMessage("Pre-key inner is not normal")
            }
            inner = normal
        } else {
            (payload, mac) = try OlmMessageCoder.split(message: message)
            guard
                case .normal(let normal) = try OlmMessageCoder.decode(
                    payload: payload)
            else {
                throw .malformedMessage("Normal message expected")
            }
            inner = normal
        }
        let messageKey = try receiveKey(
            ratchet: inner.ratchetKey, index: inner.chainIndex)
        let keys = Self.messageKeys(messageKey)
        guard Primitives.constantTimeEqual(
            Self.messageMAC(keys.hmac, payload: payload), mac)
        else {
            throw .macMismatch
        }
        receivedAny = true
        return try AESCBC.decrypt(
            key: keys.aes, iv: keys.iv, ciphertext: inner.ciphertext)
    }

    /// Session ID: base64 of our Curve25519 identity public key.
    public var id: String {
        Primitives.base64UnpaddedEncode(
            Data(ourIdentity.publicKey.rawRepresentation))
    }

    // MARK: - Ratchet internals

    /// Resolve (or derive and bank) the message key for an inbound
    /// `(ratchet, index)`, advancing chains as needed.
    private mutating func receiveKey(
        ratchet: Data, index: UInt64
    ) throws(CryptoError) -> Data {
        if ratchet != theirRatchet {
            if theirRatchet == nil && receivedAny {
                // Inbound first message: sent on the peer's setup
                // ratchet, so the receiving chain is still C₀,₀ from
                // the triple-DH. (An outbound session's first message
                // always needs the DH step below: the peer must have
                // generated a fresh ratchet to reply.)
                theirRatchet = ratchet
                senderStale = true
            } else {
                if let prev = previousRecv, ratchet == prev.ratchet {
                    let advanced = try advanceTo(
                        chainKey: prev.chainKey, index: prev.index,
                        target: index, ratchet: ratchet)
                    previousRecv?.chainKey = advanced.chainKey
                    previousRecv?.index = advanced.index
                    return advanced.messageKey
                }
                if recvIndex > 0 || previousRecv != nil {
                    previousRecv = (
                        ratchet: theirRatchet ?? Data(),
                        chainKey: recvChainKey, index: recvIndex)
                }
                let (root, chain) = try Self.rootKDF(
                    root: rootKey, dh: Self.ecdh(ourRatchet, ratchet))
                rootKey = root
                theirRatchet = ratchet
                recvChainKey = chain
                recvIndex = 0
                senderStale = true
            }
        }
        if index < recvIndex {
            guard
                let skipped = skipped.removeValue(
                    forKey: SkippedID(ratchet: ratchet, index: index))
            else {
                throw .replayDetected
            }
            return skipped
        }
        let advanced = try advanceTo(
            chainKey: recvChainKey, index: recvIndex, target: index,
            ratchet: ratchet)
        recvChainKey = advanced.chainKey
        recvIndex = advanced.index
        return advanced.messageKey
    }

    /// Step a chain forward to `target`, banking skipped message keys.
    /// Returns the post-target chain state plus the target message key.
    private mutating func advanceTo(
        chainKey: Data, index: UInt64, target: UInt64, ratchet: Data
    ) throws(CryptoError) -> (
        chainKey: Data, index: UInt64, messageKey: Data
    ) {
        guard target >= index else {
            throw .malformedMessage("Ratchet went backwards")
        }
        guard target - index <= Self.maxGap else {
            throw .gapTooLarge
        }
        var key = chainKey
        var i = index
        while i < target {
            bankSkipped(
                ratchet: ratchet, index: i, key: Self.messageKey(key))
            key = Self.stepChain(key)
            i += 1
        }
        let messageKey = Self.messageKey(key)
        return (Self.stepChain(key), i + 1, messageKey)
    }

    private mutating func bankSkipped(
        ratchet: Data, index: UInt64, key: Data
    ) {
        let id = SkippedID(ratchet: ratchet, index: index)
        skipped[id] = key
        skippedOrder.append(id)
        while skipped.count > Self.maxSkippedKeys {
            if let oldest = skippedOrder.first {
                skipped.removeValue(forKey: oldest)
                skippedOrder.removeFirst()
            } else {
                break
            }
        }
    }

    // MARK: - KDF helpers

    /// Message key for the current chain position: `M = HMAC(C, 0x01)`.
    private static func messageKey(_ chainKey: Data) -> Data {
        Primitives.hmacSHA256(key: chainKey, message: Data([0x01]))
    }

    /// Step the chain forward: `C' = HMAC(C, 0x02)`.
    private static func stepChain(_ chainKey: Data) -> Data {
        Primitives.hmacSHA256(key: chainKey, message: Data([0x02]))
    }

    /// `R₀ ∥ C₀,₀ = HKDF(0, S, "OLM_ROOT", 64)` — TripleDH setup only.
    /// ("OLM_RATCHET" is for subsequent DH ratchet steps; using it here
    /// produced sessions that round-tripped with themselves but failed
    /// against spec implementations — caught by vodozemac interop.)
    private static func setupKDF(dh: Data) -> (root: Data, chain: Data) {
        let out = Primitives.hkdfSHA256(
            inputKeyMaterial: dh, salt: Data(),
            info: Data("OLM_ROOT".utf8), outputByteCount: 64)
        return (out.prefix(32), out.suffix(32))
    }

    /// `Rᵢ ∥ Cᵢ,₀ = HKDF(Rᵢ₋₁, ECDH(ours, theirs), "OLM_RATCHET", 64)`.
    /// The previous root key chains in as the HKDF salt (only the
    /// TripleDH setup uses the zero salt). Ignoring it here produced
    /// sessions that round-tripped with themselves but failed against
    /// spec implementations — caught by vodozemac interop.
    private static func rootKDF(root: Data, dh: Data) -> (
        root: Data, chain: Data
    ) {
        let out = Primitives.hkdfSHA256(
            inputKeyMaterial: dh, salt: root,
            info: Data("OLM_RATCHET".utf8), outputByteCount: 64)
        return (out.prefix(32), out.suffix(32))
    }

    /// `AES ∥ HMAC ∥ IV = HKDF(0, M, "OLM_KEYS", 80)` (32 + 32 + 16).
    private static func messageKeys(_ messageKey: Data) -> (
        aes: Data, hmac: Data, iv: Data
    ) {
        let out = Primitives.hkdfSHA256(
            inputKeyMaterial: messageKey, salt: Data(),
            info: Data("OLM_KEYS".utf8), outputByteCount: 80)
        return (out.prefix(32), out[32..<64], out.suffix(16))
    }

    /// MAC over the full payload (version byte + fields); first 8 bytes.
    private static func messageMAC(_ hmacKey: Data, payload: Data) -> Data {
        Primitives.hmacSHA256(key: hmacKey, message: payload).prefix(8)
    }

    private static func ecdh(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey, _ peer: Data
    ) throws(CryptoError) -> Data {
        let peerKey = try publicKey(peer, what: "peer key")
        do {
            let secret = try privateKey.sharedSecretFromKeyAgreement(
                with: peerKey)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            throw CryptoError.invalidKey("ECDH failed: \(error)")
        }
    }

    private static func publicKey(
        _ bytes: Data, what: String
    ) throws(CryptoError) -> Curve25519.KeyAgreement.PublicKey {
        guard bytes.count == 32 else {
            throw .invalidKey("Olm \(what) must be 32 bytes")
        }
        do {
            return try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: bytes)
        } catch {
            throw CryptoError.invalidKey("Bad Olm \(what): \(error)")
        }
    }
}

// MARK: - Pickle (persistence)

extension OlmSession {
    private struct PickledSkipped: Codable {
        var ratchet: Data
        var index: UInt64
        var key: Data
    }

    /// Versioned, JSON-encoded snapshot of the full ratchet state.
    /// Opaque to callers — persist the bytes (e.g. via a `KeyStore`)
    /// and hand them back to `restore(from:)`. Same file: uses the
    /// private `SkippedID` type.
    private struct Pickle: Codable {
        struct Ref: Codable {
            var ratchet: Data
            var index: UInt64
        }
        var v: Int
        var ourIdentity: Data
        var theirIdentity: Data
        var rootKey: Data
        var ourRatchet: Data
        var theirRatchet: Data?
        var sendChainKey: Data
        var sendIndex: UInt64
        var recvChainKey: Data
        var recvIndex: UInt64
        var prevRatchet: Data?
        var prevChainKey: Data?
        var prevIndex: UInt64?
        var senderStale: Bool
        var receivedAny: Bool
        var oneTimeKey: Data?
        var baseKey: Data?
        var skipped: [PickledSkipped]
        var skippedOrder: [Ref]
    }
}

extension OlmSession {
    /// Snapshot the full ratchet state (chains, ratchets, skipped keys,
    /// pre-key material) for persistence across restarts. The bytes hold
    /// key material — store them as a secret.
    public func pickle() throws(CryptoError) -> Data {
        let prev = previousRecv
        let pickle = Pickle(
            v: 1,
            ourIdentity: Data(ourIdentity.rawRepresentation),
            theirIdentity: theirIdentity,
            rootKey: rootKey,
            ourRatchet: Data(ourRatchet.rawRepresentation),
            theirRatchet: theirRatchet,
            sendChainKey: sendChainKey,
            sendIndex: sendIndex,
            recvChainKey: recvChainKey,
            recvIndex: recvIndex,
            prevRatchet: prev?.ratchet,
            prevChainKey: prev?.chainKey,
            prevIndex: prev?.index,
            senderStale: senderStale,
            receivedAny: receivedAny,
            oneTimeKey: oneTimeKey,
            baseKey: baseKey,
            skipped: skipped.map { (id, key) in
                PickledSkipped(
                    ratchet: id.ratchet, index: id.index, key: key)
            },
            skippedOrder: skippedOrder.map {
                Pickle.Ref(ratchet: $0.ratchet, index: $0.index)
            })
        do {
            return try JSONEncoder().encode(pickle)
        } catch {
            throw .malformedMessage("Olm pickle encoding failed: \(error)")
        }
    }

    /// Rebuild a session from `pickle()` bytes. Throws
    /// `.malformedMessage` on corrupt input (including unknown versions
    /// and wrong-length keys).
    public static func restore(from data: Data) throws(CryptoError) -> OlmSession {
        let pickle: Pickle
        do {
            pickle = try JSONDecoder().decode(Pickle.self, from: data)
        } catch {
            throw .malformedMessage("Olm pickle undecodable: \(error)")
        }
        guard pickle.v == 1 else {
            throw .malformedMessage(
                "Unsupported Olm pickle version \(pickle.v)")
        }
        let ourIdentity: Curve25519.KeyAgreement.PrivateKey
        let ourRatchet: Curve25519.KeyAgreement.PrivateKey
        do {
            ourIdentity = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: pickle.ourIdentity)
            ourRatchet = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: pickle.ourRatchet)
        } catch {
            throw .invalidKey("Olm pickle has invalid private key: \(error)")
        }
        for (label, bytes) in [
            ("their identity", pickle.theirIdentity),
            ("root key", pickle.rootKey),
            ("send chain", pickle.sendChainKey),
            ("receive chain", pickle.recvChainKey),
        ] as [(String, Data)] {
            guard bytes.count == 32 else {
                throw .malformedMessage("Olm pickle has short \(label)")
            }
        }
        var previousRecv: (ratchet: Data, chainKey: Data, index: UInt64)?
        if let ratchet = pickle.prevRatchet,
            let chainKey = pickle.prevChainKey,
            let index = pickle.prevIndex
        {
            previousRecv = (ratchet, chainKey, index)
        }
        var skipped: [SkippedID: Data] = [:]
        for entry in pickle.skipped {
            skipped[SkippedID(ratchet: entry.ratchet, index: entry.index)] =
                entry.key
        }
        return OlmSession(
            ourIdentity: ourIdentity,
            theirIdentity: pickle.theirIdentity,
            rootKey: pickle.rootKey,
            ourRatchet: ourRatchet,
            theirRatchet: pickle.theirRatchet,
            sendChainKey: pickle.sendChainKey,
            sendIndex: pickle.sendIndex,
            recvChainKey: pickle.recvChainKey,
            recvIndex: pickle.recvIndex,
            previousRecv: previousRecv,
            senderStale: pickle.senderStale,
            receivedAny: pickle.receivedAny,
            oneTimeKey: pickle.oneTimeKey,
            baseKey: pickle.baseKey,
            skipped: skipped,
            skippedOrder: pickle.skippedOrder.map {
                SkippedID(ratchet: $0.ratchet, index: $0.index)
            })
    }
}
