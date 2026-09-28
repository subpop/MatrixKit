import Foundation
import Testing

@testable import MatrixKit

/// `GET /capabilities` decoding: the spec envelope, the six known
/// capabilities, unknown capabilities ignored, missing capabilities
/// defaulting to enabled.
@Suite("Capabilities")
struct CapabilitiesTests {
    struct DefaultsCase: Sendable {
        var id: String
        var json: String
        var canChangePassword: Bool
        var canSetDisplayName: Bool
        var canSetAvatarURL: Bool
        var canChangeThreePIDs: Bool
        var defaultRoomVersion: String?
    }

    static let defaultsCases: [DefaultsCase] = [
        DefaultsCase(
            id: "full payload",
            json: """
                {"capabilities":{
                "m.change_password":{"enabled":true},
                "m.room_versions":{"default":"11","available":{"1":"Stable","11":"Stable"}},
                "m.set_displayname":{"enabled":true},
                "m.set_avatar_url":{"enabled":false},
                "m.3pid_changes":{"enabled":true},
                "m.get_login_token":{"enabled":true},
                "com.example.custom":{"anything":42}
                }}
                """,
            canChangePassword: true, canSetDisplayName: true,
            canSetAvatarURL: false, canChangeThreePIDs: true,
            defaultRoomVersion: "11"),
        DefaultsCase(
            id: "disabled toggle",
            json: #"{"capabilities":{"m.change_password":{"enabled":false}}}"#,
            canChangePassword: false, canSetDisplayName: true,
            canSetAvatarURL: true, canChangeThreePIDs: true,
            defaultRoomVersion: nil),
        DefaultsCase(
            id: "empty capabilities",
            json: #"{"capabilities":{}}"#,
            canChangePassword: true, canSetDisplayName: true,
            canSetAvatarURL: true, canChangeThreePIDs: true,
            defaultRoomVersion: nil),
        DefaultsCase(
            id: "missing envelope",
            json: #"{}"#,
            canChangePassword: true, canSetDisplayName: true,
            canSetAvatarURL: true, canChangeThreePIDs: true,
            defaultRoomVersion: nil),
    ]

    @Test("Capability defaults and toggles", arguments: defaultsCases)
    func capabilityDefaults(_ c: DefaultsCase) throws {
        let capabilities = try JSONDecoder().decode(
            ServerCapabilities.self, from: Data(c.json.utf8))
        #expect(capabilities.canChangePassword == c.canChangePassword)
        #expect(capabilities.canSetDisplayName == c.canSetDisplayName)
        #expect(capabilities.canSetAvatarURL == c.canSetAvatarURL)
        #expect(capabilities.canChangeThreePIDs == c.canChangeThreePIDs)
        #expect(capabilities.defaultRoomVersion == c.defaultRoomVersion)
    }

    @Test("Full payload keeps room versions and login-token flag")
    func fullPayload() throws {
        let capabilities = try JSONDecoder().decode(
            ServerCapabilities.self, from: Data(Self.defaultsCases[0].json.utf8))
        #expect(capabilities.roomVersions?.available["1"] == "Stable")
        #expect(capabilities.getLoginToken?.enabled == true)
    }

    @Test("Round-trips through Codable")
    func roundTrip() throws {
        let original = ServerCapabilities(
            roomVersions: RoomVersionsCapability(
                default: "11", available: ["11": "Stable"]),
            setAvatarURL: BoolCapability(enabled: false))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerCapabilities.self, from: data)
        #expect(decoded == original)
    }
}
