import Foundation
import Testing

@testable import MatrixKit

@Suite("Key backup wire models")
struct KeyBackupTests {
    @Test("Backup version info decodes")
    func versionInfo() throws {
        let json = """
        {"version": "7", "algorithm": "m.megolm_backup.v1.curve25519-aes-sha2",
         "auth_data": {"public_key": "XjhWTCjW7l59pbfx9tlCBQolfnIQWARoKOzjTOPSlWM"},
         "count": 12, "etag": "e1"}
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(BackupVersionInfo.self, from: json)
        #expect(info.version == "7")
        #expect(info.algorithm == KeyBackup.algorithm)
        #expect(info.authData?["public_key"]?.stringValue == "XjhWTCjW7l59pbfx9tlCBQolfnIQWARoKOzjTOPSlWM")
        #expect(info.count == 12)
    }

    @Test("Backup session data decodes")
    func sessionData() throws {
        let json = """
        {"first_message_index": 0, "forwarded_count": 0, "is_verified": false,
         "session_data": {"ephemeral": "e", "ciphertext": "c", "mac": "m"}}
        """.data(using: .utf8)!
        let data = try JSONDecoder().decode(BackupSessionData.self, from: json)
        #expect(data.firstMessageIndex == 0)
        #expect(!data.isVerified)
        #expect(data.sessionData.ephemeral == "e")
    }

    @Test("Room keys payload decodes through the sessions wrapper")
    func roomKeysPayload() throws {
        // Shape of a live GET /room_keys/keys response: rooms map to a
        // {"sessions": {...}} wrapper, not directly to session entries.
        struct Response: Decodable {
            var rooms: [String: BackupRoomSessions]
        }
        let json = """
        {"rooms": {
         "!a:matrix.org": {"sessions": {
           "sid1": {"first_message_index": 0, "forwarded_count": 0,
                    "is_verified": false,
                    "session_data": {"ephemeral": "e", "ciphertext": "c", "mac": "m"}},
           "sid2": {"first_message_index": 3, "forwarded_count": 1,
                    "is_verified": true,
                    "session_data": {"ephemeral": "e", "ciphertext": "c", "mac": "m"}}}},
         "!b:matrix.org": {"sessions": {}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(Response.self, from: json)
        #expect(response.rooms.count == 2)
        #expect(response.rooms["!a:matrix.org"]?.sessions.count == 2)
        #expect(
            response.rooms["!a:matrix.org"]?.sessions["sid2"]?.firstMessageIndex == 3)
        #expect(response.rooms["!b:matrix.org"]?.sessions.isEmpty == true)
    }
}
