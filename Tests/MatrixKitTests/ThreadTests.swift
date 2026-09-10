import Foundation
import Testing

@testable import MatrixKit

private func threadMessage(id: String, body: String, root: String? = nil) -> MessageEvent {
    var content: [String: AnyCodable] = [
        "msgtype": .string("m.text"),
        "body": .string(body),
    ]
    if let root {
        content["m.relates_to"] = .object([
            "rel_type": .string("m.thread"),
            "event_id": .string(root),
        ])
    }
    return MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: id),
        sender: UserId(unchecked: "@alice:x"),
        originServerTs: 1_700_000_000_000,
        content: content)
}

@Suite("Threads")
@MainActor
struct ThreadTests {
    @Test("Thread relation carries root plus reply fallback")
    func relationShape() {
        let root = EventId(unchecked: "$root:x")
        let parent = EventId(unchecked: "$parent:x")
        let relation = RelatesTo.thread(root: root, replyTo: parent)
        #expect(relation.eventId == root)
        #expect(relation.relType == .thread)
        #expect(relation.inReplyTo?.eventId == parent)

        let content = MessageContent.text("hi", relatesTo: relation)
        #expect(content.threadRootEventId == root)
    }

    @Test("Non-thread content has no thread root")
    func noThreadRoot() {
        #expect(MessageContent.text("hi").threadRootEventId == nil)
        let reply = MessageContent.text(
            "hi", relatesTo: .reply(to: EventId(unchecked: "$p:x")))
        #expect(reply.threadRootEventId == nil)
    }

    @Test("RelationsResponse decodes the wire shape")
    func relationsDecode() throws {
        let json = """
        {
            "chunk": [
                {"type": "m.room.message", "event_id": "$r:x", "sender": "@a:x",
                 "origin_server_ts": 1, "content": {"msgtype": "m.text", "body": "reply"}}
            ],
            "next_batch": "n1"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(RelationsResponse.self, from: json)
        #expect(response.chunk.count == 1)
        #expect(response.nextBatch == "n1")
        #expect(response.prevBatch == nil)
    }

    @Test("ThreadTimeline loads root plus replies oldest-first")
    func load() async throws {
        let pager = FakePager()
        let root = threadMessage(id: "$root:x", body: "root")
        await pager.setEvents([
            EventId(unchecked: "$root:x"): root,
        ])
        await pager.setRelations(
            chunk: [
                threadMessage(id: "$r2:x", body: "second", root: "$root:x"),
                threadMessage(id: "$r1:x", body: "first", root: "$root:x"),
            ],
            nextBatch: "n1")
        let thread = ThreadTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            rootEventId: EventId(unchecked: "$root:x"),
            messages: pager)
        try await thread.load()
        let events = await thread.events()
        #expect(events.map(\.eventId.value) == ["$root:x", "$r1:x", "$r2:x"])
        #expect(await thread.canPaginateBack())
    }

    @Test("ThreadTimeline pages older replies to the front")
    func paging() async throws {
        let pager = FakePager()
        await pager.setEvents([EventId(unchecked: "$root:x"): threadMessage(id: "$root:x", body: "root")])
        await pager.setRelations(
            chunk: [threadMessage(id: "$r1:x", body: "first", root: "$root:x")],
            nextBatch: "n1")
        let thread = ThreadTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            rootEventId: EventId(unchecked: "$root:x"),
            messages: pager)
        try await thread.load()
        await pager.setRelations(
            chunk: [threadMessage(id: "$r0:x", body: "zeroth", root: "$root:x")],
            nextBatch: nil)
        let loaded = try await thread.loadMore()
        #expect(loaded == 1)
        let events = await thread.events()
        #expect(events.map(\.eventId.value) == ["$root:x", "$r0:x", "$r1:x"])
        #expect(!(await thread.canPaginateBack()))
    }

    @Test("Rendered events expose thread roots and bundled counts")
    func renderedFields() {
        let event = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$r:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1_700_000_000_000,
            content: [
                "msgtype": .string("m.text"),
                "body": .string("reply"),
                "m.relates_to": .object([
                    "rel_type": .string("m.thread"),
                    "event_id": .string("$root:x"),
                ]),
            ],
            unsigned: ["m.relations": .object([
                "m.thread": .object([
                    "count": .int(3),
                    "current_user_participated": .bool(true),
                ])])])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.threadRootEventId == EventId(unchecked: "$root:x"))
        #expect(wrapper.threadReplyCount == 3)
        #expect(wrapper.threadParticipated)
    }

    @Test("ObservableTimeline loads a thread and returns to live")
    func threadFlow() async throws {

        let roomId = RoomId(unchecked: "!r:x")
        let rootId = EventId(unchecked: "$root:x")
        let room = RoomActor(roomId: roomId)
        await room.appendLocalEcho(threadMessage(id: "$live:x", body: "live"))
        let pager = FakePager()
        await pager.setEvents([rootId: threadMessage(id: "$root:x", body: "root")])
        await pager.setRelations(
            chunk: [threadMessage(id: "$r1:x", body: "reply", root: "$root:x")],
            nextBatch: nil)
        let timeline = await ObservableTimeline(
            timeline: Timeline(roomId: roomId, messages: pager, room: room),
            room: room,
            messages: pager,
            localUser: UserId(unchecked: "@alice:x"))
        #expect(timeline.timelineFocus == .live)

        try await timeline.loadThread(rootEventId: rootId)
        #expect(timeline.timelineFocus == .thread(rootId))
        #expect(timeline.events.map(\.eventId.value) == ["$root:x", "$r1:x"])
        #expect(timeline.events[1].threadRootEventId == rootId)

        await timeline.returnToLive()
        #expect(timeline.timelineFocus == .live)
        #expect(timeline.events.map(\.eventId.value) == ["$live:x"])
    }

    @Test("Root falls back to context without single-event fetch")
    func rootFallback() async throws {
        let pager = FakePager()
        await pager.setEventError(.serverError(
            code: "M_UNRECOGNIZED", message: "Unrecognized request", retryAfter: nil))
        await pager.setContext(
            before: [], focus: threadMessage(id: "$root:x", body: "root"),
            after: [], start: nil, end: nil)
        await pager.setRelations(chunk: [], nextBatch: nil)
        let thread = ThreadTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            rootEventId: EventId(unchecked: "$root:x"),
            messages: pager)
        try await thread.load()
        #expect(await thread.events().map(\.eventId.value) == ["$root:x"])
    }

    @Test("Replies fall back to the live window without relations")
    func relationsFallback() async throws {
        let pager = FakePager()
        await pager.setEvents([EventId(unchecked: "$root:x"): threadMessage(id: "$root:x", body: "root")])
        await pager.setRelationsError(.serverError(
            code: "M_UNRECOGNIZED", message: "Unrecognized request", retryAfter: nil))
        let thread = ThreadTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            rootEventId: EventId(unchecked: "$root:x"),
            messages: pager)
        try await thread.load(localEvents: [
            threadMessage(id: "$other:x", body: "unrelated"),
            threadMessage(id: "$r1:x", body: "reply", root: "$root:x"),
        ])
        #expect(await thread.events().map(\.eventId.value) == ["$root:x", "$r1:x"])
        #expect(!(await thread.canPaginateBack()))
    }

    @Test("Non-recognition errors other than M_UNRECOGNIZED propagate")
    func otherErrorsPropagate() async throws {
        let pager = FakePager()
        await pager.setEvents([EventId(unchecked: "$root:x"): threadMessage(id: "$root:x", body: "root")])
        await pager.setRelationsError(.serverError(
            code: "M_FORBIDDEN", message: "Denied", retryAfter: nil))
        let thread = ThreadTimeline(
            roomId: RoomId(unchecked: "!r:x"),
            rootEventId: EventId(unchecked: "$root:x"),
            messages: pager)
        await #expect(throws: MatrixError.self) {
            try await thread.load(localEvents: [])
        }
    }
}
