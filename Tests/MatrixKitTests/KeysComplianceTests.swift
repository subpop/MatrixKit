import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Key compliance suite: device-key upload/query/claim round-trips,
/// cross-signing upload, and signature-failure mapping.
///
/// Exercised registry endpoints: `POST /keys/{upload,device_signing/upload,signatures/upload,query,claim}`.
@Suite("KeysCompliance")
struct KeysComplianceTests {
    private func deviceKeys(user: String = "@alice:test", device: String = "ALICEDEVICE") -> DeviceKeys {
        DeviceKeys(
            userId: user, deviceId: device,
            keys: [
                "curve25519:\(device)": "curve-key",
                "ed25519:\(device)": "ed-key",
            ])
    }

    @Test("Upload then query returns device keys")
    func uploadQuery() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            let response = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: deviceKeys()))
            #expect(response.oneTimeKeyCounts["signed_curve25519"] == 0)
            let queried = try await keys.queryKeys(users: [UserId(unchecked: "@alice:test")])
            let entry = try #require(queried.deviceKeys["@alice:test"]?["ALICEDEVICE"])
            #expect(entry.keys["ed25519:ALICEDEVICE"] == "ed-key")
            // Unknown users query empty, not missing.
            let empty = try await keys.queryKeys(users: [UserId(unchecked: "@ghost:test")])
            #expect(empty.deviceKeys["@ghost:test"]?.isEmpty == true)
        }
    }

    @Test("One-time keys claim once, then pop")
    func claimPops() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: deviceKeys(),
                oneTimeKeys: [
                    "signed_curve25519:AAA": .object([
                        "key": .string("otk-key"),
                        "signatures": .object([:]),
                    ])
                ]))
            let claimed = try await keys.claimKeys(
                user: UserId(unchecked: "@alice:test"), device: "ALICEDEVICE")
            #expect(claimed.oneTimeKeys["@alice:test"]?["ALICEDEVICE"]?["signed_curve25519:AAA"]?.key == "otk-key")
            let drained = try await keys.claimKeys(
                user: UserId(unchecked: "@alice:test"), device: "ALICEDEVICE")
            #expect(drained.oneTimeKeys.isEmpty)
        }
    }

    @Test("Claim with wildcard picks a device with keys")
    func claimWildcard() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: deviceKeys(device: "PHONE"),
                oneTimeKeys: [
                    "signed_curve25519:BBB": .object([
                        "key": .string("phone-otk"),
                        "signatures": .object([:]),
                    ])
                ]))
            let claimed = try await keys.claimKeys(
                user: UserId(unchecked: "@alice:test"))
            #expect(claimed.oneTimeKeys["@alice:test"]?["PHONE"]?["signed_curve25519:BBB"]?.key == "phone-otk")
        }
    }

    @Test("Query filters by device list")
    func queryFilter() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(deviceKeys: deviceKeys(device: "D1")))
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(deviceKeys: deviceKeys(device: "D2")))
            let filtered = try await keys.queryKeys(KeyQueryRequest(
                deviceKeys: ["@alice:test": ["D1"]]))
            #expect(filtered.deviceKeys["@alice:test"]?.keys.sorted() == ["D1"])
            let all = try await keys.queryKeys(users: [UserId(unchecked: "@alice:test")])
            #expect(all.deviceKeys["@alice:test"]?.keys.sorted() == ["D1", "D2"])
        }
    }

    @Test("Cross-signing keys upload")
    func signingKeys() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            try await keys.uploadSigningKeys(UploadSigningKeysRequest(
                masterKey: CrossSigningKey(
                    userId: "@alice:test", usage: ["master"],
                    keys: ["ed25519:msk": "pub"])))
            let uploads = await harness.requests.filter { $0.path == "/_matrix/client/v3/keys/device_signing/upload" }
            #expect(uploads.count == 1)
            #expect(uploads.first?.hadBearer == true)
        }
    }

    @Test("Signatures upload accepts, failures throw")
    func signatures() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            try await keys.uploadSignatures(UploadSignaturesRequest(signed: [
                "@alice:test": ["ALICEDEVICE": deviceKeys()],
            ]))
            await harness.setOverride(
                method: "POST", path: "/_matrix/client/v3/keys/signatures/upload",
                response: .raw(
                    #"{"failures": {"@bob:test": {"DEV": {"errcode": "M_INVALID_SIGNATURE", "error": "bad sig"}}}}"#,
                    status: 200))
            await #expect(throws: MatrixError.serverError(
                code: "M_INVALID_SIGNATURE",
                message: "@bob:test/DEV: bad sig",
                retryAfter: nil))
            {
                try await keys.uploadSignatures(UploadSignaturesRequest())
            }
        }
    }

    @Test("Key calls reject invalid sessions without network", arguments: ["upload", "query", "claim"])
    func keysGuards(_ op: String) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let keys = KeyClient(transport: transport, session: session)
        switch op {
        case "upload":
            await #expect(throws: MatrixError.notAuthenticated) {
                try await keys.uploadDeviceKeys(UploadDeviceKeysRequest())
            }
        case "query":
            await #expect(throws: MatrixError.notAuthenticated) {
                try await keys.queryKeys(users: [UserId(unchecked: "@a:b")])
            }
        default:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await keys.claimKeys(user: UserId(unchecked: "@a:b"))
            }
        }
        try? await transport.shutdown()
    }
}
