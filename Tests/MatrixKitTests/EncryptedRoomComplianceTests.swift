import Foundation
import Testing

import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixKit

/// Encrypted-room compliance suite: the full Megolm loop over real
/// transports — share, send, receive, decrypt — plus persistence.
///
/// Exercised: world keys routes, `PUT /sendToDevice`, `KeyClient`,
/// `OlmConnector`, `RoomCrypto` (the pieces `MatrixClient` wires).
@Suite("EncryptedRoomCompliance")
struct EncryptedRoomComplianceTests {
    struct Peer {
        var user: UserId
        var device: DeviceId
        var olm: OlmConnector
        var crypto: RoomCrypto
        var sender: FakeRoomSender
        var transport: MatrixTransport
    }

    private func peer(
        _ harness: Harness, user: String, device: String,
        keystore: (any KeyStore)? = nil
    ) async throws -> Peer {
        let world = await harness.world
        let userId = UserId(unchecked: user)
        let deviceId = DeviceId(device)
        let (access, _) = await world.mintTokens(userId: userId, deviceId: deviceId)
        let baseURL = await harness.baseURL
        let transport = MatrixTransport(homeserver: baseURL)
        let session = Session(
            homeserver: baseURL, userId: userId,
            deviceId: deviceId, accessToken: access)
        let keys = KeyClient(transport: transport, session: session)
        let toDevice = ToDeviceClient(transport: transport, session: session)
        let olm = OlmConnector(keys: keys, sender: toDevice)
        try await olm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: userId, deviceId: deviceId)
        try await olm.ensureKeys()
        let sender = FakeRoomSender()
        let crypto = RoomCrypto(sharer: olm, sender: sender, keystore: keystore)
        await crypto.setLocalUserId(userId)
        return Peer(
            user: userId, device: deviceId, olm: olm,
            crypto: crypto, sender: sender, transport: transport)
    }

    private func shareToBob(
        _ harness: Harness, alice: Peer, bob: Peer, room: RoomId
    ) async throws {
        let world = await harness.world
        try await alice.crypto.shareRoomKey(roomId: room, users: [bob.user])
        struct Envelope: Decodable {
            var messages: [String: [String: [String: AnyCodable]]]
        }
        let shares = await world.recordedToDeviceSends()
        let envelope = try JSONDecoder().decode(
            Envelope.self, from: try #require(shares.last).body)
        let payload = try #require(envelope.messages[bob.user.value]?[bob.device.value])
        let wire = BasicEvent(
            type: "m.room.encrypted", sender: alice.user, content: payload)
        let received = await bob.olm.decrypt([wire])
        #expect(received.count == 1)
        for event in received {
            _ = await bob.crypto.receiveRoomKey(event)
        }
    }

    @Test("Share, send, receive, and decrypt round-trip")
    func megolmLoop() async throws {
        try await withHarness { harness in
            let alice = try await peer(harness, user: "@alice:test", device: "ALICE")
            let bob = try await peer(harness, user: "@bob:test", device: "BOB")
            let room = RoomId(unchecked: "!room:test")
            // Alice shares the room key; Bob receives it from the recorded
            // to-device send, as his sync loop would deliver it.
            try await shareToBob(harness, alice: alice, bob: bob, room: room)
            let world = await harness.world
            #expect(await world.recordedToDeviceSends().count == 1)
            // Alice sends; Bob decrypts to plaintext.
            _ = try await alice.crypto.sendEncryptedContent(
                room, MessageContent.text("secret Hi Bob"))
            let sent = await alice.sender.sent
            #expect(sent.count == 1)
            let cipher = MessageEvent(
                type: sent[0].type,
                eventId: EventId(unchecked: "$e:test"),
                sender: alice.user,
                roomId: room,
                originServerTs: 1,
                content: sent[0].content)
            let decrypted = await bob.crypto.decryptRoomEvent(cipher, in: room)
            #expect(decrypted?.content["body"] == .string("secret Hi Bob"))
            try? await alice.transport.shutdown()
            try? await bob.transport.shutdown()
        }
    }

    @Test("Sessions persist and restore across instances")
    func persistRestore() async throws {
        try await withHarness { harness in
            let store = InMemoryKeyStore()
            let alice = try await peer(harness, user: "@alice:test", device: "ALICE")
            let bob = try await peer(harness, user: "@bob:test", device: "BOB", keystore: store)
            let room = RoomId(unchecked: "!room:test")
            try await shareToBob(harness, alice: alice, bob: bob, room: room)
            // A fresh instance restores Bob's inbound sessions from disk
            // and decrypts without re-receiving the key.
            let bob2 = RoomCrypto(
                sharer: bob.olm, sender: FakeRoomSender(), keystore: store)
            await bob2.restore()
            _ = try await alice.crypto.sendEncryptedContent(
                room, MessageContent.text("after restart"))
            let sent = await alice.sender.sent
            let cipher = MessageEvent(
                type: sent.last?.type ?? "m.room.encrypted",
                eventId: EventId(unchecked: "$e2:test"),
                sender: alice.user,
                roomId: room,
                originServerTs: 2,
                content: try #require(sent.last?.content))
            #expect(await bob2.decryptRoomEvent(cipher, in: room)?.content["body"]
                == .string("after restart"))
            try? await alice.transport.shutdown()
            try? await bob.transport.shutdown()
        }
    }

    @Test("Tampered one-time-key signatures fail the claim")
    func badOTKSignature() async throws {
        try await withHarness { harness in
            let alice = try await peer(harness, user: "@alice:test", device: "ALICE")
            // Bob's device record is real, but his one-time key carries a
            // garbage signature: verification fails at claim time.
            let bobMaterial = DeviceIdentityKeys.generate()
            let bobKeys = try bobMaterial.deviceKeys(
                userId: "@bob:test", deviceId: "BOB")
            let (keys, _, _) = await harness.keyClient()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: bobKeys,
                oneTimeKeys: ["signed_curve25519:0000": .object([
                    "key": .string(Primitives.base64UnpaddedEncode(Data(repeating: 3, count: 32))),
                    "signatures": .object(["@bob:test": .object([
                        "ed25519:BOB": .string(Primitives.base64UnpaddedEncode(Data(repeating: 4, count: 64))),
                    ])]),
                ])]))
            await #expect(throws: MatrixError.self) {
                try await alice.olm.sendEncrypted(
                    eventType: "m.secret.send",
                    content: ["secret": .string("s3cr3t")],
                    to: UserId(unchecked: "@bob:test"), devices: [DeviceId("BOB")])
            }
            try? await alice.transport.shutdown()
        }
    }

    @Test("Backup exports round-trip through import")
    func backupExportImport() async throws {
        try await withHarness { harness in
            let alice = try await peer(harness, user: "@alice:test", device: "ALICE")
            let bob = try await peer(harness, user: "@bob:test", device: "BOB")
            let room = RoomId(unchecked: "!room:test")
            try await shareToBob(harness, alice: alice, bob: bob, room: room)
            // Exports list received sessions; malformed blobs throw.
            let exports = await bob.crypto.backupExports()
            #expect(exports.count == 1)
            #expect(exports.first?.roomId == room)
            let fresh = RoomCrypto(sharer: bob.olm, sender: FakeRoomSender())
            try await fresh.importSession(
                roomId: room, sessionId: "sid1", export: exports.first!.export)
            await #expect(throws: MatrixError.self) {
                try await fresh.importSession(
                    roomId: room, sessionId: "sid2", export: Data("garbage".utf8))
            }
            try? await alice.transport.shutdown()
            try? await bob.transport.shutdown()
        }
    }
}
