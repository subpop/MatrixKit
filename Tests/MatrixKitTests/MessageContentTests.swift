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

    @Test("RelatesTo encodes reply, edit, and reaction shapes")
    func relatesTo() throws {
        let eventId = EventId(unchecked: "$x:example.com")
        let reply = MessageContent.text("yo", relatesTo: .reply(to: eventId))
        let data = try JSONEncoder().encode(reply)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(json["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.stringValue == "$x:example.com")

        let reaction = ReactionContent.reaction(to: eventId, key: "👍")
        let reactionData = try JSONEncoder().encode(reaction)
        let reactionJson = try JSONDecoder().decode([String: AnyCodable].self, from: reactionData)
        #expect(
            reactionJson["m.relates_to"]?["rel_type"]?.stringValue == "m.annotation")
        #expect(reactionJson["m.relates_to"]?["key"]?.stringValue == "👍")

        let edit = EditContent(
            body: " * new", newContent: .text("new"), relatesTo: .edit(of: eventId))
        let editData = try JSONEncoder().encode(edit)
        let editJson = try JSONDecoder().decode([String: AnyCodable].self, from: editData)
        #expect(editJson["m.new_content"]?["body"]?.stringValue == "new")
        #expect(editJson["m.relates_to"]?["rel_type"]?.stringValue == "m.replace")
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
