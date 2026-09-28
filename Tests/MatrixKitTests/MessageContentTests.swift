import Foundation
import Testing

@testable import MatrixKit

@Suite("MessageContent")
struct MessageContentTests {
    @Test("Text and HTML factories set msgtype and bodies")
    func factories() {
        let text = MessageContent.text("hello")
        #expect(text.msgtype == .text)
        #expect(text.body == "hello")
        #expect(text.formattedBody == nil)

        let html = MessageContent.html("hi", formattedBody: "<b>hi</b>")
        #expect(html.format == "org.matrix.custom.html")
        #expect(html.formattedBody == "<b>hi</b>")
    }

    struct RelationCase: Sendable {
        var id: String
        var content: any Encodable & Sendable
        var check: @Sendable ([String: AnyCodable]) -> Bool
    }

    static func relationCases(eventId: EventId) -> [RelationCase] {
        [
            RelationCase(
                id: "reply",
                content: MessageContent.text("yo", relatesTo: .reply(to: eventId)),
                check: { $0["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.stringValue == eventId.value }),
            RelationCase(
                id: "reaction",
                content: ReactionContent.reaction(to: eventId, key: "👍"),
                check: {
                    $0["m.relates_to"]?["rel_type"]?.stringValue == "m.annotation"
                        && $0["m.relates_to"]?["key"]?.stringValue == "👍"
                }),
            RelationCase(
                id: "edit",
                content: EditContent(body: " * new", newContent: .text("new"), relatesTo: .edit(of: eventId)),
                check: {
                    $0["m.new_content"]?["body"]?.stringValue == "new"
                        && $0["m.relates_to"]?["rel_type"]?.stringValue == "m.replace"
                }),
        ]
    }

    @Test("RelatesTo encodes relation shapes", arguments: relationCases(eventId: EventId(unchecked: "$x:example.com")))
    func relatesTo(_ c: RelationCase) throws {
        let data = try JSONEncoder().encode(c.content)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(c.check(json))
    }

    @Test("MessageEvent timestamp converts millis to Date")
    func timestamp() {
        let event = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$e"),
            sender: UserId(unchecked: "@a:b"),
            originServerTs: 1_700_000_000_000,
            content: [:]
        )
        #expect(event.timestamp.timeIntervalSince1970 == 1_700_000_000)
    }
}
