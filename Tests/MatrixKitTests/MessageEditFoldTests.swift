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
    enum EventKind: Sendable {
        case edit
        case plain
    }

    struct FoldCase: Sendable {
        var kind: EventKind
        var isEdit: Bool
        var replacementBody: String?
    }

    @Test("Edits recognized, plain messages not", arguments: [
        FoldCase(kind: .edit, isEdit: true, replacementBody: "fixed"),
        FoldCase(kind: .plain, isEdit: false, replacementBody: nil),
    ])
    func fold(_ c: FoldCase) throws {
        let event: MessageEvent
        switch c.kind {
        case .edit:
            event = try editMessageEvent(
                target: EventId(unchecked: "$original:x"), newBody: "fixed")
        case .plain:
            event = MessageEvent(
                type: EventType.roomMessage.rawValue,
                eventId: EventId(unchecked: "$plain:x"),
                sender: UserId(unchecked: "@alice:x"),
                originServerTs: 1_700_000_000_000,
                content: [
                    "msgtype": .string("m.text"),
                    "body": .string("hello"),
                ])
        }
        #expect(ObservableTimelineEvent.isEdit(event) == c.isEdit)
        #expect(ObservableTimelineEvent.editReplacement(in: event)?.body == c.replacementBody)
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
}
