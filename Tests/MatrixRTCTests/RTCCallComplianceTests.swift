import Foundation
import Testing

import MatrixKit
import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixRTC

/// RTC call compliance suite: membership join/refresh/leave against
/// world state, SFU discovery fallbacks, credential exchange, delayed
/// leave scheduling, and local key registration.
///
/// Exercised registry endpoints: `PUT /rooms/{roomId}/state/{eventType}/{stateKey}`
/// (membership + delayed schedule via query),
/// `GET /rooms/{roomId}/state`, `GET /v1/rtc/transports` (+ unstable),
/// `POST /user/{userId}/openid/request_token`,
/// `POST /unstable/.../delayed_events/{delayId}` (overrides),
/// `/sfu/get` + `/get_token` (harness-loopback SFU, overrides).
@Suite("RTCCallCompliance")
struct RTCCallComplianceTests {
    @MainActor
    private func setup(_ harness: Harness) async -> (
        session: RTCCallSession, client: MatrixClient, room: RoomId
    ) {
        let baseURL = await harness.baseURL
        let client = await MatrixClient.restore(
            homeserver: baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: "harness-token-alice")
        let room = try! await client.rooms.create(CreateRoomRequest())
        return (RTCCallSession(client: client), client, room)
    }

    @Test("Join publishes membership, schedules leave, mints credentials")
    @MainActor
    func joinLeave() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (session, client, room) = await setup(harness)
            let joined = try await session.join(roomId: room)
            #expect(joined.membership.userId == UserId(unchecked: "@alice:test"))
            #expect(joined.credentials.token == "livekit-jwt")
            #expect(joined.credentials.url.absoluteString == "wss://livekit.test")
            #expect(joined.leaveDelayId == "d1")
            // Membership visible through state.
            let members = try await session.memberships(roomId: room)
            #expect(members.map(\.membershipID) == [joined.membership.membershipID])
            // Refresh keeps the ID, extends expiry.
            try await session.refresh(roomId: room, membership: joined.membership)
            let refreshed = try #require(try await session.memberships(roomId: room).first)
            #expect(refreshed.membershipID == joined.membership.membershipID)
            #expect(refreshed.expires > joined.membership.expires)
            // Leave clears the membership and cancels the delayed leave.
            try await session.leave(roomId: room, delayId: joined.leaveDelayId)
            #expect(try await session.memberships(roomId: room).isEmpty)
            #expect(await world.recordedDelayedCancels() == ["d1"])
            let schedules = await world.recordedDelayedSchedules()
            #expect(schedules.count == 1)
            #expect(schedules.first?.delayMs == 60_000)
            try? await client.transport.shutdown()
        }
    }

    @Test("Unstable transports endpoint backs up v1")
    @MainActor
    func transportsFallback() async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/rtc/transports",
                response: .matrixError(code: "M_UNRECOGNIZED", message: "nope", status: 404))
            let (session, client, room) = await setup(harness)
            let joined = try await session.join(roomId: room)
            #expect(joined.credentials.token == "livekit-jwt")
            try? await client.transport.shutdown()
        }
    }

    @Test("v2 token endpoint backs up legacy")
    @MainActor
    func tokenFallback() async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "POST", path: "/sfu/get",
                response: .raw("nope", status: 500))
            let (session, client, room) = await setup(harness)
            let joined = try await session.join(roomId: room)
            #expect(joined.credentials.token == "livekit-jwt")
            try? await client.transport.shutdown()
        }
    }

    @Test("Total SFU failure surfaces credentialFailed")
    @MainActor
    func tokenFailure() async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "POST", path: "/sfu/get",
                response: .raw("nope", status: 500))
            await harness.setOverride(
                method: "POST", path: "/get_token",
                response: .raw("nope", status: 500))
            let (session, client, room) = await setup(harness)
            await #expect(throws: RTCError.self) {
                try await session.join(roomId: room)
            }
            try? await client.transport.shutdown()
        }
    }

    @Test("Distribute with no peers registers local keys")
    @MainActor
    func distributeLocal() async throws {
        try await withHarness { harness in
            let (session, client, _) = await setup(harness)
            let key = CallKeyDistributor.generateKey()
            #expect(key.count == 16)
            try await session.keys.distribute(
                roomId: RoomId(unchecked: "!room:test"),
                memberships: [],
                membershipID: "member-1", index: 0, key: key)
            let identity = CallKeyDistributor.legacyIdentity(
                matrixID: "@alice:test", deviceID: "ALICEDEVICE")
            #expect(await session.keys.newestKey(for: identity)?.key == key)
            try? await client.transport.shutdown()
        }
    }

    @Test("Distribute Olm-encrypts keys to live peers")
    @MainActor
    func distributeToPeer() async throws {
        try await withHarness { harness in
            let (session, client, room) = await setup(harness)
            let world = await harness.world
            // Bob's real Olm identity, published through the world's keys
            // routes (same shape a live homeserver serves).
            let bobUser = UserId(unchecked: "@bob:test")
            let (bobAccess, _) = await world.mintTokens(
                userId: bobUser, deviceId: DeviceId("BOB"))
            let (bobKeys, _, _) = await harness.keyClient(token: bobAccess)
            let bob = OlmConnector(keys: bobKeys, sender: FakeSender())
            let bobMaterial = DeviceIdentityKeys.generate()
            try await bob.configure(
                identity: bobMaterial, userId: bobUser, deviceId: DeviceId("BOB"))
            try await bob.ensureKeys()
            // Alice configures Olm and distributes to Bob's membership.
            let aliceMaterial = DeviceIdentityKeys.generate()
            try await client.olm.configure(
                identity: aliceMaterial,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            let key = CallKeyDistributor.generateKey()
            let bobMembership = CallMembership(
                membershipID: "bob-member", userId: bobUser, deviceId: "BOB",
                fociPreferred: [], focusActive: RTCFocus(type: "livekit"),
                createdTs: 1_000_000, expires: 1_000_000 + 4 * 3_600_000)
            try await session.keys.distribute(
                roomId: room, memberships: [bobMembership],
                membershipID: "member-1", index: 3, key: key)
            let sends = await world.recordedToDeviceSends()
            #expect(sends.count == 1)
            // Olm envelope on the wire; the RTC payload decrypts inside.
            #expect(sends.first?.type == "m.room.encrypted")
            struct SendEnvelope: Decodable {
                var messages: [String: [String: [String: AnyCodable]]]
            }
            let envelope = try JSONDecoder().decode(
                SendEnvelope.self, from: try #require(sends.first).body)
            let payload = try #require(envelope.messages["@bob:test"]?["BOB"])
            let wire = BasicEvent(
                type: "m.room.encrypted",
                sender: UserId(unchecked: "@alice:test"),
                content: payload)
            let inner = await bob.decrypt([wire])
            #expect(inner.first?.type == "io.element.call.encryption_keys")
            #expect(inner.first?.content["keys"]?.objectValue?["index"]?.intValue == 3)
            #expect(await session.keys.newestKey(for: CallKeyDistributor.legacyIdentity(
                matrixID: "@alice:test", deviceID: "ALICEDEVICE"))?.key == key)
            try? await client.transport.shutdown()
        }
    }

    @Test("Winner focus overrides transports discovery")
    @MainActor
    func winnerFocus() async throws {
        try await withHarness { harness in
            let (session, client, room) = await setup(harness)
            let baseURL = await harness.baseURL
            let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
            let winner = CallMembership(
                membershipID: "winner", userId: UserId(unchecked: "@bob:test"),
                deviceId: "BOB", fociPreferred: [],
                focusActive: RTCFocus(
                    type: "livekit", livekitServiceURL: baseURL.absoluteString),
                createdTs: nowMs, expires: nowMs + 4 * 3_600_000)
            let creds = try await session.credentials.credentials(
                roomId: room,
                membership: CallMembership(
                    membershipID: "m", userId: UserId(unchecked: "@alice:test"),
                    deviceId: "ALICEDEVICE", fociPreferred: [],
                    focusActive: RTCFocus(type: "livekit"),
                    createdTs: 1_000_000, expires: 1_000_000 + 4 * 3_600_000),
                memberships: [winner])
            #expect(creds.token == "livekit-jwt")
            // No transports lookup happened — the winner short-circuits.
            let lookups = await harness.requests.filter {
                $0.path.contains("rtc/transports")
            }
            #expect(lookups.isEmpty)
            try? await client.transport.shutdown()
        }
    }

    @Test("Pumped encrypted batches register peer keys")
    @MainActor
    func pumpIngest() async throws {
        try await withHarness { harness in
            let (session, client, room) = await setup(harness)
            let world = await harness.world
            // Bob's real Olm stack, sending through the world's to-device
            // route (not a fake): the full encrypted path.
            let bobUser = UserId(unchecked: "@bob:test")
            let (bobAccess, _) = await world.mintTokens(
                userId: bobUser, deviceId: DeviceId("BOB"))
            let bobTransport = MatrixTransport(homeserver: await harness.baseURL)
            let bobSession = Session(
                homeserver: await harness.baseURL, userId: bobUser,
                deviceId: DeviceId("BOB"), accessToken: bobAccess)
            let bobToDevice = ToDeviceClient(transport: bobTransport, session: bobSession)
            let (bobKeys, _, _) = await harness.keyClient(token: bobAccess)
            let bob = OlmConnector(keys: bobKeys, sender: bobToDevice)
            try await bob.configure(
                identity: DeviceIdentityKeys.generate(),
                userId: bobUser, deviceId: DeviceId("BOB"))
            try await bob.ensureKeys()
            // Alice configures Olm and pumps decrypted batches into keys.
            // ensureKeys publishes her device keys + one-time keys so Bob
            // can open a session to her.
            let aliceMaterial = DeviceIdentityKeys.generate()
            try await client.olm.configure(
                identity: aliceMaterial,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            try await client.olm.ensureKeys()
            try await client.configureEncryption()
            let pump = Task { await session.keys.pumpToDevice() }
            defer { pump.cancel() }
            let key = CallKeyDistributor.generateKey()
            let content: [String: AnyCodable] = [
                "keys": .object(["index": .int(2), "key": .string(key.base64EncodedString())]),
                "member": .object([
                    "id": .string("bob-member"),
                    "claimed_device_id": .string("BOB"),
                ]),
                "room_id": .string(room.value),
                "session": .object([
                    "application": .string("m.call"),
                    "call_id": .string(""),
                    "scope": .string("m.room"),
                ]),
                "sent_ts": .int(1),
            ]
            try await bob.sendEncrypted(
                eventType: "io.element.call.encryption_keys", content: content,
                to: UserId(unchecked: "@alice:test"), devices: [DeviceId("ALICEDEVICE")])
            // Loop the send back into Alice's sync stream, as the server's
            // to-device routing would.
            struct SendEnvelope: Decodable {
                var messages: [String: [String: [String: AnyCodable]]]
            }
            let sends = await world.recordedToDeviceSends()
            let envelope = try JSONDecoder().decode(
                SendEnvelope.self, from: try #require(sends.first).body)
            let payload = try #require(envelope.messages["@alice:test"]?["ALICEDEVICE"])
            await world.queueToDevice(BasicEvent(
                type: "m.room.encrypted",
                sender: UserId(unchecked: "@bob:test"),
                content: payload))
            try await client.syncOnce()
            let hashed = CallKeyDistributor.liveKitIdentity(
                matrixID: "@bob:test", claimedDeviceID: "BOB",
                memberID: "bob-member")
            let deadline = ContinuousClock.now + .seconds(2)
            while await session.keys.newestKey(for: hashed) == nil,
                ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(await session.keys.newestKey(for: hashed)?.index == 2)
            // Malformed batches are ignored, never trap.
            await world.queueToDevice(BasicEvent(
                type: "io.element.call.encryption_keys",
                sender: UserId(unchecked: "@mallory:test"),
                content: ["room_id": .string(room.value)]))
            try await client.syncOnce()
            try? await client.transport.shutdown()
            try? await bobTransport.shutdown()
        }
    }
}
