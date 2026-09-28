import Foundation
import Testing

import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixKit

/// Devices, capabilities, to-device, and key-backup compliance.
///
/// Exercised registry endpoints: `GET /devices[/{deviceId}]`,
/// `PUT|DELETE /devices/{deviceId}`, `GET /capabilities`,
/// `PUT /sendToDevice/{eventType}/{txnId}`,
/// `GET|POST /room_keys/version[/{version}]`,
/// `DELETE /room_keys/version/{version}`,
/// `GET|PUT /room_keys/keys[/{roomId}/{sessionId}]`.
@Suite("DeviceCompliance")
struct DeviceComplianceTests {
    @Test("Devices list flags the current session")
    func devices() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient()
            let list = try await auth.devices()
            #expect(list.count == 1)
            #expect(list.first?.deviceId == DeviceId("ALICEDEVICE"))
            #expect(list.first?.displayName == "Test Device")
            #expect(list.first?.isCurrentDevice == true)
            let entry = try await auth.device(DeviceId("ALICEDEVICE"))
            #expect(entry.displayName == "Test Device")
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such device", retryAfter: nil)) {
                try await auth.device(DeviceId("GHOST"))
            }
        }
    }

    @Test("Rename updates, delete removes, ghosts 404")
    func renameDelete() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient()
            try await auth.renameDevice(DeviceId("ALICEDEVICE"), displayName: "Laptop")
            #expect(try await auth.device(DeviceId("ALICEDEVICE")).displayName == "Laptop")
            try await auth.deleteDevice(DeviceId("ALICEDEVICE"))
            #expect(try await auth.devices().isEmpty)
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such device", retryAfter: nil)) {
                try await auth.deleteDevice(DeviceId("ALICEDEVICE"))
            }
        }
    }

    @Test("Capabilities advertise the default room version")
    func capabilities() async throws {
        try await withHarness { harness in
            let (auth, _, _) = await harness.authClient()
            let caps = try await auth.capabilities()
            #expect(caps.defaultRoomVersion == "11")
        }
    }

    @Test("To-device sends record type and transaction")
    func toDevice() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (toDevice, _, _) = await harness.toDeviceClient()
            try await toDevice.send(
                eventType: "m.room_key_request",
                content: ["action": .string("request")],
                to: UserId(unchecked: "@bob:test"),
                devices: ["*"],
                transactionId: "txn1")
            let sends = await world.recordedToDeviceSends()
            #expect(sends.count == 1)
            #expect(sends.first?.type == "m.room_key_request")
            #expect(sends.first?.txn == "txn1")
        }
    }

    @Test("Raw sends fan out per device in one PUT")
    func toDeviceRaw() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (toDevice, _, _) = await harness.toDeviceClient()
            try await toDevice.sendRaw(
                eventType: "m.test",
                messages: ["@bob:test": ["B1": ["k": .string("v")]]],
                transactionId: "txn-raw")
            let sends = await world.recordedToDeviceSends()
            #expect(sends.count == 1)
            #expect(sends.first?.txn == "txn-raw")
            // Encodable content encodes through the generic path.
            struct Ping: Encodable, Sendable {
                var ping: String
            }
            try await toDevice.send(
                eventType: "m.test", content: Ping(ping: "pong"),
                to: UserId(unchecked: "@bob:test"), devices: ["*"])
            #expect(await world.recordedToDeviceSends().count == 2)
        }
    }

    @Test("To-device rejects invalid sessions without network")
    func toDeviceGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let toDevice = ToDeviceClient(transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await toDevice.send(
                eventType: "m.test", content: ["k": .string("v")],
                to: UserId(unchecked: "@b:c"), devices: ["*"])
        }
        try? await transport.shutdown()
    }
}

@Suite("BackupCompliance")
struct BackupComplianceTests {
    @Test("Version lifecycle: absent, create, get, delete")
    func versions() async throws {
        try await withHarness { harness in
            let (backup, _, _) = await harness.backupClient()
            #expect(try await backup.backupInfo() == nil)
            let privateKey = BackupCrypto.generatePrivateKey()
            let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
            let version = try await backup.createBackup(publicKey: publicKey)
            #expect(version == "1")
            let info = try #require(try await backup.backupInfo())
            #expect(info.algorithm == KeyBackup.algorithm)
            try await backup.deleteBackup(version: version)
            #expect(try await backup.backupInfo() == nil)
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such backup", retryAfter: nil)) {
                try await backup.deleteBackup(version: version)
            }
        }
    }

    @Test("Sessions round-trip through backup encryption")
    func sessionRoundTrip() async throws {
        try await withHarness { harness in
            let (backup, _, _) = await harness.backupClient()
            let privateKey = BackupCrypto.generatePrivateKey()
            let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
            let version = try await backup.createBackup(publicKey: publicKey)
            var sender = MegolmSession.create()
            let blob = sender.export()
            let message = try sender.encrypt(Data("room message".utf8))
            let roomId = RoomId(unchecked: "!room:test")
            let sessionId = "sid1"
            try await backup.uploadSessions(
                [(roomId: roomId, sessionId: sessionId, export: blob)],
                publicKey: publicKey, version: version)
            let info = try #require(try await backup.backupInfo())
            #expect(info.count == 1)
            let downloaded = try await backup.downloadSessions(version: version, privateKey: privateKey)
            #expect(downloaded.count == 1)
            #expect(downloaded.first?.0 == roomId)
            #expect(downloaded.first?.1 == sessionId)
            var restored = try MegolmSession.importSessionKey(try #require(downloaded.first?.2))
            #expect(try restored.decrypt(message) == Data("room message".utf8))
            let single = try await backup.downloadSession(
                roomId: roomId, sessionId: sessionId, version: version, privateKey: privateKey)
            #expect(single == blob)
        }
    }

    @Test("Backup calls reject invalid sessions without network")
    func backupGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let backup = KeyBackup(transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await backup.backupInfo()
        }
        try? await transport.shutdown()
    }
}
