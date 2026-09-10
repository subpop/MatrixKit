import Crypto
import Foundation
import MatrixKitCrypto
import Testing

@testable import MatrixKit

/// Recording `ToDeviceSender` for driving verification flows in-process.
actor FakeSender: ToDeviceSender {
    var sent: [(type: String, content: [String: AnyCodable], devices: [String])] = []

    func send(
        eventType: String, content: [String: AnyCodable],
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        sent.append((eventType, content, devices))
    }

    func send<T: Encodable & Sendable>(
        eventType: String, content: T,
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError("Fake cannot encode content: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dictData = try? JSONSerialization.data(withJSONObject: json),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: dictData)
        else {
            throw .encodingError("Fake cannot encode content")
        }
        sent.append((eventType, dict, devices))
    }

    func last<T: Decodable>(_ type: T.Type, event: String) throws -> T {
        guard let entry = sent.last(where: { $0.type == event }) else {
            throw MatrixError.verificationFailed("No \(event) recorded")
        }
        let data = try JSONEncoder().encode(AnyCodableDictionary(entry.content))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// `ToDeviceSender` that fails the next N sends with a canned error, for
/// exercising the transient-retry paths on terminal verification sends.
actor FlakySender: ToDeviceSender {
    var sent: [(type: String, content: [String: AnyCodable], devices: [String])] = []
    var attempts: [String: Int] = [:]
    var failuresRemaining = 0
    var failure: MatrixError = .networkError("boom")

    func failNext(_ n: Int, with error: MatrixError = .networkError("boom")) {
        failuresRemaining = n
        failure = error
    }

    func doneSends() -> Int {
        sent.filter { $0.type == "m.key.verification.done" }.count
    }

    func doneAttempts() -> Int {
        attempts["m.key.verification.done"] ?? 0
    }

    func macSends() -> Int {
        sent.filter { $0.type == "m.key.verification.mac" }.count
    }

    func send(
        eventType: String, content: [String: AnyCodable],
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        attempts[eventType, default: 0] += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        sent.append((eventType, content, devices))
    }

    func send<T: Encodable & Sendable>(
        eventType: String, content: T,
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        attempts[eventType, default: 0] += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError("Flaky cannot encode content: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dictData = try? JSONSerialization.data(withJSONObject: json),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: dictData)
        else {
            throw .encodingError("Flaky cannot encode content")
        }
        sent.append((eventType, dict, devices))
    }

    func last<T: Decodable>(_ type: T.Type, event: String) throws -> T {
        guard let entry = sent.last(where: { $0.type == event }) else {
            throw MatrixError.verificationFailed("No \(event) recorded")
        }
        let data = try JSONEncoder().encode(AnyCodableDictionary(entry.content))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@Suite("CryptoPrimitives")
struct CryptoPrimitivesTests {
    @Test("Base58 known vector + round-trip")
    func base58() throws {
        #expect(CryptoPrimitives.base58Encode(Data("hello world".utf8)) == "StV1DL6CwTryKyV")
        let bytes = Data([0, 0, 1, 2, 3, 255])
        let encoded = CryptoPrimitives.base58Encode(bytes)
        #expect(encoded.hasPrefix("11"))
        #expect(CryptoPrimitives.base58Decode(encoded) == bytes)
        #expect(CryptoPrimitives.base58Decode("0OIl") == nil)
    }

    @Test("Canonical JSON sorts keys and strips whitespace")
    func canonicalJSON() throws {
        let data = try CryptoPrimitives.canonicalJSON(
            ["b": 1, "a": [true, NSNull(), "x\"y"]] as [String: Any])
        #expect(String(data: data, encoding: .utf8) == #"{"a":[true,null,"x\"y"],"b":1}"#)
    }

    @Test("Canonical JSON rejects floats")
    func canonicalJSONRejectsFloat() {
        #expect(throws: MatrixError.self) {
            try CryptoPrimitives.canonicalJSON(["x": 1.5] as [String: Any])
        }
    }

    @Test("SAS indices/decimals on all-0xFF bytes")
    func sasAllFF() {
        let bytes = Data(repeating: 0xFF, count: 6)
        #expect(CryptoPrimitives.sasIndices(bytes: bytes) == [63, 63, 63, 63, 63, 63, 63])
        #expect(CryptoPrimitives.sasDecimals(bytes: bytes) == [9191, 9191, 9191])
        let emoji = CryptoPrimitives.sasEmoji(indices: [63])
        #expect(emoji == [SASEmoji(emoji: "📌", description: "pin")])
    }

    @Test("Commitment is deterministic and key-bound")
    func commitment() throws {
        let start = VerificationStart(fromDevice: "A", transactionId: "txn")
        let c1 = try VerificationSession.commitment(
            ephemeralPublicB64: Primitives.base64UnpaddedEncode(Data(repeating: 1, count: 32)),
            startContent: start)
        let c2 = try VerificationSession.commitment(
            ephemeralPublicB64: Primitives.base64UnpaddedEncode(Data(repeating: 1, count: 32)),
            startContent: start)
        #expect(c1 == c2)
        let c3 = try VerificationSession.commitment(
            ephemeralPublicB64: Primitives.base64UnpaddedEncode(Data(repeating: 2, count: 32)),
            startContent: start)
        #expect(c1 != c3)
    }

    @Test("Commitment hashes the base64-text key per spec, not raw bytes")
    func commitmentUsesKeyText() throws {
        // Real wire key from a live session (decodes to 32 bytes).
        let keyB64 = "7jfEIRkede2Tdof9UFmGVQAM6baNJU1ErJ4ZzBbudkY"
        let start = VerificationStart(fromDevice: "ADEV", transactionId: "TXN")
        // Hardcoded canonical JSON pins the serializer too.
        let canonical = #"{"from_device":"ADEV","hashes":["sha256"],"key_agreement_protocols":["curve25519-hkdf-sha256"],"message_authentication_codes":["hkdf-hmac-sha256.v2"],"method":"m.sas.v1","short_authentication_string":["emoji","decimal"],"transaction_id":"TXN"}"#
        #expect(try VerificationSession.canonicalStart(start) == Data(canonical.utf8))
        // Spec preimage: ASCII(key text) + canonical JSON.
        var preimage = Data(keyB64.utf8)
        preimage.append(Data(canonical.utf8))
        let expected = Primitives.base64UnpaddedEncode(
            Data(Crypto.SHA256.hash(data: preimage)))
        #expect(
            try VerificationSession.commitment(
                ephemeralPublicB64: keyB64, startContent: start) == expected)
        // The old raw-bytes preimage must differ (guards the interop bug).
        var wrong = try #require(Primitives.base64UnpaddedDecode(keyB64))
        wrong.append(Data(canonical.utf8))
        let wrongHash = Primitives.base64UnpaddedEncode(
            Data(Crypto.SHA256.hash(data: wrong)))
        #expect(expected != wrongHash)
    }

    @Test("MACs are deterministic and key-bound")
    func mac() {
        let secret = Data(repeating: 7, count: 32)
        let keys = [VerificationSession.KeyToMAC(id: "ed25519:ABC", key: "ABC")]
        let m1 = VerificationSession.computeMac(
            sharedSecret: secret, sender: ("@a:x", "A"),
            receiver: ("@b:x", "B"), transactionId: "t", keys: keys)
        let m2 = VerificationSession.computeMac(
            sharedSecret: secret, sender: ("@a:x", "A"),
            receiver: ("@b:x", "B"), transactionId: "t", keys: keys)
        #expect(m1 == m2)
        #expect(m1.perKey["ed25519:ABC"] != nil)
        #expect(!m1.list.isEmpty)
        let m3 = VerificationSession.computeMac(
            sharedSecret: Data(repeating: 8, count: 32), sender: ("@a:x", "A"),
            receiver: ("@b:x", "B"), transactionId: "t", keys: keys)
        #expect(m1 != m3)
    }
}

@Suite("VerificationSession")
struct VerificationSessionTests {
    private func pair() -> (
        requester: VerificationSession, responder: VerificationSession,
        reqSender: FakeSender, resSender: FakeSender
    ) {
        let reqSender = FakeSender()
        let resSender = FakeSender()
        // Both sides share the request's transaction ID (as on the wire).
        let transactionId = UUID().uuidString
        let requester = VerificationSession(
            toDevice: reqSender, role: .requester,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "ALICE",
            peerUserId: UserId(unchecked: "@bob:x"),
            transactionId: transactionId)
        let responder = VerificationSession(
            toDevice: resSender, role: .responder,
            ourUserId: UserId(unchecked: "@bob:x"), ourDeviceId: "BOB",
            peerUserId: UserId(unchecked: "@alice:x"),
            peerDeviceId: "ALICE",
            transactionId: transactionId)
        return (requester, responder, reqSender, resSender)
    }

    @Test("Out-of-order calls throw")
    func ordering() async {
        let (requester, _, _, _) = pair()
        await #expect(throws: MatrixError.self) {
            try await requester.sendStart()
        }
        await #expect(throws: MatrixError.self) {
            try await requester.sendKey()
        }
    }

    @Test("Full requester↔responder handshake agrees on SAS and MACs")
    func fullHandshake() async throws {
        let (requester, responder, reqSender, resSender) = pair()

        try await requester.sendRequest()
        try await responder.sendReady()
        let ready: VerificationReady = try await resSender.last(
            VerificationReady.self, event: "m.key.verification.ready")
        try await requester.receiveReady(ready)

        try await requester.sendStart()
        let start: VerificationStart = try await reqSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await responder.receiveStart(start)

        try await responder.sendAccept()
        let accept: VerificationAccept = try await resSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await requester.receiveAccept(accept)

        try await requester.sendKey()
        let reqKey: VerificationKey = try await reqSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await responder.receiveKey(reqKey)

        try await responder.sendKey()
        let resKey: VerificationKey = try await resSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        let sas = try await requester.receiveKey(resKey)
        #expect(sas != nil)

        // Both sides derived identical SAS (responder derives on confirm path
        // state check: responder is .keysExchanged after sendKey).
        #expect(await responder.state == .keysExchanged)
        #expect(await requester.sasEmoji() == responder.sasEmoji())
        #expect(await requester.sasDecimals() == responder.sasDecimals())
        #expect(await requester.sasEmoji().count == 7)

        // MAC exchange both directions.
        let aliceKeys = [VerificationSession.KeyToMAC(id: "ed25519:ALICEM", key: "ALICEM")]
        let bobKeys = [VerificationSession.KeyToMAC(id: "ed25519:BOBM", key: "BOBM")]
        try await requester.confirm(keysToMac: aliceKeys)
        try await responder.confirm(keysToMac: bobKeys)

        let aliceMac: VerificationMac = try await reqSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        let bobMac: VerificationMac = try await resSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        let verifiedByBob = try await responder.receiveMac(aliceMac, peerKeys: aliceKeys)
        let verifiedByAlice = try await requester.receiveMac(bobMac, peerKeys: bobKeys)
        #expect(verifiedByBob == ["ed25519:ALICEM"])
        #expect(verifiedByAlice == ["ed25519:BOBM"])

        try await requester.sendDone()
        try await responder.sendDone()
        #expect(await requester.state == .done)
        #expect(await responder.state == .done)
    }

    @Test("Peer-started handshake agrees on SAS (interop fallback)")
    func responderStartedHandshake() async throws {
        // Either side may send `start` per spec. The driver is
        // requester-starts, but a peer that starts first is accepted.
        let (requester, responder, reqSender, resSender) = pair()

        try await requester.sendRequest()
        try await responder.sendReady()
        let ready: VerificationReady = try await resSender.last(
            VerificationReady.self, event: "m.key.verification.ready")
        try await requester.receiveReady(ready)

        // Requester waits — it must not start (that collides).
        try await responder.sendStart()
        let start: VerificationStart = try await resSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await requester.receiveStart(start)
        #expect(await requester.state == .started)

        // Requester accepts without ever receiving accept: no commitment
        // to check, keys still agree.
        try await requester.sendAccept()
        let accept: VerificationAccept = try await reqSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await responder.receiveAccept(accept)

        try await requester.sendKey()
        let reqKey: VerificationKey = try await reqSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await responder.receiveKey(reqKey)

        try await responder.sendKey()
        let resKey: VerificationKey = try await resSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        let sas = try await requester.receiveKey(resKey)
        #expect(sas != nil)
        #expect(await responder.state == .keysExchanged)
        #expect(await requester.sasEmoji() == responder.sasEmoji())
        #expect(await requester.sasDecimals() == responder.sasDecimals())
        #expect(await requester.sasEmoji().count == 7)
    }

    @Test("Requester accepts start arriving before ready")
    func startBeforeReady() async throws {
        let (requester, _, reqSender, _) = pair()
        try await requester.sendRequest()
        // Ready and start can arrive out of order (plaintext vs encrypted
        // batches): start alone locks the peer and starts the flow.
        try await requester.receiveStart(VerificationStart(
            fromDevice: "BOB", shortAuthenticationString: ["emoji"],
            transactionId: "txn"))
        #expect(await requester.state == .started)
        try await requester.sendAccept()
        let accept: VerificationAccept = try await reqSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        #expect(accept.commitment.isEmpty == false)
    }

    @Test("Start collision resolves by lexicographic tie-break")
    func startCollisionTieBreak() async throws {
        // Both sides send `start` (live Element run: requester start at :44,
        // responder start at :46). The smaller (user, device) wins instead
        // of both sides cancelling.
        let transactionId = UUID().uuidString
        let lowSender = FakeSender()
        let highSender = FakeSender()
        let low = VerificationSession(
            toDevice: lowSender, role: .requester,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "A",
            peerUserId: UserId(unchecked: "@alice:x"),
            peerDeviceId: "B",
            peerDevices: ["B"],
            transactionId: transactionId)
        let high = VerificationSession(
            toDevice: highSender, role: .responder,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "B",
            peerUserId: UserId(unchecked: "@alice:x"),
            peerDeviceId: "A",
            peerDevices: ["A"],
            transactionId: transactionId)
        try await low.sendRequest()
        try await high.sendReady()
        let ready = VerificationReady(fromDevice: "B", methods: ["m.sas.v1"])
        try await low.receiveReady(ready)
        try await low.sendStart()
        try await high.sendStart()
        let lowStart = VerificationStart(
            fromDevice: "A", shortAuthenticationString: ["emoji", "decimal"],
            transactionId: transactionId)
        let highStart = VerificationStart(
            fromDevice: "B", shortAuthenticationString: ["emoji", "decimal"],
            transactionId: transactionId)
        // Each receives the peer's start: low ("A") wins, high adopts it.
        try await low.receiveStart(highStart)
        #expect(await low.weSentStart == true)
        try await high.receiveStart(lowStart)
        #expect(await high.weSentStart == false)
        // Winner waits for accept; loser accepts and sends its key.
        try await high.sendAccept()
        let accept: VerificationAccept = try await highSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await low.receiveAccept(accept)
        try await low.sendKey()
        let lowKey: VerificationKey = try await lowSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await high.receiveKey(lowKey)
        try await high.sendKey()
        let highKey: VerificationKey = try await highSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        let sas = try await low.receiveKey(highKey)
        #expect(sas != nil)
        #expect(await low.sasEmoji() == high.sasEmoji())
    }

    @Test("Late ready after start is ignored, not a failure")
    func lateReadyIgnored() async throws {
        let (requester, _, _, _) = pair()
        try await requester.sendRequest()
        try await requester.receiveStart(VerificationStart(
            fromDevice: "BOB", shortAuthenticationString: ["emoji"],
            transactionId: "txn"))
        #expect(await requester.state == .started)
        try await requester.receiveReady(
            VerificationReady(fromDevice: "BOB", methods: ["m.sas.v1"]))
        #expect(await requester.state == .started)
    }

    /// Drive a flaky-sender pair to keys-exchanged (requester-starts).
    private func drivenFlakyPair() async throws -> (
        requester: VerificationSession, responder: VerificationSession,
        reqSender: FlakySender, resSender: FlakySender
    ) {
        let transactionId = UUID().uuidString
        let reqSender = FlakySender()
        let resSender = FlakySender()
        let requester = VerificationSession(
            toDevice: reqSender, role: .requester,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "ALICE",
            peerUserId: UserId(unchecked: "@bob:x"),
            transactionId: transactionId)
        let responder = VerificationSession(
            toDevice: resSender, role: .responder,
            ourUserId: UserId(unchecked: "@bob:x"), ourDeviceId: "BOB",
            peerUserId: UserId(unchecked: "@alice:x"),
            peerDeviceId: "ALICE",
            transactionId: transactionId)
        try await requester.sendRequest()
        try await responder.sendReady()
        let ready: VerificationReady = try await resSender.last(
            VerificationReady.self, event: "m.key.verification.ready")
        try await requester.receiveReady(ready)
        try await requester.sendStart()
        let start: VerificationStart = try await reqSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await responder.receiveStart(start)
        try await responder.sendAccept()
        let accept: VerificationAccept = try await resSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await requester.receiveAccept(accept)
        try await requester.sendKey()
        let reqKey: VerificationKey = try await reqSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await responder.receiveKey(reqKey)
        try await responder.sendKey()
        let resKey: VerificationKey = try await resSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await requester.receiveKey(resKey)
        #expect(await requester.state == .keysExchanged)
        return (requester, responder, reqSender, resSender)
    }

    @Test("Done survives transient network failures")
    func doneRetriesTransientFailures() async throws {
        // Live run: the peer showed success while our terminal `done`
        // failed with a network error and the sheet showed a failure.
        let (requester, responder, reqSender, resSender) = try await drivenFlakyPair()
        let aliceKeys = [VerificationSession.KeyToMAC(id: "ed25519:ALICEM", key: "ALICEM")]
        let bobKeys = [VerificationSession.KeyToMAC(id: "ed25519:BOBM", key: "BOBM")]
        try await requester.confirm(keysToMac: aliceKeys)
        try await responder.confirm(keysToMac: bobKeys)
        let aliceMac: VerificationMac = try await reqSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        _ = try await responder.receiveMac(aliceMac, peerKeys: aliceKeys)
        let bobMac: VerificationMac = try await resSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        _ = try await requester.receiveMac(bobMac, peerKeys: bobKeys)
        await reqSender.failNext(2)
        try await requester.sendDone()
        #expect(await requester.state == .done)
        #expect(await reqSender.doneAttempts() == 3)
        #expect(await reqSender.doneSends() == 1)
    }

    @Test("Done fails fast on non-retryable errors")
    func doneFailsFastOnTerminalErrors() async throws {
        let (requester, _, reqSender, _) = try await drivenFlakyPair()
        try await requester.confirm(keysToMac: [
            VerificationSession.KeyToMAC(id: "ed25519:A", key: "A")
        ])
        await reqSender.failNext(3, with: .unknownToken)
        await #expect(throws: MatrixError.self) {
            try await requester.sendDone()
        }
        #expect(await reqSender.doneSends() == 0)
        #expect(await requester.state == .macSent)
    }

    @Test("Done gives up after the retry budget")
    func doneGivesUpAfterRetryBudget() async throws {
        let (requester, _, reqSender, _) = try await drivenFlakyPair()
        try await requester.confirm(keysToMac: [
            VerificationSession.KeyToMAC(id: "ed25519:A", key: "A")
        ])
        await reqSender.failNext(10)
        await #expect(throws: MatrixError.self) {
            try await requester.sendDone()
        }
        // Initial try + 3 retries, then the error surfaces.
        #expect(await reqSender.doneSends() == 0)
        let attempts = await reqSender.failuresRemaining
        #expect(attempts == 6)
        #expect(await requester.state == .macSent)
    }

    @Test("Confirm survives a transient network failure")
    func confirmRetriesTransientFailures() async throws {
        let (requester, _, reqSender, _) = try await drivenFlakyPair()
        await reqSender.failNext(1)
        try await requester.confirm(keysToMac: [
            VerificationSession.KeyToMAC(id: "ed25519:A", key: "A")
        ])
        #expect(await requester.state == .macSent)
        #expect(await reqSender.macSends() == 1)
    }

    @Test("Post-ready sends address only the engaged device")
    func postReadyNarrowsRecipients() async throws {
        // Regression: post-ready traffic (start/key/mac/done) fanned out
        // to every queried device instead of the single engaged one,
        // confusing the peer (live Element run: start ×18).
        let transactionId = UUID().uuidString
        let reqSender = FakeSender()
        let requester = VerificationSession(
            toDevice: reqSender, role: .requester,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "A1",
            peerUserId: UserId(unchecked: "@bob:x"),
            peerDevices: ["B1", "B2", "B3"],
            transactionId: transactionId)
        try await requester.sendRequest()
        let request = await reqSender.sent.last
        #expect(request?.type == "m.key.verification.request")
        #expect(request?.devices.sorted() == ["B1", "B2", "B3"])
        try await requester.receiveReady(
            VerificationReady(fromDevice: "B2", methods: ["m.sas.v1"]))
        try await requester.sendStart()
        let startEntry = await reqSender.sent.last
        #expect(startEntry?.type == "m.key.verification.start")
        #expect(startEntry?.devices == ["B2"])

        let resSender = FakeSender()
        let responder = VerificationSession(
            toDevice: resSender, role: .responder,
            ourUserId: UserId(unchecked: "@bob:x"), ourDeviceId: "B2",
            peerUserId: UserId(unchecked: "@alice:x"),
            peerDevices: ["A1", "A2"],
            transactionId: transactionId)
        try await responder.sendReady()
        let readyEntry = await resSender.sent.last
        #expect(readyEntry?.devices.sorted() == ["A1", "A2"])
        let start: VerificationStart = try await reqSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await responder.receiveStart(start)
        try await responder.sendAccept()
        let acceptEntry = await resSender.sent.last
        #expect(acceptEntry?.type == "m.key.verification.accept")
        #expect(acceptEntry?.devices == ["A1"])
    }

    @Test("Tampered MAC is rejected")
    func tamperedMac() async throws {
        let (requester, responder, reqSender, resSender) = pair()
        try await requester.sendRequest()
        try await responder.sendReady()
        let ready: VerificationReady = try await resSender.last(
            VerificationReady.self, event: "m.key.verification.ready")
        try await requester.receiveReady(ready)
        try await requester.sendStart()
        let start: VerificationStart = try await reqSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await responder.receiveStart(start)
        try await responder.sendAccept()
        let accept: VerificationAccept = try await resSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await requester.receiveAccept(accept)
        try await requester.sendKey()
        let reqKey: VerificationKey = try await reqSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await responder.receiveKey(reqKey)
        try await responder.sendKey()
        let resKey: VerificationKey = try await resSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await requester.receiveKey(resKey)

        let keys = [VerificationSession.KeyToMAC(id: "ed25519:X", key: "X")]
        try await responder.confirm(keysToMac: keys)
        let mac: VerificationMac = try await resSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        let tampered = VerificationMac(
            keys: mac.keys,
            mac: ["ed25519:X": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
            transactionId: mac.transactionId)
        await #expect(throws: MatrixError.self) {
            try await requester.receiveMac(tampered, peerKeys: keys)
        }
    }

    /// Drive a pair to keys-exchanged (request→ready→start→accept→keys).
    private func exchangedPair() async throws -> (
        requester: VerificationSession, responder: VerificationSession,
        reqSender: FakeSender, resSender: FakeSender
    ) {
        let (requester, responder, reqSender, resSender) = pair()
        try await requester.sendRequest()
        try await responder.sendReady()
        let ready: VerificationReady = try await resSender.last(
            VerificationReady.self, event: "m.key.verification.ready")
        try await requester.receiveReady(ready)
        try await requester.sendStart()
        let start: VerificationStart = try await reqSender.last(
            VerificationStart.self, event: "m.key.verification.start")
        try await responder.receiveStart(start)
        try await responder.sendAccept()
        let accept: VerificationAccept = try await resSender.last(
            VerificationAccept.self, event: "m.key.verification.accept")
        try await requester.receiveAccept(accept)
        try await requester.sendKey()
        let reqKey: VerificationKey = try await reqSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await responder.receiveKey(reqKey)
        try await responder.sendKey()
        let resKey: VerificationKey = try await resSender.last(
            VerificationKey.self, event: "m.key.verification.key")
        _ = try await requester.receiveKey(resKey)
        return (requester, responder, reqSender, resSender)
    }

    /// The Element case: peer MACs device + master key while our pool is a
    /// superset. Verification follows the IDs in the message, not predictions.
    @Test("Peer MAC covering extra keys verifies from a superset pool")
    func multiKeyPeerMac() async throws {
        let (requester, responder, _, resSender) = try await exchangedPair()
        let device = VerificationSession.KeyToMAC(id: "ed25519:DEV", key: "DEVKEY")
        let master = VerificationSession.KeyToMAC(id: "ed25519:MASTER", key: "MASTERKEY")
        try await responder.confirm(keysToMac: [device, master])
        let mac: VerificationMac = try await resSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        #expect(mac.mac.keys.sorted() == ["ed25519:DEV", "ed25519:MASTER"])
        let pool = [device, master, .init(id: "ed25519:OTHER", key: "OTHERKEY")]
        let verified = try await requester.receiveMac(mac, peerKeys: pool)
        #expect(verified == ["ed25519:DEV", "ed25519:MASTER"])
    }

    @Test("Unknown key ID in peer MAC is rejected")
    func unknownKeyId() async throws {
        let (requester, responder, _, resSender) = try await exchangedPair()
        let device = VerificationSession.KeyToMAC(id: "ed25519:DEV", key: "DEVKEY")
        try await responder.confirm(keysToMac: [device])
        let mac: VerificationMac = try await resSender.last(
            VerificationMac.self, event: "m.key.verification.mac")
        let master = VerificationSession.KeyToMAC(id: "ed25519:MASTER", key: "MASTERKEY")
        await #expect(throws: MatrixError.self) {
            try await requester.receiveMac(mac, peerKeys: [master])
        }
    }
}

@Suite("VerificationEchoFiltering")
struct VerificationEchoFilteringTests {
    /// Self-verify must not address our own device: the server would echo
    /// our messages back and the echoes poison the handshake (own `key`
    /// fails the accept-commitment check).
    @Test("Self-verify excludes our own device from recipients")
    func excludesSelf() async throws {
        let sender = FakeSender()
        let session = VerificationSession(
            toDevice: sender, role: .requester,
            ourUserId: UserId(unchecked: "@me:x"), ourDeviceId: "MINE",
            peerUserId: UserId(unchecked: "@me:x"),
            peerDevices: ["MINE", "OTHER"])
        try await session.sendRequest()
        let targets = await sender.sent.map(\.devices)
        #expect(targets == [["OTHER"]])
    }

    @Test("Other-user verify keeps all recipient devices")
    func keepsOthers() async throws {
        let sender = FakeSender()
        let session = VerificationSession(
            toDevice: sender, role: .requester,
            ourUserId: UserId(unchecked: "@me:x"), ourDeviceId: "MINE",
            peerUserId: UserId(unchecked: "@bob:x"),
            peerDevices: ["MINE", "BOBDEV"])
        try await session.sendRequest()
        let targets = await sender.sent.map(\.devices)
        #expect(targets == [["MINE", "BOBDEV"]])
    }

    @Test("Own key echo is ignored, not a commitment failure")
    func ownKeyEchoIgnored() async throws {
        let sender = FakeSender()
        let session = VerificationSession(
            toDevice: sender, role: .requester,
            ourUserId: UserId(unchecked: "@me:x"), ourDeviceId: "MINE",
            peerUserId: UserId(unchecked: "@me:x"),
            peerDevices: ["OTHER"])
        try await session.sendRequest()
        try await session.receiveReady(
            VerificationReady(fromDevice: "OTHER", methods: ["m.sas.v1"]))
        try await session.sendStart()
        try await session.receiveAccept(
            VerificationAccept(
                shortAuthenticationString: ["emoji"], commitment: "bogus"))
        try await session.sendKey()
        let ownKey: VerificationKey = try await sender.last(
            VerificationKey.self, event: "m.key.verification.key")
        // Echo of our own key: ignored, state unchanged, no throw.
        let result = try await session.receiveKey(ownKey)
        #expect(result == nil)
        #expect(await session.state == .accepted)
    }
}

@Suite("VerificationWireShape")struct VerificationWireShapeTests {
    /// `method` must be a plain string on the wire. An earlier revision sent
    /// `{"name": "m.sas.v1"}`; real clients (Element) reject that shape and
    /// the flow stalls with no emoji ever shown.
    @Test("Start encodes method as a string")
    func startMethodIsString() throws {
        let start = VerificationStart(
            fromDevice: "A", transactionId: "txn1")
        let data = try JSONEncoder().encode(start)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["method"] as? String == "m.sas.v1")
    }

    @Test("Start decodes the spec shape real clients send")
    func startDecodesSpecShape() throws {
        let wire = """
            {"from_device":"B","method":"m.sas.v1",
             "key_agreement_protocols":["curve25519-hkdf-sha256"],
             "hashes":["sha256"],
             "message_authentication_codes":["hkdf-hmac-sha256.v2"],
             "short_authentication_string":["decimal","emoji"],
             "transaction_id":"txn1"}
            """
        let start = try JSONDecoder().decode(
            VerificationStart.self, from: Data(wire.utf8))
        #expect(start.method == "m.sas.v1")
        #expect(start.fromDevice == "B")
    }

    @Test("Accept decodes the method-less shape real clients send")
    func acceptDecodesSpecShape() throws {
        // Element's accept carries NO `method` field (per spec). An earlier
        // revision required it, so live accepts failed with "Could not
        // decode accept" and the flow stalled with no emoji ever shown.
        let wire = """
            {"hash":"sha256","key_agreement_protocol":"curve25519-hkdf-sha256",
             "message_authentication_code":"hkdf-hmac-sha256.v2",
             "short_authentication_string":["emoji","decimal"],
             "commitment":"hoTQNdln+cQxfkfEyMKk0agpmxdIywog+fwu/wsmEfM",
             "transaction_id":"txn1"}
            """
        let accept = try JSONDecoder().decode(
            VerificationAccept.self, from: Data(wire.utf8))
        #expect(accept.hash == "sha256")
        #expect(accept.shortAuthenticationString == ["emoji", "decimal"])
        #expect(accept.commitment.hasPrefix("hoTQNdln"))
        // Our own accept encodes without `method` too.
        let data = try JSONEncoder().encode(accept)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["method"] == nil)
    }

    @Test("Key carries transaction_id on the wire")
    func keyCarriesTransactionId() throws {
        let key = VerificationKey(key: "k", transactionId: "txn1")
        let data = try JSONEncoder().encode(key)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["transaction_id"] as? String == "txn1")
    }

    @Test("Mac encodes keys as a string and mac as a map")
    func macWireShape() throws {
        // Per spec `keys` is a SINGLE string (MAC of the key-ID list) and
        // `mac` maps key IDs to key MACs. An earlier revision sent both as
        // maps; peers couldn't verify, never sent done, and both sides
        // stalled forever after emoji compare.
        let mac = VerificationMac(
            keys: "listmac", mac: ["ed25519:A": "keymac"],
            transactionId: "txn1")
        let data = try JSONEncoder().encode(mac)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["keys"] as? String == "listmac")
        #expect((json["mac"] as? [String: String]) == ["ed25519:A": "keymac"])
        // The spec example shape decodes too.
        let wire = """
            {"keys":"2Wptgo4CwmLo/Y8B8qinxApKaCkBG2fjTWB7AbP5Uy+aIbygsSdLOFzvdDjww8zUVKCmI02eP9xtyJxc/cLiBA",
             "mac":{"ed25519:ABCDEF":"fQpGIW1Snz+pwLZu6sTy2aHy/DYWWTspTJRPyNp0PKkymfIsNffysMl6ObMMFdIJhk6g6pwlIqZ54rxo8SLmAg"},
             "transaction_id":"S0meUniqueAndOpaqueString"}
            """
        let decoded = try JSONDecoder().decode(
            VerificationMac.self, from: Data(wire.utf8))
        #expect(decoded.keys.hasPrefix("2Wptgo4C"))
        #expect(decoded.mac["ed25519:ABCDEF"]?.hasPrefix("fQpGIW1Snz") == true)
        #expect(decoded.transactionId == "S0meUniqueAndOpaqueString")
    }
}
