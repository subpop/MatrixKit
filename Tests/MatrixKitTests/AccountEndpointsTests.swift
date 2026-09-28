import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Batch A of the missing-endpoints gap: registration, deactivation,
/// single-device get/rename, presence, and user-directory search.
/// Request/response shapes are covered by decode tables below; the
/// auth guard is covered offline (no transport mock exists).
@Suite("AccountEndpoints")
struct AccountEndpointsTests {
    @Test("RegisterRequest encodes registration fields and UIAA auth")
    func registerRequestEncode() throws {
        let request = RegisterRequest(
            username: "alice",
            password: "secret",
            deviceId: DeviceId("DEV"),
            initialDeviceDisplayName: "Phone",
            auth: UIAAuth(type: "m.login.dummy", session: "s1"))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RegisterRequest.self, from: data)
        #expect(decoded.username == "alice")
        #expect(decoded.password == "secret")
        #expect(decoded.deviceId == DeviceId("DEV"))
        #expect(decoded.initialDeviceDisplayName == "Phone")
        #expect(decoded.auth?.type == "m.login.dummy")
        #expect(decoded.auth?.session == "s1")
        // Wire keys use snake_case.
        let raw = try rawShape(String(data: data, encoding: .utf8) ?? "")
        #expect(raw["device_id"]?.stringValue == "DEV")
        #expect(raw["initial_device_display_name"]?.stringValue == "Phone")
        #expect(raw["auth"] != nil)
    }

    struct RegisterResponseCase: Sendable {
        var json: String
        var accessToken: String?
        var deviceId: DeviceId?
        var expiresInMs: Int?
    }

    @Test("RegisterResponse decodes sessions and inhibited logins", arguments: [
        RegisterResponseCase(
            json: #"{"user_id":"@a:b","access_token":"t","device_id":"D","expires_in_ms":1000}"#,
            accessToken: "t", deviceId: DeviceId("D"), expiresInMs: 1000),
        RegisterResponseCase(json: #"{"user_id":"@a:b"}"#, accessToken: nil, deviceId: nil, expiresInMs: nil),
    ])
    func registerResponseDecode(_ c: RegisterResponseCase) throws {
        let response: RegisterResponse = try decodeFixture(c.json)
        #expect(response.userId == UserId(unchecked: "@a:b"))
        #expect(response.accessToken == c.accessToken)
        #expect(response.deviceId == c.deviceId)
        #expect(response.expiresInMs == c.expiresInMs)
    }

    @Test("Deactivate request/response round-trip")
    func deactivateShapes() throws {
        let body = DeactivateAccountRequest(erase: true, auth: UIAAuth(type: "m.login.password"))
        let decoded: DeactivateAccountRequest = try roundTrip(body)
        #expect(decoded.erase == true)
        #expect(decoded.auth?.type == "m.login.password")
        let response: DeactivateAccountResponse = try decodeFixture(#"{"id_server_unbind_result":"success"}"#)
        #expect(response.idServerUnbindResult == "success")
    }

    @Test("RenameDeviceRequest encodes display name and UIAA auth")
    func renameDeviceEncode() throws {
        let data = try JSONEncoder().encode(
            RenameDeviceRequest(displayName: "Laptop", auth: UIAAuth(type: "m.login.dummy")))
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(raw["display_name"]?.stringValue == "Laptop")
        #expect(raw["auth"] != nil)
    }

    @Test("DeviceEntry decodes a single-device body")
    func deviceEntryDecode() throws {
        let entry: DeviceEntry = try decodeFixture(
            #"{"device_id":"D","display_name":"Phone","last_seen_ip":"1.2.3.4","last_seen_ts":1700000000000}"#)
        #expect(entry.deviceId == DeviceId("D"))
        #expect(entry.displayName == "Phone")
        #expect(entry.lastSeenIP == "1.2.3.4")
        #expect(entry.lastSeenTimestampMs == 1_700_000_000_000)
    }

    struct PresenceCase: Sendable {
        var json: String
        var presence: Presence
        var statusMessage: String?
    }

    @Test("UserPresence decodes presence bodies", arguments: [
        PresenceCase(
            json: #"{"presence":"online","last_active_ago":5000,"status_msg":"lunch","currently_active":true}"#,
            presence: .online, statusMessage: "lunch"),
        PresenceCase(json: #"{"presence":"offline"}"#, presence: .offline, statusMessage: nil),
        PresenceCase(json: #"{"presence":"unavailable","status_msg":"busy"}"#, presence: .unavailable, statusMessage: "busy"),
    ])
    func presenceDecode(_ c: PresenceCase) throws {
        let presence: UserPresence = try decodeFixture(c.json)
        #expect(presence.presence == c.presence)
        #expect(presence.statusMessage == c.statusMessage)
    }

    @Test("SetPresenceRequest encodes status_msg")
    func setPresenceEncode() throws {
        let data = try JSONEncoder().encode(
            SetPresenceRequest(presence: .unavailable, statusMessage: "busy"))
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(raw["presence"]?.stringValue == "unavailable")
        #expect(raw["status_msg"]?.stringValue == "busy")
    }

    @Test("UserDirectory request/response round-trip")
    func userDirectoryShapes() throws {
        let requestData = try JSONEncoder().encode(UserDirectoryRequest(searchTerm: "@ali", limit: 10))
        let requestRaw = try JSONDecoder().decode([String: AnyCodable].self, from: requestData)
        #expect(requestRaw["search_term"]?.stringValue == "@ali")
        let response: UserDirectoryResponse = try decodeFixture(
            #"{"results":[{"user_id":"@alice:x","display_name":"Alice"}],"limited":false}"#)
        #expect(response.results.count == 1)
        #expect(response.results[0].userId == UserId(unchecked: "@alice:x"))
        #expect(response.results[0].displayName == "Alice")
        #expect(response.limited == false)
    }

    /// Auth-guarded operations callable with no credentials. Every row
    /// must throw `.notAuthenticated` before any request leaves the SDK.
    enum GuardedCall: String, Sendable, CaseIterable {
        case deactivate
        case device
        case renameDevice
        case presence
        case setPresence
        case searchUsers
    }

    @Test("Account endpoints reject invalid sessions without network", arguments: GuardedCall.allCases)
    func accountRequiresAuth(_ call: GuardedCall) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let auth = AuthClient(transport: transport, session: session)
        let profile = ProfileClient(transport: transport, session: session)
        let userId = UserId(unchecked: "@a:b")
        switch call {
        case .deactivate:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.deactivateAccount() }
        case .device:
            await #expect(throws: MatrixError.notAuthenticated) { try await auth.device(DeviceId("D")) }
        case .renameDevice:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await auth.renameDevice(DeviceId("D"), displayName: "X")
            }
        case .presence:
            await #expect(throws: MatrixError.notAuthenticated) { try await profile.presence(userId) }
        case .setPresence:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await profile.setPresence(userId, presence: .online)
            }
        case .searchUsers:
            await #expect(throws: MatrixError.notAuthenticated) { try await profile.searchUsers(query: "ali") }
        }
        try? await transport.shutdown()
    }
}
