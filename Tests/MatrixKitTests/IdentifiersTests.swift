import Foundation
import Testing

@testable import MatrixKit

@Suite("Identifiers")
struct IdentifiersTests {
    @Test("UserId validates sigil and server part")
    func userIdValidation() throws {
        let user = try UserId("@alice:example.com")
        #expect(user.localpart == "alice")
        #expect(user.serverName == "example.com")
        #expect(user.description == "@alice:example.com")
        #expect(throws: MatrixError.self) { try UserId("alice:example.com") }
        #expect(throws: MatrixError.self) { try UserId("@alice") }
    }

    @Test("UserId Codable round-trips as a string")
    func userIdCodable() throws {
        let original = UserId(unchecked: "@bob:example.org")
        let data = try JSONEncoder().encode(original)
        #expect(String(data: data, encoding: .utf8) == "\"@bob:example.org\"")
        #expect(try JSONDecoder().decode(UserId.self, from: data) == original)
    }

    @Test("RoomId validates sigil")
    func roomIdValidation() throws {
        #expect(try RoomId("!abc:example.com").value == "!abc:example.com")
        #expect(throws: MatrixError.self) { try RoomId("#general:example.com") }
    }

    @Test("EventId accepts old and new formats")
    func eventIdFormats() throws {
        #expect(try EventId("$abc:example.com").value == "$abc:example.com")
        #expect(try EventId("$opaque-event-id").value == "$opaque-event-id")
        #expect(throws: MatrixError.self) { try EventId("abc") }
    }

    @Test("MXCURI splits server and media ID")
    func mxcComponents() throws {
        let uri = try MXCURI("mxc://example.com/abc123")
        #expect(uri.components?.server == "example.com")
        #expect(uri.components?.mediaId == "abc123")
        #expect(try MXCURI("mxc://example.com/abc123").value == "mxc://example.com/abc123")
        #expect(throws: MatrixError.self) { try MXCURI("https://example.com/x") }
    }

    @Test("TransactionId.random is unique")
    func transactionIdUnique() {
        #expect(TransactionId.random() != TransactionId.random())
    }

    @Test("DeviceId and BatchToken support string literals")
    func stringLiterals() {
        let device: DeviceId = "MYDEVICE"
        #expect(device.value == "MYDEVICE")
        let token: BatchToken = "s123_456"
        #expect(token.value == "s123_456")
    }
}
