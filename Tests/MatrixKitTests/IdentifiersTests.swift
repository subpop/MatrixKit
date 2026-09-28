import Foundation
import Testing

@testable import MatrixKit

@Suite("Identifiers")
struct IdentifiersTests {
    struct ValidCase: Sendable {
        var id: String
        var input: String
        var expected: String
    }

    @Test("Valid identifiers parse", arguments: [
        ValidCase(id: "user", input: "@alice:example.com", expected: "@alice:example.com"),
        ValidCase(id: "room", input: "!abc:example.com", expected: "!abc:example.com"),
        ValidCase(id: "old event id", input: "$abc:example.com", expected: "$abc:example.com"),
        ValidCase(id: "new event id", input: "$opaque-event-id", expected: "$opaque-event-id"),
        ValidCase(id: "mxc", input: "mxc://example.com/abc123", expected: "mxc://example.com/abc123"),
    ])
    func validIdentifiers(_ c: ValidCase) throws {
        switch c.id {
        case "user":
            let user = try UserId(c.input)
            #expect(user.value == c.expected)
            #expect(user.localpart == "alice")
            #expect(user.serverName == "example.com")
        case "room":
            #expect(try RoomId(c.input).value == c.expected)
        case "mxc":
            let uri = try MXCURI(c.input)
            #expect(uri.value == c.expected)
            #expect(uri.components?.server == "example.com")
            #expect(uri.components?.mediaId == "abc123")
        default:
            #expect(try EventId(c.input).value == c.expected)
        }
    }

    @Test("Invalid identifiers throw", arguments: [
        "alice:example.com", "@alice", "#general:example.com", "https://example.com/x",
        "general:example.com", "#general",
    ])
    func invalidIdentifiers(_ input: String) {
        #expect(throws: MatrixError.self) {
            if input.hasPrefix("#") {
                _ = try RoomId(input)
            } else if input.hasPrefix("mxc") || input.hasPrefix("https") {
                _ = try MXCURI(input)
            } else if input.contains(":") {
                _ = try RoomAlias(input)
            } else {
                _ = try UserId(input)
            }
        }
    }

    @Test("EventId rejects missing sigils")
    func eventIdInvalid() {
        #expect(throws: MatrixError.self) { try EventId("abc") }
    }

    @Test("Identifier Codable round-trips as strings", arguments: [
        "@bob:example.org", "#general:example.com", "$opaque-event-id", "mxc://example.com/abc123",
    ])
    func identifierCodable(_ value: String) throws {
        switch value.first {
        case "@":
            let original = UserId(unchecked: value)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(UserId.self, from: data) == original)
        case "#":
            let original = RoomAlias(unchecked: value)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(RoomAlias.self, from: data) == original)
        case "$":
            let original = EventId(unchecked: value)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(EventId.self, from: data) == original)
        default:
            let original = try MXCURI(value)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(MXCURI.self, from: data) == original)
        }
    }

    @Test("RelatesTo conveniences build relations")
    func relatesTo() {
        let target = EventId(unchecked: "$t:x")
        let reaction = RelatesTo.reaction(to: target, key: "👍")
        #expect(reaction.eventId == target)
        #expect(reaction.relType == .annotation)
    }

    @Test("UserId Codable round-trips as a string")
    func userIdCodable() throws {
        let original = UserId(unchecked: "@bob:example.org")
        let data = try JSONEncoder().encode(original)
        #expect(String(data: data, encoding: .utf8) == "\"@bob:example.org\"")
        #expect(try JSONDecoder().decode(UserId.self, from: data) == original)
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
