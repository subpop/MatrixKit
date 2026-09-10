import Crypto
import Foundation
import MatrixKitCrypto

/// Our role in a verification flow.
public enum VerificationRole: String, Sendable {
    /// We sent `m.key.verification.request`.
    case requester
    /// We received the request and answered with `ready`.
    case responder
}

/// SAS verification flow state (`m.sas.v1`, `curve25519-hkdf-sha256`).
public enum VerificationState: String, Sendable {
    case requested
    case ready
    case started
    case accepted
    case keysExchanged
    case macSent
    case macReceived
    case done
    case cancelled
}

/// One side of an SAS verification (`m.sas.v1`).
///
/// Follows the to-device handshake: after `ready`, the *requester* (the side
/// that sent the request) sends `start` and the responder answers with
/// `accept`. Either side *may* send `start` per spec — when both do, the
/// start from the lexicographically smaller (user ID, device ID) wins and
/// the other side adopts it — so `receiveStart` implements that tie-break
/// instead of cancelling. Key exchange, SAS derivation, and MAC logic follow
/// the spec sections verified against v1.19 (`SAS HKDF calculation`, `MAC
/// calculation`): empty HKDF salt, `MATRIX_KEY_VERIFICATION_SAS|` info with
/// `|` separators, `hkdf-hmac-sha256.v2` MACs.
public actor VerificationSession {
    public let transactionId: String
    public let role: VerificationRole
    public let peerUserId: UserId

    private(set) public var state: VerificationState = .requested
    private(set) public var peerDeviceId: String?
    /// Whether we sent `start` (vs received it). The SAS HKDF binds the
    /// starter/accepter identities, so derivation follows this flag — not
    /// the role, since either side may start per spec.
    private(set) public var weSentStart = false

    private let toDevice: any ToDeviceSender
    private let ourUserId: UserId
    private let ourDeviceId: String
    private var peerDevices: [String]

    private var ephemeralPrivate: Data?
    private var ephemeralPublicB64: String?
    private var peerEphemeralB64: String?
    private(set) var ourKeySent = false
    /// Whether we sent our `mac` (i.e. the local user approved the SAS).
    /// Gating `done` on this — not just on verifying the peer's MAC —
    /// keeps a peer that approves first from completing our side for us.
    private(set) public var ourMacSent = false
    private var startContent: VerificationStart?
    private var sharedSecret: Data?
    private var sasBytes: Data?

    /// Recipient devices for outbound to-device messages. When verifying
    /// ourselves our own device is excluded — otherwise the server echoes
    /// our messages back to us and the echoes poison the handshake (our own
    /// `key` fails the accept-commitment check, our own `mac` fails MAC
    /// verification). Self-verify broadcasts resolve `"*"` to an explicit
    /// list (minus us) at request time; when that falls back to `"*"` the
    /// monitor's ingress self-check drops the echo, and the `receiveKey`
    /// echo-skip below covers that path.
    private var targetDevices: [String] {
        guard peerUserId == ourUserId else { return peerDevices }
        let filtered = peerDevices.filter { $0 != ourDeviceId }
        return filtered.isEmpty ? peerDevices : filtered
    }

    public init(
        toDevice: any ToDeviceSender,
        role: VerificationRole,
        ourUserId: UserId,
        ourDeviceId: String,
        peerUserId: UserId,
        peerDeviceId: String? = nil,
        peerDevices: [String] = ["*"],
        transactionId: String = UUID().uuidString
    ) {
        self.toDevice = toDevice
        self.role = role
        self.ourUserId = ourUserId
        self.ourDeviceId = ourDeviceId
        self.peerUserId = peerUserId
        self.peerDeviceId = peerDeviceId
        self.peerDevices = peerDevices
        self.transactionId = transactionId
    }

    // MARK: - Request / ready

    /// Send `m.key.verification.request` (requester, initial state).
    public func sendRequest() async throws(MatrixError) {
        try await toDevice.send(
            eventType: "m.key.verification.request",
            content: VerificationRequest(
                fromDevice: ourDeviceId, methods: ["m.sas.v1"],
                timestamp: Int(Date().timeIntervalSince1970 * 1000),
                transactionId: transactionId),
            to: peerUserId, devices: targetDevices
        )
    }

    /// Send `m.key.verification.ready` (responder, on incoming request).
    public func sendReady() async throws(MatrixError) {
        try await toDevice.send(
            eventType: "m.key.verification.ready",
            content: VerificationReady(fromDevice: ourDeviceId, methods: ["m.sas.v1"]),
            to: peerUserId, devices: targetDevices
        )
        state = .ready
    }

    /// Handle an incoming `ready` (requester). Records the peer device.
    /// Late duplicates (after we already started) are ignored so out-of-order
    /// batches never cancel a live handshake.
    public func receiveReady(_ ready: VerificationReady) throws(MatrixError) {
        if state == .ready {
            return
        }
        if state == .started {
            return
        }
        try requireState(.requested, "ready")
        guard ready.methods.contains("m.sas.v1") else {
            throw .verificationFailed("Peer does not support m.sas.v1")
        }
        peerDeviceId = ready.fromDevice
        // Narrow all further traffic (start/key/mac/done) to the engaged
        // device. Fanning out post-ready messages confused peers (each
        // unengaged device sees a start for a flow it never joined).
        peerDevices = [ready.fromDevice]
        state = .ready
    }

    // MARK: - Start / accept

    /// Send `m.key.verification.start` with a fresh ephemeral key. The
    /// requester auto-sends after `ready`; the responder waits for the
    /// peer's start (it only sends one as a fallback when driving a flow
    /// manually, e.g. the mx REPL).
    public func sendStart(
        sasMethods: [String] = ["emoji", "decimal"]
    ) async throws(MatrixError) {
        try requireState(.ready, "start")
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        ephemeralPrivate = Data(ephemeral.rawRepresentation)
        ephemeralPublicB64 = Primitives.base64UnpaddedEncode(
            Data(ephemeral.publicKey.rawRepresentation))
        let start = VerificationStart(
            fromDevice: ourDeviceId, shortAuthenticationString: sasMethods,
            transactionId: transactionId)
        startContent = start
        try await toDevice.send(
            eventType: "m.key.verification.start", content: start,
            to: peerUserId, devices: targetDevices
        )
        weSentStart = true
        state = .started
    }

    /// Handle an incoming `start`. The requester normally receives it (the
    /// responder started), and it is also accepted before `ready` since the
    /// two messages can arrive out of order. When both sides sent `start`,
    /// the lexicographically smaller (user ID, device ID) wins per spec:
    /// the loser adopts the peer's start, the winner ignores it. Records
    /// peer device + content.
    public func receiveStart(_ start: VerificationStart) throws(MatrixError) {
        if state == .started {
            if !weSentStart {
                return
            }
            if peerStartWins(start) {
                peerDeviceId = start.fromDevice
                peerDevices = [start.fromDevice]
                startContent = start
                weSentStart = false
            }
            return
        }
        guard state == .requested || state == .ready else {
            throw .verificationFailed(
                "Cannot start in state \(state) (expected requested or ready)")
        }
        peerDeviceId = start.fromDevice
        // Same narrowing as `receiveReady`: accept/key/mac/done go to the
        // engaged device only.
        peerDevices = [start.fromDevice]
        startContent = start
        state = .started
    }

    /// Send `m.key.verification.accept` with our commitment. Normally the
    /// responder accepts the requester's start; either role may accept when
    /// the peer started (interop fallback).
    public func sendAccept() async throws(MatrixError) {
        try requireState(.started, "accept")
        guard let start = startContent else {
            throw .verificationFailed("No start content to accept")
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        ephemeralPrivate = Data(ephemeral.rawRepresentation)
        let publicB64 = Primitives.base64UnpaddedEncode(
            Data(ephemeral.publicKey.rawRepresentation))
        ephemeralPublicB64 = publicB64
        let commitment = try Self.commitment(
            ephemeralPublicB64: publicB64, startContent: start)
        try await toDevice.send(
            eventType: "m.key.verification.accept",
            content: VerificationAccept(
                shortAuthenticationString: start.shortAuthenticationString,
                commitment: commitment),
            to: peerUserId, devices: targetDevices
        )
        state = .accepted
    }

    /// Handle an incoming `accept`. Normally the requester receives it (it
    /// started); either role may receive it when the peer started instead.
    /// The commitment binds the accepter's ephemeral key, which only arrives
    /// in their later `m.key.verification.key` — it is stored and checked in
    /// `receiveKey`. There is no commitment to check when we accepted without
    /// a prior accept, so that check is skipped when no accept was received.
    public func receiveAccept(_ accept: VerificationAccept) throws(MatrixError) {
        try requireState(.started, "accept")
        guard
            accept.keyAgreementProtocol == "curve25519-hkdf-sha256",
            accept.hash == "sha256",
            accept.messageAuthenticationCode == "hkdf-hmac-sha256.v2"
        else {
            throw .verificationFailed(
                "Unsupported agreement: \(accept.keyAgreementProtocol)/\(accept.hash)/\(accept.messageAuthenticationCode)")
        }
        pendingCommitment = accept.commitment
        state = .accepted
    }

    // MARK: - Key exchange

    /// Send our ephemeral public key (`m.key.verification.key`).
    public func sendKey() async throws(MatrixError) {
        try requireState(.accepted, "key")
        guard let key = ephemeralPublicB64 else {
            throw .verificationFailed("No ephemeral key (send start/accept first)")
        }
        try await toDevice.send(
            eventType: "m.key.verification.key",
            content: VerificationKey(key: key, transactionId: transactionId),
            to: peerUserId, devices: targetDevices
        )
        ourKeySent = true
        try maybeDeriveSAS()
    }

    /// Handle the peer's ephemeral key. Returns emoji + decimals once both
    /// keys are known (also verifies the accept commitment as requester).
    /// An exact duplicate after the exchange completed is ignored (not an
    /// error) so redeliveries never cancel a live handshake.
    @discardableResult
    public func receiveKey(_ key: VerificationKey) throws(MatrixError) -> ([SASEmoji], [Int])? {
        if state == .keysExchanged, key.key == peerEphemeralB64 {
            return (sasEmoji(), sasDecimals())
        }
        try requireState(.accepted, "key")
        if key.key == ephemeralPublicB64 {
            // Our own `key` echoed back (broadcast `"*"` send or a server
            // that reflects to the sender): it is not the peer's key and
            // would fail the commitment check. Ignore it.
            return nil
        }
        peerEphemeralB64 = key.key
        if pendingCommitment != nil {
            // We received an accept before this key: verify the accepter's
            // commitment. Absent when we accepted the peer's start ourselves
            // (nothing committed to us), in which case there is nothing to
            // check.
            try verifyAcceptCommitment(peerKeyB64: key.key)
        }
        try maybeDeriveSAS()
        guard state == .keysExchanged else { return nil }
        return (sasEmoji(), sasDecimals())
    }

    /// Verify the accepter's commitment (requester, once peer key arrives).
    /// Recomputes via `commitment()` (key as base64 text per spec) and
    /// compares against the stored accept — single construction site.
    private func verifyAcceptCommitment(peerKeyB64: String) throws(MatrixError) {
        guard let commitment = pendingCommitment, let start = startContent else {
            throw .verificationFailed("No pending commitment to verify")
        }
        let computed = try Self.commitment(
            ephemeralPublicB64: peerKeyB64, startContent: start)
        guard computed == commitment else {
            throw .verificationFailed("Commitment mismatch — possible MITM")
        }
    }

    private var pendingCommitment: String?

    private func maybeDeriveSAS() throws(MatrixError) {
        guard ourKeySent, let peerKeyB64 = peerEphemeralB64 else { return }
        try requireState(.accepted, "SAS derivation")
        guard
            let privateBytes = ephemeralPrivate,
            let privateKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateBytes),
            let peerKeyBytes = Primitives.base64UnpaddedDecode(peerKeyB64),
            let peerKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerKeyBytes)
        else {
            throw .verificationFailed("Malformed key agreement inputs")
        }
        let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        guard let secret else {
            throw .verificationFailed("Key agreement failed")
        }
        sharedSecret = secret.withUnsafeBytes { Data($0) }
        sasBytes = try Self.deriveSASBytes(
            sharedSecret: sharedSecret!,
            startSender: starterParty(),
            acceptSender: accepterParty(),
            transactionId: transactionId
        )
        state = .keysExchanged
    }

    /// Spec start tie-break: the smaller (user ID, device ID) wins. Either
    /// side may send `start`; when both do, the winner's start defines the
    /// starter/accepter identities for SAS derivation.
    private func peerStartWins(_ start: VerificationStart) -> Bool {
        if peerUserId.value != ourUserId.value {
            return peerUserId.value < ourUserId.value
        }
        return start.fromDevice < ourDeviceId
    }

    /// (user, device, key) of the side that sent `start`. Either role may
    /// start per spec, so this follows `weSentStart`, not the role.
    private func starterParty() -> (user: String, device: String, key: String) {
        if weSentStart {
            return (ourUserId.value, ourDeviceId, ephemeralPublicB64 ?? "")
        } else {
            return (peerUserId.value, peerDeviceId ?? "", peerEphemeralB64 ?? "")
        }
    }

    /// (user, device, key) of the side that sent `accept` — the other side.
    private func accepterParty() -> (user: String, device: String, key: String) {
        if weSentStart {
            return (peerUserId.value, peerDeviceId ?? "", peerEphemeralB64 ?? "")
        } else {
            return (ourUserId.value, ourDeviceId, ephemeralPublicB64 ?? "")
        }
    }

    // MARK: - SAS display

    /// 7 emoji for the user to compare out-of-band.
    public func sasEmoji() -> [SASEmoji] {
        guard let sasBytes else { return [] }
        return CryptoPrimitives.sasEmoji(
            indices: CryptoPrimitives.sasIndices(bytes: sasBytes))
    }

    /// 3 decimal numbers (already +1000 per spec) for comparison.
    public func sasDecimals() -> [Int] {
        guard let sasBytes else { return [] }
        return CryptoPrimitives.sasDecimals(bytes: sasBytes)
    }

    // MARK: - MAC + done

    /// A key to MAC: key ID (`"ed25519:<b64>"`) plus the key itself (b64).
    public struct KeyToMAC: Hashable, Sendable {
        public let id: String
        public let key: String

        public init(id: String, key: String) {
            self.id = id
            self.key = key
        }
    }

    /// Send `m.key.verification.mac` over our keys after the user confirms
    /// the SAS matches. Also valid after the peer's MAC arrived first
    /// (state `.macReceived`) — the state is kept so `done` follows.
    /// Transient send failures are retried (see `sendWithTransientRetry`).
    public func confirm(keysToMac: [KeyToMAC]) async throws(MatrixError) {
        guard state == .keysExchanged || state == .macReceived else {
            throw .verificationFailed("Unexpected confirm in state \(state)")
        }
        guard !keysToMac.isEmpty else {
            throw .verificationFailed("Nothing to MAC")
        }
        let mac = Self.computeMac(
            sharedSecret: sharedSecret ?? Data(),
            sender: (ourUserId.value, ourDeviceId),
            receiver: (peerUserId.value, peerDeviceId ?? ""),
            transactionId: transactionId,
            keys: keysToMac
        )
        try await sendWithTransientRetry { () async throws(MatrixError) in
            try await toDevice.send(
                eventType: "m.key.verification.mac",
                content: VerificationMac(
                    keys: mac.list, mac: mac.perKey,
                    transactionId: transactionId),
                to: peerUserId, devices: targetDevices
            )
        }
        ourMacSent = true
        if state == .keysExchanged {
            state = .macSent
        }
    }

    /// Verify an incoming `mac`. The key IDs verified are the ones the peer
    /// actually MACs in the message (spec: MACs cover the keys given in the
    /// message) — peers commonly MAC more than we predicted (e.g. Element
    /// sends device + master key). `peerKeys` is a resolution pool, so it
    /// may be a superset. Returns the verified IDs.
    @discardableResult
    public func receiveMac(
        _ mac: VerificationMac, peerKeys: [KeyToMAC]
    ) async throws(MatrixError) -> [String] {
        guard state == .keysExchanged || state == .macSent else {
            throw .verificationFailed("Unexpected mac in state \(state)")
        }
        let messageIds = mac.mac.keys.sorted()
        guard !messageIds.isEmpty else {
            throw .verificationFailed("Peer MAC covers no keys")
        }
        let pool = Dictionary(
            uniqueKeysWithValues: peerKeys.map { ($0.id, $0.key) })
        var resolved: [KeyToMAC] = []
        resolved.reserveCapacity(messageIds.count)
        for id in messageIds {
            guard let key = pool[id] else {
                throw .verificationFailed("Unknown key \(id) in peer MAC")
            }
            resolved.append(KeyToMAC(id: id, key: key))
        }
        let expected = Self.computeMac(
            sharedSecret: sharedSecret ?? Data(),
            sender: (peerUserId.value, peerDeviceId ?? ""),
            receiver: (ourUserId.value, ourDeviceId),
            transactionId: transactionId,
            keys: resolved
        )
        for key in resolved {
            guard mac.mac[key.id] == expected.perKey[key.id] else {
                throw .verificationFailed("MAC mismatch for key \(key.id)")
            }
        }
        guard mac.keys == expected.list else {
            throw .verificationFailed("Key-list MAC mismatch")
        }
        state = .macReceived
        return messageIds
    }

    /// Send `m.key.verification.done` to close the flow. Transient send
    /// failures are retried (see `sendWithTransientRetry`).
    public func sendDone() async throws(MatrixError) {
        guard state == .macReceived || state == .macSent else {
            throw .verificationFailed("Unexpected done in state \(state)")
        }
        try await sendWithTransientRetry { () async throws(MatrixError) in
            try await toDevice.send(
                eventType: "m.key.verification.done",
                content: VerificationDone(transactionId: transactionId),
                to: peerUserId, devices: targetDevices
            )
        }
        state = .done
    }

    // MARK: - Cancel

    /// Abort with `m.key.verification.cancel`.
    public func cancel(code: String = "m.user", reason: String = "") async throws(MatrixError) {
        try await toDevice.send(
            eventType: "m.key.verification.cancel",
            content: VerificationCancel(
                code: code, reason: reason, transactionId: transactionId),
            to: peerUserId, devices: targetDevices
        )
        state = .cancelled
    }

    /// Record an incoming cancel.
    public func receiveCancel(_ cancel: VerificationCancel) {
        state = .cancelled
    }

    // MARK: - Spec crypto

    /// `base64(sha256(base64text(accepter_pubkey) || canonical(start_content)))`.
    ///
    /// Per spec the ephemeral key enters the preimage as its unpadded-base64
    /// *text* (ASCII), not raw key bytes — Element computes it this way, so
    /// raw bytes fail interop while passing self-to-self tests.
    static func commitment(
        ephemeralPublicB64: String, startContent: VerificationStart
    ) throws(MatrixError) -> String {
        guard
            Primitives.base64UnpaddedDecode(ephemeralPublicB64) != nil
        else {
            throw .verificationFailed("Malformed ephemeral key")
        }
        var preimage = Data(ephemeralPublicB64.utf8)
        preimage.append(try canonicalStart(startContent))
        let digest = Crypto.SHA256.hash(data: preimage)
        return Primitives.base64UnpaddedEncode(Data(digest))
    }

    /// Canonical JSON of a `start` message body.
    static func canonicalStart(_ start: VerificationStart) throws(MatrixError) -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(start)
        } catch {
            throw .encodingError("Start content encoding failed: \(error.localizedDescription)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .encodingError("Start content is not a JSON object")
        }
        return try CryptoPrimitives.canonicalJSON(json)
    }

    /// 6 SAS bytes via `HKDF(shared, salt: "", info: "MATRIX_KEY_VERIFICATION_SAS|…")`.
    static func deriveSASBytes(
        sharedSecret: Data,
        startSender: (user: String, device: String, key: String),
        acceptSender: (user: String, device: String, key: String),
        transactionId: String
    ) throws(MatrixError) -> Data {
        let info =
            "MATRIX_KEY_VERIFICATION_SAS|\(startSender.user)|\(startSender.device)|\(startSender.key)|"
            + "\(acceptSender.user)|\(acceptSender.device)|\(acceptSender.key)|\(transactionId)"
        guard !startSender.key.isEmpty, !acceptSender.key.isEmpty else {
            throw .verificationFailed("SAS derivation needs both ephemeral keys")
        }
        return Primitives.hkdfSHA256(
            inputKeyMaterial: sharedSecret, salt: Data(),
            info: Data(info.utf8), outputByteCount: 6
        )
    }

    /// MACs for keys + key-ID list (`hkdf-hmac-sha256.v2`).
    ///
    /// Returns per-key MACs plus the single list MAC. On the wire the list
    /// MAC goes in the `keys` STRING (not per key ID) — see `VerificationMac`.
    static func computeMac(
        sharedSecret: Data,
        sender: (user: String, device: String),
        receiver: (user: String, device: String),
        transactionId: String,
        keys: [KeyToMAC]
    ) -> (perKey: [String: String], list: String) {
        func macKey(suffix: String) -> Crypto.SymmetricKey {
            let info =
                "MATRIX_KEY_VERIFICATION_MAC\(sender.user)\(sender.device)"
                + "\(receiver.user)\(receiver.device)\(transactionId)\(suffix)"
            let derived = Primitives.hkdfSHA256(
                inputKeyMaterial: sharedSecret, salt: Data(),
                info: Data(info.utf8), outputByteCount: 32
            )
            return Crypto.SymmetricKey(data: derived)
        }
        var keyMacs: [String: String] = [:]
        for key in keys {
            let code = Crypto.HMAC<Crypto.SHA256>.authenticationCode(
                for: Data(key.key.utf8), using: macKey(suffix: key.id))
            keyMacs[key.id] = Primitives.base64UnpaddedEncode(Data(code))
        }
        let list = keys.map(\.id).sorted().joined(separator: ",")
        // The list MAC is a single value filed under `keys` (spec wire shape).
        let listCode = Crypto.HMAC<Crypto.SHA256>.authenticationCode(
            for: Data(list.utf8), using: macKey(suffix: "KEY_IDS"))
        return (keyMacs, Primitives.base64UnpaddedEncode(Data(listCode)))
    }

    // MARK: - Helpers

    /// Retry a terminal verification send (MAC, done) on transient failures.
    ///
    /// A momentary network blip on the final `done` turned an otherwise
    /// successful verification into an error screen (live run: the peer
    /// showed success while our `done` failed with a network error). Only
    /// `MatrixError.isRetryable` is retried — anything else throws
    /// immediately — and resends stay idempotent because session state
    /// advances only after the send succeeds.
    private func sendWithTransientRetry(
        _ send: () async throws(MatrixError) -> Void
    ) async throws(MatrixError) {
        var attempt = 0
        while true {
            do {
                try await send()
                return
            } catch {
                attempt += 1
                guard attempt < 4, error.isRetryable, !Task.isCancelled else {
                    throw error
                }
                if let after = error.retryAfter {
                    // Honor server backoff, capped so the flow never hangs long.
                    try? await Task.sleep(for: min(after, .seconds(10)))
                } else {
                    try? await Task.sleep(for: .seconds(Int64(1 << (attempt - 1))))
                }
                if Task.isCancelled { throw error }
            }
        }
    }

    private func requireState(_ expected: VerificationState, _ action: String) throws(MatrixError) {
        guard state == expected else {
            throw .verificationFailed(
                "Cannot \(action) in state \(state) (expected \(expected))")
        }
    }
}
