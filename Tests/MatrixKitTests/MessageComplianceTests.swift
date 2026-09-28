import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Message compliance suite: send variants, redaction, pagination,
/// single-event fetch, context windows, and relation indexes.
///
/// Exercised registry endpoints: `PUT /rooms/{roomId}/send/{eventType}/{txnId}`,
/// `PUT /rooms/{roomId}/redact/{eventId}/{txnId}`,
/// `GET /rooms/{roomId}/{messages,event/{eventId},context/{eventId}}`,
/// `GET /v1/rooms/{roomId}/relations/{eventId}/{relType}[/{eventType}]`.
@Suite("MessageCompliance")
struct MessageComplianceTests {
    enum SendVariant: Sendable {
        case text
        case html
        case reply
        case thread
        case edit
        case react
    }

    @Test("Send variants reach the wire with event IDs", arguments: [
        SendVariant.text, .html, .reply, .thread, .edit, .react,
    ])
    func sendVariants(_ variant: SendVariant) async throws {
        try await withHarness { harness in
            let world = await harness.world
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = await world.stageMessage(roomId: room.value, body: "target")
            let id: EventId
            switch variant {
            case .text:
                id = try await messages.sendText(room, "hello")
            case .html:
                id = try await messages.sendHTML(room, body: "hi", formattedBody: "<b>hi</b>")
            case .reply:
                id = try await messages.reply(room, to: target.eventId, body: "reply")
            case .thread:
                id = try await messages.threadReply(room, root: target.eventId, body: "thread")
            case .edit:
                id = try await messages.edit(room, eventId: target.eventId, newBody: "fixed")
            case .react:
                id = try await messages.react(room, to: target.eventId, key: "👍")
            }
            #expect(id.value.hasPrefix("$w"))
            // The sent event is retrievable and paginable.
            let fetched = try await messages.event(room, id)
            #expect(fetched.eventId == id)
            let sends = await harness.requests.filter { $0.method == "PUT" && $0.path.contains("/send/") }
            #expect(sends.count == 1)
            #expect(sends.first?.hadBearer == true)
        }
    }

    @Test("Redact prunes content, unknown events 404")
    func redact() async throws {
        try await withHarness { harness in
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let id = try await messages.sendText(room, "doomed")
            let redactionId = try await messages.redact(room, eventId: id, reason: "spam")
            #expect(redactionId.value.hasPrefix("$w"))
            let pruned = try await messages.event(room, id)
            #expect(pruned.content.isEmpty)
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such event", retryAfter: nil)) {
                try await messages.redact(room, eventId: EventId(unchecked: "$ghost:test"))
            }
        }
    }

    @Test("Pagination walks newest-first with cursors")
    func paginate() async throws {
        try await withHarness { harness in
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            for body in ["one", "two", "three"] {
                _ = try await messages.sendText(room, body)
            }
            let first = try await messages.paginate(room, from: nil, limit: 2)
            #expect(first.chunk.count == 2)
            #expect(first.chunk.map(\.eventId.value) == ["$w3:test", "$w2:test"])
            let cursor = try #require(first.end)
            let second = try await messages.paginate(room, from: BatchToken(cursor), limit: 2)
            #expect(second.chunk.map(\.eventId.value) == ["$w1:test"])
            #expect(second.end == nil)
        }
    }

    @Test("Context splits before/focus/after")
    func context() async throws {
        try await withHarness { harness in
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            _ = try await messages.sendText(room, "before")
            let focus = try await messages.sendText(room, "focus")
            _ = try await messages.sendText(room, "after")
            let window = try await messages.context(room, eventId: focus)
            #expect(window.eventsBefore.map(\.eventId.value) == ["$w1:test"])
            #expect(window.focusEventId == focus)
            #expect(window.event?.eventId == focus)
            #expect(window.eventsAfter.map(\.eventId.value) == ["$w3:test"])
            #expect(window.events.map(\.eventId.value) == ["$w1:test", focus.value, "$w3:test"])
        }
    }

    @Test("Reactions and thread replies index under relations")
    func relations() async throws {
        try await withHarness { harness in
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "target")
            _ = try await messages.react(room, to: target, key: "👍")
            _ = try await messages.threadReply(room, root: target, body: "threaded")
            let annotations = try await messages.relations(room, eventId: target, relType: "m.annotation")
            #expect(annotations.chunk.count == 1)
            let threads = try await messages.relations(room, eventId: target, relType: "m.thread")
            #expect(threads.chunk.count == 1)
            let missing = try await messages.relations(room, eventId: target, relType: "m.replace")
            #expect(missing.chunk.isEmpty)
        }
    }

    @Test("Message calls reject invalid sessions without network", arguments: [true, false])
    func messageGuards(sending: Bool) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let messages = MessageClient(transport: transport, session: session)
        let roomId = RoomId(unchecked: "!r:example.com")
        if sending {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await messages.sendText(roomId, "hi")
            }
        } else {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await messages.paginate(roomId, from: nil)
            }
        }
        try? await transport.shutdown()
    }
}
