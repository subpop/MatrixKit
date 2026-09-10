import Foundation
import Testing

@testable import MatrixKit

/// Regression tests for the `%253A` double-encoding bug: segments are
/// encoded exactly once by `pathSegmentEncoded`, and `makeURLString`
/// must concatenate without re-encoding.
@Suite("PathEncoding")
struct PathEncodingTests {
    @Test("Room ID encodes the colon exactly once")
    func roomId() {
        let encoded = RoomId(unchecked: "!abc:matrix.org").pathSegmentEncoded
        #expect(encoded == "!abc%3Amatrix.org")
        #expect(!encoded.contains("%25"))
    }

    @Test("Room alias encodes the hash and colon exactly once")
    func roomAlias() {
        let encoded = RoomAlias(unchecked: "#general:matrix.org").pathSegmentEncoded
        #expect(encoded == "%23general%3Amatrix.org")
        #expect(!encoded.contains("%25"))
    }

    @Test("User ID encodes the colon exactly once")
    func userId() {
        let encoded = UserId(unchecked: "@alice:matrix.org").pathSegmentEncoded
        #expect(encoded == "@alice%3Amatrix.org")
    }

    @Test("Send URL keeps single encoding end to end")
    func sendURL() throws {
        let roomId = RoomId(unchecked: "!abc:matrix.org")
        let url = try MatrixTransport.makeURLString(
            base: "https://matrix.org",
            path:
                "/_matrix/client/v3/rooms/\(roomId.pathSegmentEncoded)/send/\("m.room.message".pathSegmentEncoded)/txn1",
            query: nil
        )
        #expect(
            url
                == "https://matrix.org/_matrix/client/v3/rooms/!abc%3Amatrix.org/send/m.room.message/txn1"
        )
    }

    @Test("Query values are encoded without breaking structure")
    func queryEncoding() throws {
        let url = try MatrixTransport.makeURLString(
            base: "https://matrix.org/",
            path: "/_matrix/client/v3/sync",
            query: ["filter": #"{"room":{"timeline":{"limit":10}}}"#, "timeout": "30000"]
        )
        #expect(url.hasPrefix("https://matrix.org/_matrix/client/v3/sync?"))
        #expect(!url.contains("{") && !url.contains("\""))
        #expect(url.contains("timeout=30000"))
    }

    @Test("Strict query set leaves unreserved characters alone")
    func queryUnreserved() {
        #expect("s105_106-abc.~".queryEncoded == "s105_106-abc.~")
    }
}
