import Foundation
import Testing

@testable import MatrixKit

/// Regression tests for the `%253A` double-encoding bug: segments are
/// encoded exactly once by `pathSegmentEncoded`, and `makeURLString`
/// must concatenate without re-encoding.
@Suite("PathEncoding")
struct PathEncodingTests {
    @Test("Segments encode exactly once", arguments: [
        (RoomId(unchecked: "!abc:matrix.org").pathSegmentEncoded, "!abc%3Amatrix.org"),
        (RoomAlias(unchecked: "#general:matrix.org").pathSegmentEncoded, "%23general%3Amatrix.org"),
        (UserId(unchecked: "@alice:matrix.org").pathSegmentEncoded, "@alice%3Amatrix.org"),
        ("m.room.message".pathSegmentEncoded, "m.room.message"),
    ])
    func segmentEncoding(encoded: String, expected: String) {
        #expect(encoded == expected)
        #expect(!encoded.contains("%25"))
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
