import Foundation
import Testing

@testable import MatrixKit

/// Batch A of the missing-endpoints gap: registration, deactivation,
/// single-device get/rename, presence, and user-directory search.
/// Request/response shapes are covered by encode/decode tests; the
/// auth guard is covered offline (no transport mock exists).
@Suite("AccountEndpoints")
struct AccountEndpointsTests {
    private func makeUnauthenticated() -> (auth: AuthClient, profile: ProfileClient, transport: MatrixTransport) {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        return (
            AuthClient(transport: transport, session: session),
            ProfileClient(transport: transport, session: session),
            transport)
    }

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
        let raw = try JSONDecoder().decode(
            [String: AnyCodable].self, from: data)
        #expect(raw["device_id"]?.stringValue == "DEV")
        #expect(raw["initial_device_display_name"]?.stringValue == "Phone")
        #expect(raw["auth"] != nil)
    }

    @Test("RegisterResponse decodes a session and an inhibited token")
    func registerResponseDecode() throws {
        let session = try JSONDecoder().decode(
            RegisterResponse.self,
            from: Data(
                #"{"user_id":"@a:b","access_token":"t","device_id":"D","expires_in_ms":1000}"#.utf8
            ))
        #expect(session.userId == UserId(unchecked: "@a:b"))
        #expect(session.accessToken == "t")
        #expect(session.deviceId == DeviceId("D"))
        #expect(session.expiresInMs == 1000)
        let inhibited = try JSONDecoder().decode(
            RegisterResponse.self, from: Data(#"{"user_id":"@a:b"}"#.utf8))
        #expect(inhibited.accessToken == nil)
        #expect(inhibited.deviceId == nil)
    }

    @Test("RegisterAvailable decodes availability")
    func registerAvailableDecode() throws {
        let response = try JSONDecoder().decode(
            RegisterAvailable.self, from: Data(#"{"available":true}"#.utf8))
        #expect(response.available)
    }

    @Test("Deactivate request/response round-trip")
    func deactivateShapes() throws {
        let body = DeactivateAccountRequest(erase: true, auth: UIAAuth(type: "m.login.password"))
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(DeactivateAccountRequest.self, from: data)
        #expect(decoded.erase == true)
        #expect(decoded.auth?.type == "m.login.password")
        let response = try JSONDecoder().decode(
            DeactivateAccountResponse.self,
            from: Data(#"{"id_server_unbind_result":"success"}"#.utf8))
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
        let entry = try JSONDecoder().decode(
            DeviceEntry.self,
            from: Data(
                #"{"device_id":"D","display_name":"Phone","last_seen_ip":"1.2.3.4","last_seen_ts":1700000000000}"#
                    .utf8))
        #expect(entry.deviceId == DeviceId("D"))
        #expect(entry.displayName == "Phone")
        #expect(entry.lastSeenIP == "1.2.3.4")
        #expect(entry.lastSeenTimestampMs == 1_700_000_000_000)
    }

    @Test("UserPresence decodes a presence body")
    func presenceDecode() throws {
        let presence = try JSONDecoder().decode(
            UserPresence.self,
            from: Data(
                #"{"presence":"online","last_active_ago":5000,"status_msg":"lunch","currently_active":true}"#
                    .utf8))
        #expect(presence.presence == .online)
        #expect(presence.lastActiveAgo == 5000)
        #expect(presence.statusMessage == "lunch")
        #expect(presence.currentlyActive == true)
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
        let request = UserDirectoryRequest(searchTerm: "@ali", limit: 10)
        let requestData = try JSONEncoder().encode(request)
        let requestRaw = try JSONDecoder().decode(
            [String: AnyCodable].self, from: requestData)
        #expect(requestRaw["search_term"]?.stringValue == "@ali")
        let response = try JSONDecoder().decode(
            UserDirectoryResponse.self,
            from: Data(
                #"{"results":[{"user_id":"@alice:x","display_name":"Alice"}],"limited":false}"#.utf8
            ))
        #expect(response.results.count == 1)
        #expect(response.results[0].userId == UserId(unchecked: "@alice:x"))
        #expect(response.results[0].displayName == "Alice")
        #expect(response.limited == false)
    }

    @Test("Account endpoints reject invalid sessions without network")
    func accountRequiresAuth() async {
        let (auth, profile, transport) = makeUnauthenticated()
        let userId = UserId(unchecked: "@a:b")
        await #expect(throws: MatrixError.notAuthenticated) {
            try await auth.deactivateAccount()
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await auth.device(DeviceId("D"))
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await auth.renameDevice(DeviceId("D"), displayName: "X")
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await profile.presence(userId)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await profile.setPresence(userId, presence: .online)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await profile.searchUsers(query: "ali")
        }
        try? await transport.shutdown()
    }
}
