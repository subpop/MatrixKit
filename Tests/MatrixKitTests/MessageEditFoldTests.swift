import Foundation
import Testing

@testable import MatrixKit

/// Encodes an `EditContent` exactly as `MessageClient.edit` puts it on the
/// wire: `m.room.message` type carrying `body` + `m.new_content` +
/// `m.relates_to`, and no `msgtype`.
private func editEventContent(target: EventId, newBody: String) throws -> [String: AnyCodable] {
    let edit = EditContent.markdown(editing: target, newBody)
    let data = try JSONEncoder().encode(edit)
    return try JSONDecoder().decode([String: AnyCodable].self, from: data)
}

private func editMessageEvent(
    target: EventId,
    newBody: String,
    sender: UserId = UserId(unchecked: "@alice:x")
) throws -> MessageEvent {
    MessageEvent(
        type: EventType.roomMessage.rawValue,
        eventId: EventId(unchecked: "$edit\(Int.random(in: 1...1_000_000))"),
        sender: sender,
        originServerTs: 1_700_000_000_000,
        content: try editEventContent(target: target, newBody: newBody))
}

@Suite("Message edit folding")
@MainActor
struct MessageEditFoldTests {
    @Test("Edit events are recognized as edits")
    func isEditRecognizesWireShape() throws {
        let event = try editMessageEvent(
            target: EventId(unchecked: "$original:x"), newBody: "fixed")
        #expect(ObservableTimelineEvent.isEdit(event))
    }

    @Test("Edit replacement decodes the new content")
    func editReplacementDecodesNewContent() throws {
        let event = try editMessageEvent(
            target: EventId(unchecked: "$original:x"), newBody: "fixed")
        #expect(ObservableTimelineEvent.editReplacement(in: event)?.body == "fixed")
    }

    @Test("Edit wire shape carries a top-level msgtype")
    func editWireShapeHasMsgtype() throws {
        // Strict servers reject m.room.message events without msgtype.
        let content = try editEventContent(
            target: EventId(unchecked: "$original:x"), newBody: "fixed")
        #expect(content["msgtype"]?.stringValue == "m.text")
        #expect(content["m.new_content"]?["body"]?.stringValue == "fixed")
        #expect(content["m.relates_to"]?["rel_type"]?.stringValue == "m.replace")
    }

    @Test("Plain messages are not edits")
    func plainMessageIsNotEdit() {
        let event = MessageEvent(
            type: EventType.roomMessage.rawValue,
            eventId: EventId(unchecked: "$plain:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1_700_000_000_000,
            content: [
                "msgtype": .string("m.text"),
                "body": .string("hello"),
            ])
        #expect(!ObservableTimelineEvent.isEdit(event))
        #expect(ObservableTimelineEvent.editReplacement(in: event) == nil)
    }
}
