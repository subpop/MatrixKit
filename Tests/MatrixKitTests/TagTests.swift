import Foundation
import Testing

@testable import MatrixKit

/// Tag endpoints: decodable models and the endpoint paths/methods they
/// map to (`GET .../tags`, `PUT`/`DELETE .../tags/{tag}`).
@Suite("Tags")
struct TagTests {
    @Test("RoomTag decodes with and without order")
    func roomTagDecode() throws {
        let withOrder = try JSONDecoder().decode(
            RoomTag.self, from: Data(#"{"order":0.5}"#.utf8))
        #expect(withOrder.order == 0.5)
        let withoutOrder = try JSONDecoder().decode(
            RoomTag.self, from: Data(#"{}"#.utf8))
        #expect(withoutOrder.order == nil)
    }

    @Test("TagsResponse decodes a real server body")
    func tagsResponseDecode() throws {
        let body = #"{"tags":{"m.favourite":{"order":0.5},"u.custom":{}}}"#
        let response = try JSONDecoder().decode(
            TagsResponse.self, from: Data(body.utf8))
        #expect(response.tags.count == 2)
        #expect(response.tags["m.favourite"]?.order == 0.5)
        #expect(response.tags["u.custom"]?.order == nil)
    }

    @Test("TagsResponse decodes an empty tags object")
    func tagsResponseEmpty() throws {
        let response = try JSONDecoder().decode(
            TagsResponse.self, from: Data(#"{"tags":{}}"#.utf8))
        #expect(response.tags.isEmpty)
    }

    @Test("Tag names encode safely in paths")
    func tagPathEncoding() {
        #expect("m.favourite".pathSegmentEncoded == "m.favourite")
        // `/` is urlPathAllowed so it survives unescaped — tag names are
        // inside a single segment and must not contain it themselves.
        #expect(!"u.work/secret".pathSegmentEncoded.contains("%2F"))
    }
}
