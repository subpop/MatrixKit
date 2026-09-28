import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Tag endpoints: decodable models and the endpoint paths/methods they
/// map to (`GET .../tags`, `PUT`/`DELETE .../tags/{tag}`).
@Suite("Tags")
struct TagTests {
    struct DecodeCase<T: Sendable>: Sendable {
        var id: String
        var json: String
        var check: @Sendable (T) -> Bool
    }

    @Test("RoomTag decodes with and without order", arguments: [
        DecodeCase<RoomTag>(id: "with order", json: #"{"order":0.5}"#, check: { $0.order == 0.5 }),
        DecodeCase<RoomTag>(id: "without order", json: #"{}"#, check: { $0.order == nil }),
    ])
    func roomTagDecode(_ c: DecodeCase<RoomTag>) throws {
        #expect(c.check(try decodeFixture(c.json)))
    }

    @Test("TagsResponse decodes server bodies", arguments: [
        DecodeCase<TagsResponse>(
            id: "mixed tags",
            json: #"{"tags":{"m.favourite":{"order":0.5},"u.custom":{}}}"#,
            check: { $0.tags.count == 2 && $0.tags["m.favourite"]?.order == 0.5 && $0.tags["u.custom"]?.order == nil }),
        DecodeCase<TagsResponse>(
            id: "empty tags",
            json: #"{"tags":{}}"#,
            check: { $0.tags.isEmpty }),
    ])
    func tagsResponseDecode(_ c: DecodeCase<TagsResponse>) throws {
        #expect(c.check(try decodeFixture(c.json)))
    }

    @Test("Tag names encode safely in paths", arguments: [
        ("m.favourite", "m.favourite"),
        ("u.custom+1", "u.custom+1"),
        // `/` encodes: tag names sit inside a single segment and must
        // not smuggle extra segments (see `matrixPathSegmentAllowed`).
        ("u.work/secret", "u.work%2Fsecret"),
    ])
    func tagPathEncoding(tag: String, expected: String) {
        #expect(tag.pathSegmentEncoded == expected)
        #expect(!tag.pathSegmentEncoded.contains("%25"))
    }
}
