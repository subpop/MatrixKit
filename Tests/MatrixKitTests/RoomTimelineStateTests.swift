import Foundation
import Testing

@testable import MatrixKit

private func timelineAvatarEvent(url: String?) -> MessageEvent {
    var content: [String: AnyCodable] = [:]
    if let url { content["url"] = .string(url) }
    return MessageEvent(
        type: "m.room.avatar",
        eventId: EventId(unchecked: "$avatar"),
        sender: UserId(unchecked: "@alice:x"),
        stateKey: "",
        originServerTs: 1,
        content: content)
}

@Suite("Redaction folding")
@MainActor
struct RoomRedactionFoldTests {
    private func reaction(id: String = "$reaction") -> MessageEvent {
        MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: ["m.relates_to": .object([
                "event_id": .string("$target"),
                "rel_type": .string("m.annotation"),
                "key": .string("👍"),
            ])])
    }

    private func redaction(id: String = "$redaction", target: String = "$reaction") -> MessageEvent {
        MessageEvent(
            type: "m.room.redaction",
            eventId: EventId(unchecked: id),
            sender: UserId(unchecked: "@alice:x"),
            redacts: EventId(unchecked: target),
            originServerTs: 2,
            content: [:])
    }

    @Test("applyJoined stamps redacted_because onto the redaction target")
    func foldsRedactionIntoTarget() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [reaction()]))
        #expect(await room.timeline.last?.isRedacted == false)
        await room.applyJoined(JoinedRoomDelta(timeline: [redaction()]))
        let stored = await room.timeline
        #expect(stored.count == 2)
        #expect(stored[0].isRedacted)
        #expect(
            stored[0].unsigned?["redacted_because"]?.objectValue?["event_id"]?.stringValue
                == "$redaction")
    }

    @Test("fold never overwrites a server-supplied redacted_because")
    func preservesServerStamp() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        var stamped = reaction()
        stamped.unsigned = ["redacted_because": .object([
            "event_id": .string("$server"),
        ])]
        await room.applyJoined(JoinedRoomDelta(timeline: [stamped]))
        await room.applyJoined(JoinedRoomDelta(timeline: [redaction()]))
        let stored = await room.timeline
        #expect(
            stored[0].unsigned?["redacted_because"]?.objectValue?["event_id"]?.stringValue
                == "$server")
    }

    @Test("redactions of events outside the window are ignored")
    func ignoresUnknownTargets() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [reaction()]))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [redaction(target: "$elsewhere")]))
        #expect(await room.timeline.first?.isRedacted == false)
    }

    @Test("fold prunes the redaction target's content alongside the stamp")
    func foldPrunesTargetContent() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [reaction()]))
        await room.applyJoined(JoinedRoomDelta(timeline: [redaction()]))
        let stored = await room.timeline
        #expect(stored[0].isRedacted)
        #expect(stored[0].content.isEmpty)
        #expect(stored[0].unsigned?["redacted_because"] != nil)
    }

    @Test("fold prunes message bodies but keeps the stamp")
    func foldPrunesMessageContent() async {
        let message = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$msg"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: [
                "msgtype": .string("m.text"),
                "body": .string("hello"),
                "formatted_body": .string("<b>hello</b>"),
                "format": .string("org.matrix.custom.html"),
            ])
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [message]))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [redaction(target: "$msg")]))
        let stored = await room.timeline
        #expect(stored[0].isRedacted)
        #expect(stored[0].content.isEmpty)
    }

    @Test("fold prunes member content to membership only")
    func foldPrunesMemberContent() async {
        let member = MessageEvent(
            type: "m.room.member",
            eventId: EventId(unchecked: "$member"),
            sender: UserId(unchecked: "@alice:x"),
            stateKey: "@alice:x",
            originServerTs: 1,
            content: [
                "membership": .string("join"),
                "displayname": .string("Alice"),
                "avatar_url": .string("mxc://x/pic"),
            ])
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [member]))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [redaction(target: "$member")]))
        let stored = await room.timeline
        #expect(stored[0].content["membership"]?.stringValue == "join")
        #expect(stored[0].content["displayname"] == nil)
        #expect(stored[0].content["avatar_url"] == nil)
    }

    @Test("suppressed transactions are dropped on confirm")
    func suppressesCancelledEchoConfirm() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let txn = TransactionId("t1")
        await room.stageEcho(
            MessageEvent(
                type: "m.reaction",
                eventId: EventId(unchecked: "local:t1"),
                sender: UserId(unchecked: "@alice:x"),
                originServerTs: 1,
                content: [:],
                unsigned: ["transaction_id": .string("t1")]),
            transactionId: txn)
        #expect(await room.cancelEcho(transactionId: txn))
        await room.suppressTransaction(txn)
        // The in-flight PUT landed; sync delivers it with the same txn.
        let confirmed = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$real"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 2,
            content: [:],
            unsigned: ["transaction_id": .string("t1")])
        await room.applyJoined(JoinedRoomDelta(timeline: [confirmed]))
        #expect(await room.timeline.isEmpty)
    }

    @Test("suppression spares events with other transaction IDs")
    func suppressionIsSelective() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.suppressTransaction(TransactionId("t1"))
        let other = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$other"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 2,
            content: [:],
            unsigned: ["transaction_id": .string("t2")])
        await room.applyJoined(JoinedRoomDelta(timeline: [other]))
        #expect(await room.timeline.map(\.eventId.value) == ["$other"])
    }

    @Test("stampRedaction notifies and restoreUnsigned rolls back")
    func stampAndRestore() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [reaction()]))
        let prior = await room.stampRedaction(
            target: EventId(unchecked: "$reaction"),
            stamp: .object(["event_id": .string("$local")]))
        #expect(prior == nil)
        #expect(await room.timeline.first?.isRedacted == true)
        await room.restoreUnsigned(
            target: EventId(unchecked: "$reaction"), unsigned: prior)
        #expect(await room.timeline.first?.isRedacted == false)
    }
}

private func timelineNameEvent(_ name: String) -> MessageEvent {
    MessageEvent(
        type: "m.room.name",
        eventId: EventId(unchecked: "$name"),
        sender: UserId(unchecked: "@alice:x"),
        stateKey: "",
        originServerTs: 1,
        content: ["name": .string(name)])
}

@Suite("Timeline-embedded state")
@MainActor
struct RoomTimelineStateTests {
    @Test("applyJoined applies avatar state carried only in the timeline")
    func appliesTimelineAvatar() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [timelineAvatarEvent(url: "mxc://x/avatar")]))
        #expect(await room.avatarURL?.value == "mxc://x/avatar")
    }

    @Test("timeline state wins over an older state-block value")
    func timelineWinsOverStateBlock() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(
                timeline: [timelineAvatarEvent(url: "mxc://x/new")],
                state: [timelineAvatarEvent(url: "mxc://x/old")]))
        #expect(await room.avatarURL?.value == "mxc://x/new")
    }

    @Test("timeline avatar applies on a limited window reset")
    func appliesOnLimitedReset() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(
                timeline: [timelineAvatarEvent(url: "mxc://x/new")],
                timelineLimited: true))
        #expect(await room.avatarURL?.value == "mxc://x/new")
    }

    @Test("applyLeft applies timeline-carried state")
    func leftAppliesTimelineState() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyLeft(
            LeftRoomDelta(timeline: [timelineNameEvent("Left Name")]))
        #expect(await room.name == "Left Name")
    }

    @Test("plain timeline messages do not touch room state")
    func messagesDoNotTouchState() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(
            JoinedRoomDelta(timeline: [
                MessageEvent(
                    type: "m.room.message",
                    eventId: EventId(unchecked: "$m"),
                    sender: UserId(unchecked: "@alice:x"),
                    originServerTs: 1,
                    content: ["body": .string("hi")])
            ]))
        #expect(await room.avatarURL == nil)
        #expect(await room.name == nil)
    }

    @Test("adoptAvatarURL publishes a healable avatar")
    func adoptAvatar() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.adoptAvatarURL(try? MXCURI("mxc://x/healed"))
        #expect(await room.avatarURL?.value == "mxc://x/healed")
    }
}

@Suite("Redaction pruning")
struct EventRedactorTests {
    @Test("message and unknown types are emptied")
    func emptiesMessageAndUnknown() {
        #expect(
            EventRedactor.prunedContent(
                type: "m.room.message",
                content: ["body": .string("hi"), "msgtype": .string("m.text")]
            ).isEmpty)
        #expect(
            EventRedactor.prunedContent(
                type: "com.example.custom",
                content: ["secret": .string("x")]
            ).isEmpty)
    }

    @Test("encrypted envelopes keep nothing")
    func emptiesEncrypted() {
        #expect(
            EventRedactor.prunedContent(
                type: "m.room.encrypted",
                content: [
                    "ciphertext": .string("abc"),
                    "session_id": .string("s"),
                ]
            ).isEmpty)
    }

    @Test("member keeps membership and the signed invite block")
    func prunesMember() {
        let pruned = EventRedactor.prunedContent(
            type: "m.room.member",
            content: [
                "membership": .string("invite"),
                "displayname": .string("Alice"),
                "third_party_invite": .object([
                    "display_name": .string("Bob"),
                    "signed": .object(["token": .string("t")]),
                ]),
            ])
        #expect(pruned["membership"]?.stringValue == "invite")
        #expect(pruned["displayname"] == nil)
        #expect(
            pruned["third_party_invite"]?.objectValue?.keys.sorted()
                == ["signed"])
    }

    @Test("create content is preserved")
    func preservesCreate() {
        let content: [String: AnyCodable] = [
            "creator": .string("@alice:x"),
            "room_version": .string("12"),
        ]
        #expect(
            EventRedactor.prunedContent(type: "m.room.create", content: content)
                == content)
    }

    @Test("power levels keep the protocol keys")
    func prunesPowerLevels() {
        let pruned = EventRedactor.prunedContent(
            type: "m.room.power_levels",
            content: [
                "ban": .int(50),
                "invite": .int(0),
                "custom_key": .string("x"),
            ])
        #expect(pruned["ban"]?.intValue == 50)
        #expect(pruned["invite"]?.intValue == 0)
        #expect(pruned["custom_key"] == nil)
    }

    @Test("join rules and history visibility keep their keys")
    func prunesJoinRulesAndVisibility() {
        #expect(
            EventRedactor.prunedContent(
                type: "m.room.join_rules",
                content: [
                    "join_rule": .string("invite"),
                    "allow": .array([]),
                    "extra": .string("x"),
                ]).keys.sorted() == ["allow", "join_rule"])
        #expect(
            EventRedactor.prunedContent(
                type: "m.room.history_visibility",
                content: [
                    "history_visibility": .string("shared"),
                    "extra": .string("x"),
                ]).keys.sorted() == ["history_visibility"])
    }

    @Test("redaction events keep redacts")
    func prunesRedaction() {
        #expect(
            EventRedactor.prunedContent(
                type: "m.room.redaction",
                content: [
                    "redacts": .string("$target"),
                    "reason": .string("spam"),
                ]).keys.sorted() == ["redacts"])
    }
}
