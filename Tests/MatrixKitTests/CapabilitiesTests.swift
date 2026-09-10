import Foundation
import Testing

@testable import MatrixKit

/// `GET /capabilities` decoding: the spec envelope, the six known
/// capabilities, unknown capabilities ignored, missing capabilities
/// defaulting to enabled.
@Suite("Capabilities")
struct CapabilitiesTests {
    private func decode(_ json: String) throws -> ServerCapabilities {
        try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8))
    }

    @Test("Full matrix.org-shaped payload decodes")
    func fullPayload() throws {
        let capabilities = try decode(
            """
            {"capabilities":{
            "m.change_password":{"enabled":true},
            "m.room_versions":{"default":"11","available":{"1":"Stable","11":"Stable"}},
            "m.set_displayname":{"enabled":true},
            "m.set_avatar_url":{"enabled":false},
            "m.3pid_changes":{"enabled":true},
            "m.get_login_token":{"enabled":true},
            "com.example.custom":{"anything":42}
            }}
            """)
        #expect(capabilities.canChangePassword)
        #expect(capabilities.defaultRoomVersion == "11")
        #expect(capabilities.roomVersions?.available["1"] == "Stable")
        #expect(capabilities.canSetDisplayName)
        #expect(!capabilities.canSetAvatarURL)
        #expect(capabilities.canChangeThreePIDs)
        #expect(capabilities.getLoginToken?.enabled == true)
    }

    @Test("Disabled toggles read back as disabled")
    func disabledToggle() throws {
        let capabilities = try decode(
            #"{"capabilities":{"m.change_password":{"enabled":false}}}"#)
        #expect(!capabilities.canChangePassword)
        #expect(capabilities.canSetDisplayName)
    }

    @Test("Missing capabilities default to enabled")
    func missingDefaultsEnabled() throws {
        let capabilities = try decode(#"{"capabilities":{}}"#)
        #expect(capabilities.canChangePassword)
        #expect(capabilities.canSetDisplayName)
        #expect(capabilities.canSetAvatarURL)
        #expect(capabilities.canChangeThreePIDs)
        #expect(capabilities.defaultRoomVersion == nil)
    }

    @Test("Missing envelope means no advertised capabilities")
    func missingEnvelope() throws {
        let capabilities = try decode(#"{}"#)
        #expect(capabilities.canChangePassword)
        #expect(capabilities.roomVersions == nil)
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
