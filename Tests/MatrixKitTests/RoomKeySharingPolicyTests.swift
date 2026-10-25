import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit
@testable import MatrixKitCrypto

@Suite("RoomKeySharingPolicy")
struct RoomKeySharingPolicyTests {
    private let bobUser = UserId(unchecked: "@bob:x")

    /// Alice's connector plus a query response for Bob's published BOB
    /// device, signed by `signer` (nil: unsigned) and advertising
    /// `selfSigning` as Bob's self-signing key.
    private func makeAlice(
        signer: SigningKey?, selfSigning: SigningKey
    ) async throws -> (alice: OlmConnector, keys: FakeKeys) {
        let keys = FakeKeys()
        let alice = OlmConnector(keys: keys, sender: FakeSender())
        try await alice.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: UserId(unchecked: "@alice:x"), deviceId: DeviceId("ALICE"))
        let bob = OlmConnector(keys: keys, sender: FakeSender())
        try await bob.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: bobUser, deviceId: DeviceId("BOB"))
        try await bob.ensureKeys()

        var device = try #require(
            try await keys.queryKeys(users: [bobUser]).deviceKeys[bobUser.value]?["BOB"])
        if let signer {
            let canonical = try CryptoPrimitives.canonicalJSON([
                "user_id": device.userId,
                "device_id": device.deviceId,
                "algorithms": device.algorithms,
                "keys": device.keys,
            ])
            device.signatures[bobUser.value] = [
                "ed25519:\(signer.publicKeyBase64)":
                    Primitives.base64UnpaddedEncode(try signer.sign(canonical))
            ]
        }
        let selfSigningKey = CrossSigningKey(
            userId: bobUser.value, usage: ["self_signing"],
            keys: ["ed25519:\(selfSigning.publicKeyBase64)": selfSigning.publicKeyBase64])
        // Each cache miss queries once; queue enough for retries.
        for _ in 0..<2 {
            await keys.enqueueQueryResponse(KeyQueryResponse(
                deviceKeys: [bobUser.value: ["BOB": device]],
                selfSigningKeys: [bobUser.value: selfSigningKey]))
        }
        return (alice, keys)
    }

    @Test("all devices policy offers an unsigned device")
    func allDevices() async throws {
        let selfSigning = SigningKey.generate()
        let (alice, _) = try await makeAlice(signer: nil, selfSigning: selfSigning)
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
    }

    @Test("cross-signed policy offers a device signed by the self-signing key")
    func signedDeviceIsOffered() async throws {
        let selfSigning = SigningKey.generate()
        let (alice, _) = try await makeAlice(signer: selfSigning, selfSigning: selfSigning)
        await alice.setRoomKeySharingPolicy(.crossSignedOnly)
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
        #expect(await alice.canShareRoomKeys(with: DeviceId("BOB"), of: bobUser))
    }

    @Test("cross-signed policy withholds from an unsigned device")
    func unsignedDeviceIsWithheld() async throws {
        let selfSigning = SigningKey.generate()
        let (alice, _) = try await makeAlice(signer: nil, selfSigning: selfSigning)
        await alice.setRoomKeySharingPolicy(.crossSignedOnly)
        #expect(try await alice.deviceIds(for: bobUser) == [])
        #expect(await !alice.canShareRoomKeys(with: DeviceId("BOB"), of: bobUser))
    }

    @Test("cross-signed policy withholds from a device signed by another key")
    func forgedSignatureIsWithheld() async throws {
        let selfSigning = SigningKey.generate()
        let (alice, _) = try await makeAlice(
            signer: SigningKey.generate(), selfSigning: selfSigning)
        await alice.setRoomKeySharingPolicy(.crossSignedOnly)
        #expect(try await alice.deviceIds(for: bobUser) == [])
    }

    @Test("policy change drops cached device lists")
    func policyChangeInvalidatesCache() async throws {
        let selfSigning = SigningKey.generate()
        let (alice, _) = try await makeAlice(signer: nil, selfSigning: selfSigning)
        #expect(try await alice.deviceIds(for: bobUser) == ["BOB"])
        await alice.setRoomKeySharingPolicy(.crossSignedOnly)
        #expect(try await alice.deviceIds(for: bobUser) == [])
    }
}
