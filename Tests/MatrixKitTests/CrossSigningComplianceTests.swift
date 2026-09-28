import Foundation
import Testing

import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixKit

/// Cross-signing compliance: generate, upload, fetch, device signing
/// with cryptographic verification, and the UIAA reset retry.
///
/// Exercised registry endpoints: `POST /keys/device_signing/upload`,
/// `POST /keys/query`, `POST /keys/signatures/upload`.
@Suite("CrossSigningCompliance")
struct CrossSigningComplianceTests {
    @Test("Generate, upload, fetch round-trips the identity")
    func uploadFetch() async throws {
        try await withHarness { harness in
            let (signing, _, _) = await harness.crossSigning()
            #expect(await signing.hasKeys == false)
            let publicKeys = await signing.generate()
            #expect(await signing.hasKeys == true)
            try await signing.upload()
            let fetched = try await signing.fetchKeys(users: [UserId(unchecked: "@alice:test")])
            #expect(fetched.masterKeys?["@alice:test"]?.keys.values.contains(publicKeys.master) == true)
            #expect(fetched.selfSigningKeys?["@alice:test"] != nil)
            #expect(fetched.userSigningKeys?["@alice:test"] != nil)
        }
    }

    @Test("Exported keys import into a fresh instance")
    func exportImport() async throws {
        try await withHarness { harness in
            let (signing, _, _) = await harness.crossSigning()
            let publicKeys = await signing.generate()
            let exported = try #require(await signing.exportPrivateKeys())
            let (fresh, _, _) = await harness.crossSigning()
            #expect(await fresh.hasKeys == false)
            try await fresh.importPrivateKeys(
                master: exported.master, selfSigning: exported.selfSigning,
                userSigning: exported.userSigning)
            #expect(await fresh.hasKeys == true)
            #expect(await fresh.publicKeys?.master == publicKeys.master)
        }
    }

    @Test("Self-signing a device verifies cryptographically")
    func signDevice() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            let (signing, _, _) = await harness.crossSigning()
            _ = await signing.generate()
            // Publish a real self-signed device record.
            let material = DeviceIdentityKeys.generate()
            let deviceKeys = try material.deviceKeys(
                userId: "@alice:test", deviceId: "ALICEDEVICE")
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(deviceKeys: deviceKeys))
            #expect(await signing.isDeviceVerified(deviceKeys) == false)
            let keyId = try await signing.signDevice(
                userId: UserId(unchecked: "@alice:test"), deviceId: DeviceId("ALICEDEVICE"))
            #expect(keyId.hasPrefix("ed25519:"))
            let fetched = try await signing.fetchKeys(users: [UserId(unchecked: "@alice:test")])
            let signed = try #require(fetched.deviceKeys["@alice:test"]?["ALICEDEVICE"])
            #expect(await signing.isDeviceVerified(signed))
        }
    }

    @Test("Reset completes the UIAA stage and retries")
    func uploadWithReset() async throws {
        try await withHarness { harness in
            let (signing, _, _) = await harness.crossSigning()
            _ = await signing.generate()
            await harness.setOverride(
                method: "POST", path: "/_matrix/client/v3/keys/device_signing/upload",
                response: .json(
                    UIAAChallenge(
                        flows: [UIAFlow(stages: [UIAAChallenge.resetStage])],
                        session: "reset-1"),
                    status: 401))
            // First attempt challenges, retry with the reset stage succeeds.
            try await signing.uploadWithReset()
            let uploads = await harness.requests.filter {
                $0.path == "/_matrix/client/v3/keys/device_signing/upload"
            }
            #expect(uploads.count == 2)
        }
    }

    @Test("Upload without keys throws before networking")
    func uploadGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "t")
        let signing = CrossSigning(transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await signing.upload()
        }
        try? await transport.shutdown()
    }
}
