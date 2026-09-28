import Foundation
import Testing

import MatrixKitTesting

@testable import MatrixKit

/// Full SAS handshake with every to-device message Olm-encrypted: two
/// `OlmConnector`s over one `FakeKeys` homeserver, `VerificationSession`s
/// driving `EncryptedToDeviceSender`, recorded `m.room.encrypted` pumped
/// peer-to-peer. Mirrors `fullHandshake` in VerificationTests.
@Suite("EncryptedVerification")
struct EncryptedVerificationTests {
    private func connector(
        user: UserId, device: String, keys: FakeKeys, sender: FakeSender
    ) async throws -> OlmConnector {
        let conn = OlmConnector(keys: keys, sender: sender)
        try await conn.configure(
            identity: .generate(), userId: user, deviceId: DeviceId(device))
        try await conn.ensureKeys()
        return conn
    }

    /// Decrypt freshly recorded sends into inner to-device events.
    private func pump(
        _ sender: FakeSender, from user: UserId, to conn: OlmConnector,
        from index: inout Int
    ) async -> [BasicEvent] {
        let all = await sender.sent
        let fresh = Array(all.dropFirst(index))
        index = all.count
        let events = fresh.map {
            BasicEvent(type: $0.type, sender: user, content: $0.content)
        }
        return await conn.decrypt(events)
    }

    private func decode<T: Decodable>(
        _ type: T.Type, _ event: BasicEvent
    ) throws -> T {
        let data = try JSONEncoder().encode(
            AnyCodableDictionary(event.content))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func inner(
        _ events: [BasicEvent], type: String
    ) throws -> BasicEvent {
        guard let event = events.first(where: { $0.type == type }) else {
            throw MatrixError.verificationFailed("No \(type) decrypted")
        }
        return event
    }

    @Test("Full handshake over Olm-encrypted to-device agrees on SAS and MACs")
    func fullHandshakeEncrypted() async throws {
        let alice = UserId(unchecked: "@alice:x")
        let bob = UserId(unchecked: "@bob:x")
        let keys = FakeKeys()
        let aliceOut = FakeSender()
        let bobOut = FakeSender()
        let aliceConn = try await connector(
            user: alice, device: "ALICE", keys: keys, sender: aliceOut)
        let bobConn = try await connector(
            user: bob, device: "BOB", keys: keys, sender: bobOut)

        let txn = UUID().uuidString
        let requester = VerificationSession(
            toDevice: EncryptedToDeviceSender(olm: aliceConn),
            role: .requester, ourUserId: alice, ourDeviceId: "ALICE",
            peerUserId: bob, peerDevices: ["BOB"], transactionId: txn)
        let responder = VerificationSession(
            toDevice: EncryptedToDeviceSender(olm: bobConn),
            role: .responder, ourUserId: bob, ourDeviceId: "BOB",
            peerUserId: alice, peerDevices: ["ALICE"], transactionId: txn)
        var aliceIdx = 0
        var bobIdx = 0

        try await requester.sendRequest()
        let reqEvents = await pump(
            aliceOut, from: alice, to: bobConn, from: &aliceIdx)
        _ = try inner(reqEvents, type: "m.key.verification.request")

        try await responder.sendReady()
        let readyEvents = await pump(
            bobOut, from: bob, to: aliceConn, from: &bobIdx)
        try await requester.receiveReady(
            try decode(
                VerificationReady.self,
                inner(readyEvents, type: "m.key.verification.ready")))

        try await requester.sendStart()
        let startEvents = await pump(
            aliceOut, from: alice, to: bobConn, from: &aliceIdx)
        try await responder.receiveStart(
            try decode(
                VerificationStart.self,
                inner(startEvents, type: "m.key.verification.start")))

        try await responder.sendAccept()
        let acceptEvents = await pump(
            bobOut, from: bob, to: aliceConn, from: &bobIdx)
        try await requester.receiveAccept(
            try decode(
                VerificationAccept.self,
                inner(acceptEvents, type: "m.key.verification.accept")))

        try await requester.sendKey()
        let reqKeyEvents = await pump(
            aliceOut, from: alice, to: bobConn, from: &aliceIdx)
        _ = try await responder.receiveKey(
            try decode(
                VerificationKey.self,
                inner(reqKeyEvents, type: "m.key.verification.key")))

        try await responder.sendKey()
        let resKeyEvents = await pump(
            bobOut, from: bob, to: aliceConn, from: &bobIdx)
        let sas = try await requester.receiveKey(
            try decode(
                VerificationKey.self,
                inner(resKeyEvents, type: "m.key.verification.key")))
        #expect(sas != nil)
        #expect(await responder.state == .keysExchanged)
        #expect(await requester.sasEmoji() == responder.sasEmoji())
        #expect(await requester.sasDecimals() == responder.sasDecimals())

        // Every message on the wire was m.room.encrypted.
        for entry in await aliceOut.sent + bobOut.sent {
            #expect(entry.type == "m.room.encrypted")
        }

        let aliceKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:ALICEM", key: "ALICEM")]
        let bobKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:BOBM", key: "BOBM")]
        try await requester.confirm(keysToMac: aliceKeys)
        try await responder.confirm(keysToMac: bobKeys)

        let aliceMacEvents = await pump(
            aliceOut, from: alice, to: bobConn, from: &aliceIdx)
        let bobMacEvents = await pump(
            bobOut, from: bob, to: aliceConn, from: &bobIdx)
        let verifiedByBob = try await responder.receiveMac(
            try decode(
                VerificationMac.self,
                inner(aliceMacEvents, type: "m.key.verification.mac")),
            peerKeys: aliceKeys)
        let verifiedByAlice = try await requester.receiveMac(
            try decode(
                VerificationMac.self,
                inner(bobMacEvents, type: "m.key.verification.mac")),
            peerKeys: bobKeys)
        #expect(verifiedByBob == ["ed25519:ALICEM"])
        #expect(verifiedByAlice == ["ed25519:BOBM"])

        try await requester.sendDone()
        try await responder.sendDone()
        #expect(await requester.state == .done)
        #expect(await responder.state == .done)
    }

    @Test("Verification guards reject out-of-order messages")
    func misuseGuards() async throws {
        let requester = VerificationSession(
            toDevice: FakeSender(), role: .requester,
            ourUserId: UserId(unchecked: "@alice:x"), ourDeviceId: "ALICE",
            peerUserId: UserId(unchecked: "@bob:x"), peerDevices: ["BOB"],
            transactionId: "txn")
        try await requester.sendRequest()
        await #expect(throws: MatrixError.verificationFailed(
            "Peer does not support m.sas.v1"))
        {
            try await requester.receiveReady(VerificationReady(
                fromDevice: "BOB", methods: ["m.show_qrcode"]))
        }

        let responder = VerificationSession(
            toDevice: FakeSender(), role: .responder,
            ourUserId: UserId(unchecked: "@bob:x"), ourDeviceId: "BOB",
            peerUserId: UserId(unchecked: "@alice:x"), peerDevices: ["ALICE"],
            transactionId: "txn")
        let start = VerificationStart(fromDevice: "ALICE", transactionId: "txn")
        try await responder.receiveStart(start)
        await #expect(throws: MatrixError.verificationFailed(
            "Unsupported agreement: md5/md5/hkdf-hmac-sha256.v2"))
        {
            try await responder.receiveAccept(VerificationAccept(
                keyAgreementProtocol: "md5", hash: "md5",
                messageAuthenticationCode: "hkdf-hmac-sha256.v2",
                shortAuthenticationString: ["emoji"], commitment: "c"))
        }
        try await responder.receiveAccept(VerificationAccept(
            shortAuthenticationString: ["emoji"], commitment: "c"))
        await #expect(throws: MatrixError.verificationFailed(
            "No ephemeral key (send start/accept first)"))
        {
            try await responder.sendKey()
        }
        // A start arriving after accept (duplicate delivery, or racing
        // the responder's own) is ignored, not a failure.
        try await responder.receiveStart(start)
        #expect(await responder.state == .accepted)
    }
}
