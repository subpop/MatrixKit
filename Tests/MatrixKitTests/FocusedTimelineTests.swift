import Foundation
import Testing

import MatrixKitTesting

@testable import MatrixKit

private func contextMessage(id: String, body: String) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: id),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: 1_700_000_000_000,
        content: [
            "msgtype": .string("m.text"),
            "body": .string(body),
        ])
}

@Suite("Event context")
@MainActor
struct EventContextTests {
    @Test("ContextResponse decodes the wire shape")
    func decode() throws {
        let json = """
        {
            "events_before": [
                {"type": "m.room.message", "event_id": "$b:x", "sender": "@a:x",
                 "origin_server_ts": 1, "content": {"msgtype": "m.text", "body": "before"}}
            ],
            "event": {"type": "m.room.message", "event_id": "$f:x", "sender": "@a:x",
                      "origin_server_ts": 2, "content": {"msgtype": "m.text", "body": "focus"}},
            "events_after": [
                {"type": "m.room.message", "event_id": "$a:x", "sender": "@a:x",
                 "origin_server_ts": 3, "content": {"msgtype": "m.text", "body": "after"}}
            ],
            "start": "s1",
            "end": "e1"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ContextResponse.self, from: json)
        #expect(response.eventsBefore.count == 1)
        #expect(response.event?.eventId.value == "$f:x")
        #expect(response.eventsAfter.count == 1)
        #expect(response.start == "s1")
        #expect(response.end == "e1")
    }

    struct WindowCase: Sendable {
        var before: [String]
        var focus: String
        var after: [String]
        var expected: [String]
    }

    nonisolated static let windowCases: [WindowCase] = [
        // Newest-first input orders oldest-first.
        WindowCase(before: ["$newer:x", "$older:x"], focus: "$f:x", after: ["$a:x"],
                   expected: ["$older:x", "$newer:x", "$f:x", "$a:x"]),
        // Repeated segments drop, keeping first occurrence.
        WindowCase(before: ["$f:x", "$older:x"], focus: "$f:x", after: ["$a:x", "$f:x"],
                   expected: ["$older:x", "$f:x", "$a:x"]),
        WindowCase(before: [], focus: "$f:x", after: [],
                   expected: ["$f:x"]),
    ]

    @Test("EventContext orders and dedupes the window", arguments: windowCases)
    func windowing(_ c: WindowCase) {
        let context = EventContext(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: c.focus),
            eventsBefore: c.before.map { contextMessage(id: $0, body: $0) },
            event: contextMessage(id: c.focus, body: c.focus),
            eventsAfter: c.after.map { contextMessage(id: $0, body: $0) })
        #expect(context.events.map(\.eventId.value) == c.expected)
    }
}

@Suite("FocusedTimeline")
@MainActor
struct FocusedTimelineTests {
    private func pager() async -> FakePager {
        let pager = FakePager()
        await pager.setContext(
            before: [contextMessage(id: "$b:x", body: "before")],
            focus: contextMessage(id: "$f:x", body: "focus"),
            after: [contextMessage(id: "$a:x", body: "after")],
            start: "s", end: "e")
        return pager
    }

    @Test("Load builds the window oldest-first with cursors")
    func load() async throws {
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: await pager())
        try await focused.load()
        let events = await focused.events
        #expect(events.map(\.eventId.value) == ["$b:x", "$f:x", "$a:x"])
        #expect(await focused.canPaginateBack())
        #expect(await focused.canPaginateForward())
    }

    @Test("Decryptor transforms loaded windows, flags stay quiet")
    func decryptor() async throws {
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: await pager())
        #expect(await focused.paginationInProgress() == false)
        await focused.setDecryptor { event, _ in
            var mapped = event
            mapped.content["decrypted"] = .bool(true)
            return mapped
        }
        try await focused.load()
        #expect(await focused.paginationInProgress() == false)
        #expect(await focused.events.allSatisfy {
            $0.content["decrypted"] == .bool(true)
        })
    }

    @Test("Backward pages prepend and consume the cursor")
    func paginateBack() async throws {
        let pager = await pager()
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: pager)
        try await focused.load()
        await pager.setPage(PaginationChunk(
            start: "s0", end: nil,
            chunk: [contextMessage(id: "$older:x", body: "older")]))
        let loaded = try await focused.paginateBack()
        #expect(loaded == 1)
        let events = await focused.events
        #expect(events.map(\.eventId.value) == ["$older:x", "$b:x", "$f:x", "$a:x"])
        #expect(!(await focused.canPaginateBack()))
    }

    @Test("Forward pages append and flip the live edge")
    func paginateForward() async throws {
        let pager = await pager()
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: pager)
        try await focused.load()
        await pager.setForwardPage(PaginationChunk(
            start: "e0", end: nil,
            chunk: [contextMessage(id: "$newer:x", body: "newer")]))
        let loaded = try await focused.paginateForward()
        #expect(loaded == 1)
        let events = await focused.events
        #expect(events.map(\.eventId.value) == ["$b:x", "$f:x", "$a:x", "$newer:x"])
        #expect(!(await focused.canPaginateForward()))
    }

    @Test("Backward pages drop events already in the window")
    func paginateBackDedupes() async throws {
        let pager = await pager()
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: pager)
        try await focused.load()
        await pager.setPage(PaginationChunk(
            start: "s0", end: "s1",
            chunk: [
                contextMessage(id: "$older:x", body: "older"),
                contextMessage(id: "$b:x", body: "boundary-echo"),
            ]))
        let loaded = try await focused.paginateBack()
        #expect(loaded == 1)
        let events = await focused.events
        #expect(events.map(\.eventId.value) == ["$older:x", "$b:x", "$f:x", "$a:x"])
    }

    @Test("Backward pages reverse the newest-first page to oldest-first")
    func paginateBackReverses() async throws {
        let pager = await pager()
        let focused = FocusedTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            focusEventId: EventId(unchecked: "$f:x"),
            messages: pager)
        try await focused.load()
        await pager.setPage(PaginationChunk(
            start: "s0", end: "s1",
            chunk: [
                contextMessage(id: "$older2:x", body: "older2"),
                contextMessage(id: "$older1:x", body: "older1"),
            ]))
        let loaded = try await focused.paginateBack()
        #expect(loaded == 2)
        let events = await focused.events
        #expect(events.map(\.eventId.value)
            == ["$older1:x", "$older2:x", "$b:x", "$f:x", "$a:x"])
    }
}
