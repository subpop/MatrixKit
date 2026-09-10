import Foundation
import Testing

@testable import MatrixKit

private func messageEvent(
    type: String = "m.room.message",
    sender: UserId = UserId(unchecked: "@alice:x"),
    stateKey: String? = nil,
    content: [String: AnyCodable] = [:],
    unsigned: [String: AnyCodable]? = nil
) -> MessageEvent {
    MessageEvent(
        type: type,
        eventId: EventId(unchecked: "$e\(Int.random(in: 1...1_000_000))"),
        sender: sender,
        stateKey: stateKey,
        originServerTs: 1_700_000_000_000,
        content: content,
        unsigned: unsigned)
}

private func textContent(_ body: String, formattedBody: String? = nil) -> [String: AnyCodable] {
    var dict: [String: AnyCodable] = [
        "msgtype": .string("m.text"),
        "body": .string(body),
    ]
    if let formattedBody {
        dict["formatted_body"] = .string(formattedBody)
        dict["format"] = .string("org.matrix.custom.html")
    }
    return dict
}

private func membersFixture() -> [UserId: MemberContent] {
    [
        UserId(unchecked: "@alice:x"): MemberContent(
            membership: .join, displayname: "Alice",
            avatarUrl: "mxc://x/alice"),
        UserId(unchecked: "@bob:x"): MemberContent(
            membership: .join, displayname: "Bob"),
    ]
}

@Suite("ObservableTimelineEvent classification")
@MainActor
struct ObservableTimelineEventTests {
    @Test("Sender display name and avatar resolve from members")
    func senderResolution() {
        let event = messageEvent(content: textContent("hi"))
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        #expect(wrapper.senderDisplayName == "Alice")
        #expect(wrapper.senderAvatarURL?.value == "mxc://x/alice")
    }

    @Test("Unknown senders resolve to nil display fields")
    func unknownSender() {
        let event = messageEvent(
            sender: UserId(unchecked: "@mallory:x"), content: textContent("hi"))
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        #expect(wrapper.senderDisplayName == nil)
        #expect(wrapper.senderAvatarURL == nil)
    }

    @Test("Formatted body passes through")
    func formattedBody() {
        let event = messageEvent(content: textContent("hi", formattedBody: "<b>hi</b>"))
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.formattedBody == "<b>hi</b>")
        if case .text(let body) = wrapper.kind {
            #expect(body == "hi")
        } else {
            Issue.record("Expected .text")
        }
    }

    @Test("Sticker classifies with body, URL, and info")
    func sticker() {
        let event = messageEvent(
            type: "m.sticker",
            content: [
                "body": .string("party"),
                "url": .string("mxc://x/sticker"),
                "info": .object([
                    "mimetype": .string("image/png"),
                    "w": .int(128),
                    "h": .int(128),
                ]),
            ])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        if case .sticker(let body, let url, let info) = wrapper.kind {
            #expect(body == "party")
            #expect(url == "mxc://x/sticker")
            #expect(info?.mimeType == "image/png")
            #expect(info?.width == 128)
        } else {
            Issue.record("Expected .sticker, got \(wrapper.kind)")
        }
    }

    @Test("Poll start classifies with the question")
    func poll() {
        let event = messageEvent(
            type: "m.poll.start",
            content: ["question": .object([
                "org.matrix.msc1767.text": .string("Lunch?")])])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .poll(question: "Lunch?"))
    }

    @Test("Poll start understands the unstable prefix")
    func pollUnstable() {
        let event = messageEvent(
            type: "org.matrix.msc3381.poll.start",
            content: ["question": .object([
                "org.matrix.msc1767.text": .string("Dinner?")])])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .poll(question: "Dinner?"))
    }

    @Test("Location with a beacon reference is live")
    func liveLocation() {
        let live = messageEvent(content: [
            "msgtype": .string("m.location"),
            "body": .string("sharing"),
            "m.relates_to": .object([
                "rel_type": .string("m.reference"),
                "event_id": .string("$beacon:x"),
            ]),
        ])
        let liveWrapper = ObservableTimelineEvent.make(from: live, localUser: nil)
        #expect(liveWrapper.kind == .liveLocation(body: "sharing"))

        let still = messageEvent(content: [
            "msgtype": .string("m.location"),
            "body": .string("here"),
        ])
        let stillWrapper = ObservableTimelineEvent.make(from: still, localUser: nil)
        #expect(stillWrapper.kind == .location(body: "here"))
    }

    @Test("Membership events use display names")
    func membership() {
        let invite = messageEvent(
            type: "m.room.member",
            stateKey: "@bob:x",
            content: ["membership": .string("invite")])
        let wrapper = ObservableTimelineEvent.make(
            from: invite, localUser: nil, members: membersFixture())
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Alice invited Bob"))
    }

    @Test("Display-name change classifies as a profile change")
    func profileChange() {
        let event = messageEvent(
            type: "m.room.member",
            stateKey: "@alice:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Alicia"),
            ],
            unsigned: ["prev_content": .object([
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ])])
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        if case .profileChange(let description) = wrapper.kind {
            #expect(description.contains("Alicia"))
        } else {
            Issue.record("Expected .profileChange, got \(wrapper.kind)")
        }
    }

    @Test("Membership join without a profile change stays a state event")
    func plainJoin() {
        let event = messageEvent(
            type: "m.room.member",
            stateKey: "@alice:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ],
            unsigned: ["prev_content": .object([
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ])])
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Alice joined"))
    }

    @Test("Invite exposes the invitee as membership target")
    func inviteTarget() {
        let invite = messageEvent(
            type: "m.room.member",
            stateKey: "@bob:x",
            content: ["membership": .string("invite")])
        let wrapper = ObservableTimelineEvent.make(
            from: invite, localUser: nil, members: membersFixture())
        #expect(wrapper.targetUserId == UserId(unchecked: "@bob:x"))
        #expect(wrapper.targetDisplayName == "Bob")
    }

    @Test("Kick exposes the removed user as membership target")
    func kickTarget() {
        let kick = messageEvent(
            type: "m.room.member",
            stateKey: "@bob:x",
            content: ["membership": .string("leave")])
        let wrapper = ObservableTimelineEvent.make(
            from: kick, localUser: nil, members: membersFixture())
        #expect(wrapper.targetUserId == UserId(unchecked: "@bob:x"))
        #expect(wrapper.targetDisplayName == "Bob")
    }

    @Test("Self join has no membership target")
    func selfJoinHasNoTarget() {
        let event = messageEvent(
            type: "m.room.member",
            stateKey: "@alice:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ],
            unsigned: ["prev_content": .object([
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ])])
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        #expect(wrapper.targetUserId == nil)
        #expect(wrapper.targetDisplayName == nil)
    }

    @Test("Non-membership state has no membership target")
    func nonMembershipHasNoTarget() {
        let event = messageEvent(
            type: "m.room.name",
            content: ["name": .string("New name")])
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        #expect(wrapper.targetUserId == nil)
        #expect(wrapper.targetDisplayName == nil)
    }

    @Test("Call invite and hangup classify; negotiation noise does not")
    func callEvents() {
        let invite = messageEvent(type: "m.call.invite", content: [:])
        let inviteWrapper = ObservableTimelineEvent.make(
            from: invite, localUser: nil, members: membersFixture())
        if case .callEvent(let type, let description) = inviteWrapper.kind {
            #expect(type == "m.call.invite")
            #expect(description == "Alice started a call")
        } else {
            Issue.record("Expected .callEvent, got \(inviteWrapper.kind)")
        }

        let candidates = messageEvent(type: "m.call.candidates", content: [:])
        let noise = ObservableTimelineEvent.make(from: candidates, localUser: nil)
        #expect(noise.kind == .unknown(type: "m.call.candidates"))
    }

    @Test("Undecryptable ciphertext classifies as unable to decrypt")
    func undecryptableCiphertext() {
        let event = messageEvent(
            type: "m.room.encrypted",
            content: [
                "algorithm": .string("m.megolm.v1.aes-sha2"),
                "sender_key": .string("opaque"),
            ])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .unableToDecrypt)
    }

    @Test("Call member state classifies")
    func callMember() {
        let event = messageEvent(
            type: "org.matrix.msc3401.call.member", content: [:])
        let wrapper = ObservableTimelineEvent.make(
            from: event, localUser: nil, members: membersFixture())
        if case .callEvent(let type, _) = wrapper.kind {
            #expect(type == "org.matrix.msc3401.call.member")
        } else {
            Issue.record("Expected .callEvent, got \(wrapper.kind)")
        }
    }

    @Test("Server ACL classifies as a state event with friendly text")
    func serverACL() {
        let event = messageEvent(type: "m.room.server_acl", content: [:])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .state(
            type: "m.room.server_acl",
            description: "Server access control was updated"))
    }

    @Test("Room state events use friendly descriptions")
    func roomStateDescriptions() {
        let cases: [(String, String)] = [
            ("m.room.create", "The room was created"),
            ("m.room.avatar", "Room avatar was updated"),
            ("m.room.power_levels", "Room permissions were updated"),
            ("m.room.encryption", "Encryption was enabled"),
            ("m.room.tombstone", "The room was upgraded"),
            ("m.room.canonical_alias", "Room address was updated"),
            ("m.room.pinned_events", "Pinned messages were updated"),
            ("m.room.join_rules", "Join rules were updated"),
            ("m.room.history_visibility", "History visibility was updated"),
        ]
        for (type, description) in cases {
            let event = messageEvent(type: type, content: [:])
            let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
            #expect(
                wrapper.kind == .state(type: type, description: description),
                "Unexpected description for \(type)")
        }
    }

    @Test("Mentions parse user IDs and the room flag")
    func mentions() {
        let event = messageEvent(content: [
            "msgtype": .string("m.text"),
            "body": .string("hi @bob"),
            "m.mentions": .object([
                "user_ids": .array([.string("@bob:x")]),
                "room": .bool(false),
            ]),
        ])
        #expect(ObservableTimelineEvent.mentions(in: event) == [UserId(unchecked: "@bob:x")])
        #expect(ObservableTimelineEvent.mentionsRoom(in: event) == false)
    }
}

@Suite("ObservableTimeline highlights and reactions")
@MainActor
struct ObservableTimelineHighlightTests {
    private func timeline(
        events: [MessageEvent], localUser: UserId? = UserId(unchecked: "@alice:x")
    ) async -> ObservableTimeline {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        for event in events {
            await room.appendLocalEcho(event)
        }
        return await ObservableTimeline(
            timeline: Timeline(roomId: RoomId(unchecked: "!r:x"), messages: FakePager(), room: room),
            room: room,
            messages: FakePager(),
            localUser: localUser)
    }

    @Test("Self-mention highlights with the local user flagged")
    func selfMention() async {
        let event = messageEvent(content: [
            "msgtype": .string("m.text"),
            "body": .string("hi alice"),
            "m.mentions": .object(["user_ids": .array([.string("@alice:x")])]),
        ])
        let timeline = await timeline(events: [event])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].isHighlighted)
        #expect(timeline.events[0].highlightedMentionUserId == UserId(unchecked: "@alice:x"))
    }

    @Test("Keyword match highlights and records the keyword")
    func keyword() async {
        let event = messageEvent(content: textContent("deploy the thing"))
        let timeline = await timeline(events: [event])
        timeline.highlightKeywords = ["deploy"]
        await timeline.refresh()
        #expect(timeline.events[0].isHighlighted)
        #expect(timeline.events[0].highlightKeywords == ["deploy"])
    }

    @Test("Plain message is not highlighted")
    func plain() async {
        let event = messageEvent(content: textContent("just chatting"))
        let timeline = await timeline(events: [event])
        #expect(!timeline.events[0].isHighlighted)
    }

    @Test("Own reactions are flagged on the target")
    func ownReactions() async {
        let target = EventId(unchecked: "$target:x")
        let message = MessageEvent(
            type: "m.room.message",
            eventId: target,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hi"))
        let reaction = messageEvent(
            type: "m.reaction",
            sender: UserId(unchecked: "@alice:x"),
            content: ["m.relates_to": .object([
                "event_id": .string("$target:x"),
                "rel_type": .string("m.annotation"),
                "key": .string("👍"),
            ])])
        let timeline = await timeline(events: [message, reaction])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].reactions["👍"] == [UserId(unchecked: "@alice:x")])
        #expect(timeline.events[0].ownReactions == ["👍"])
    }

    @Test("Staged echo reactions aggregate immediately")
    func stagedEchoReactionAggregates() async {
        let target = EventId(unchecked: "$target:x")
        let message = MessageEvent(
            type: "m.room.message",
            eventId: target,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hi"))
        let echo = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "local:t1"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1_700_000_000_001,
            content: ["m.relates_to": .object([
                "event_id": .string("$target:x"),
                "rel_type": .string("m.annotation"),
                "key": .string("🎉"),
            ])],
            unsigned: ["transaction_id": .string("t1")])
        let timeline = await timeline(events: [message, echo])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].reactions["🎉"] == [UserId(unchecked: "@alice:x")])
        #expect(timeline.events[0].ownReactions == ["🎉"])
    }

    @Test("Redacted reactions are excluded from aggregation")
    func redactedReactionsExcluded() async {
        let target = EventId(unchecked: "$target:x")
        let message = MessageEvent(
            type: "m.room.message",
            eventId: target,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hi"))
        let reaction = MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$reaction:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1_700_000_000_001,
            content: ["m.relates_to": .object([
                "event_id": .string("$target:x"),
                "rel_type": .string("m.annotation"),
                "key": .string("👍"),
            ])],
            unsigned: ["redacted_because": .object([
                "event_id": .string("$redaction:x"),
            ])])
        let timeline = await timeline(events: [message, reaction])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].reactions.isEmpty)
        #expect(timeline.events[0].ownReactions.isEmpty)
    }

    @Test("Redaction events do not render as deleted bubbles")
    func redactionEventsHidden() async {
        let target = EventId(unchecked: "$target:x")
        let message = MessageEvent(
            type: "m.room.message",
            eventId: target,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hi"))
        let redaction = MessageEvent(
            type: "m.room.redaction",
            eventId: EventId(unchecked: "$redaction:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1_700_000_000_001,
            content: [:],
            unsigned: ["transaction_id": .string("txn1")])
        var redactionWithTarget = redaction
        redactionWithTarget.redacts = EventId(unchecked: "$reaction:x")
        let timeline = await timeline(events: [message, redactionWithTarget])
        #expect(timeline.events.count == 1)
        if case .text = timeline.events[0].kind {
        } else {
            Issue.record("Expected the plain message, got \(timeline.events[0].kind)")
        }
    }

    @Test("Redacted messages still render a tombstone")
    func redactedMessageTombstone() async {
        let message = MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$target:x"),
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hi"),
            unsigned: ["redacted_because": .object([
                "event_id": .string("$redaction:x"),
            ])])
        let timeline = await timeline(events: [message])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].isRedacted)
        if case .redacted = timeline.events[0].kind {
        } else {
            Issue.record("Expected .redacted, got \(timeline.events[0].kind)")
        }
    }

    @Test("Edit folds into its target and marks it edited")
    func editFolding() async {
        let target = EventId(unchecked: "$target:x")
        let message = MessageEvent(
            type: "m.room.message",
            eventId: target,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("hello"))
        let edit = messageEvent(
            type: "m.room.message",
            sender: UserId(unchecked: "@bob:x"),
            content: [
                "msgtype": .string("m.text"),
                "body": .string(" * hello world"),
                "m.new_content": .object([
                    "msgtype": .string("m.text"),
                    "body": .string("hello world"),
                ]),
                "m.relates_to": .object([
                    "rel_type": .string("m.replace"),
                    "event_id": .string("$target:x"),
                ]),
            ])
        let timeline = await timeline(events: [message, edit])
        #expect(timeline.events.count == 1)
        if case .text(let body) = timeline.events[0].kind {
            #expect(body == "hello world")
        } else {
            Issue.record("Expected folded .text, got \(timeline.events[0].kind)")
        }
        #expect(timeline.events[0].isEdited)
    }

    @Test("Reply resolves its parent with sender name")
    func replyResolution() async {
        let parentId = EventId(unchecked: "$parent:x")
        let parent = MessageEvent(
            type: "m.room.message",
            eventId: parentId,
            sender: UserId(unchecked: "@bob:x"),
            originServerTs: 1_700_000_000_000,
            content: textContent("parent body"))
        let reply = messageEvent(content: [
            "msgtype": .string("m.text"),
            "body": .string("reply body"),
            "m.relates_to": .object([
                "m.in_reply_to": .object(["event_id": .string("$parent:x")])]),
        ])
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.appendLocalEcho(parent)
        await room.appendLocalEcho(reply)
        let timeline = await ObservableTimeline(
            timeline: Timeline(
                roomId: RoomId(unchecked: "!r:x"), messages: FakePager(), room: room),
            room: room,
            messages: FakePager(),
            localUser: UserId(unchecked: "@alice:x"))
        let rendered = timeline.events.first { $0.reply != nil }
        #expect(rendered?.reply?.body == "parent body")
        #expect(rendered?.reply?.eventID == parentId)
        #expect(rendered?.reply?.displayName == "@bob:x")
    }

    @Test("Reply to an unknown event resolves to nil")
    func replyUnknown() async {
        let reply = messageEvent(content: [
            "msgtype": .string("m.text"),
            "body": .string("reply body"),
            "m.relates_to": .object([
                "m.in_reply_to": .object(["event_id": .string("$missing:x")])]),
        ])
        let timeline = await timeline(events: [reply])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].reply == nil)
    }
}

@Suite("Join and profile-change coalescing")
@MainActor
struct JoinCoalescingTests {
    private var nextId = 0

    private mutating func memberEvent(
        user: String, membership: String, displayName: String? = nil,
        avatarUrl: String? = nil, prevMembership: String? = nil,
        prevDisplayName: String? = nil
    ) -> MessageEvent {
        nextId += 1
        var content: [String: AnyCodable] = ["membership": .string(membership)]
        if let displayName {
            content["displayname"] = .string(displayName)
        }
        if let avatarUrl {
            content["avatar_url"] = .string(avatarUrl)
        }
        var unsigned: [String: AnyCodable]? = nil
        if let prevMembership {
            var prev: [String: AnyCodable] = ["membership": .string(prevMembership)]
            if let prevDisplayName {
                prev["displayname"] = .string(prevDisplayName)
            }
            unsigned = ["prev_content": .object(prev)]
        }
        return MessageEvent(
            type: "m.room.member",
            eventId: EventId(unchecked: "$join\(nextId):x"),
            sender: UserId(unchecked: user),
            stateKey: user,
            originServerTs: 1_700_000_000_000 + nextId,
            content: content,
            unsigned: unsigned)
    }

    private mutating func textEvent(user: String, body: String) -> MessageEvent {
        nextId += 1
        return MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$msg\(nextId):x"),
            sender: UserId(unchecked: user),
            originServerTs: 1_700_000_000_000 + nextId,
            content: [
                "msgtype": .string("m.text"),
                "body": .string(body),
            ])
    }

    private func timeline(events: [MessageEvent]) async -> ObservableTimeline {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        for event in events {
            await room.appendLocalEcho(event)
        }
        return await ObservableTimeline(
            timeline: Timeline(roomId: RoomId(unchecked: "!r:x"), messages: FakePager(), room: room),
            room: room,
            messages: FakePager(),
            localUser: nil)
    }

    @Test("Initial join carrying a profile renders as a join, not a profile change")
    func initialJoinWithProfile() {
        let event = messageEvent(
            type: "m.room.member",
            sender: UserId(unchecked: "@cresh:x"),
            stateKey: "@cresh:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Cresh"),
            ])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Cresh joined"))
        #expect(wrapper.senderDisplayName == "Cresh")
    }

    @Test("Invite target resolves from event content when state is unknown")
    func inviteTargetFromContent() {
        let event = messageEvent(
            type: "m.room.member",
            sender: UserId(unchecked: "@alice:x"),
            stateKey: "@bob:x",
            content: [
                "membership": .string("invite"),
                "displayname": .string("Bob"),
            ])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "@alice:x invited Bob"))
        #expect(wrapper.targetDisplayName == "Bob")
        // The invite content describes the target, never the sender.
        #expect(wrapper.senderDisplayName == nil)
    }

    @Test("Rejoin after a leave renders as a join even when it sets a profile")
    func rejoinWithProfile() {
        let event = messageEvent(
            type: "m.room.member",
            sender: UserId(unchecked: "@cresh:x"),
            stateKey: "@cresh:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Cresh"),
            ],
            unsigned: ["prev_content": .object([
                "membership": .string("leave"),
            ])])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Cresh joined"))
    }

    @Test("Genuine rename on a join-to-join transition stays a profile change")
    func genuineRename() {
        let event = messageEvent(
            type: "m.room.member",
            sender: UserId(unchecked: "@alice:x"),
            stateKey: "@alice:x",
            content: [
                "membership": .string("join"),
                "displayname": .string("Alicia"),
            ],
            unsigned: ["prev_content": .object([
                "membership": .string("join"),
                "displayname": .string("Alice"),
            ])])
        let wrapper = ObservableTimelineEvent.make(from: event, localUser: nil)
        if case .profileChange = wrapper.kind {
        } else {
            Issue.record("Expected .profileChange, got \(wrapper.kind)")
        }
    }

    @Test("Join followed by an immediate profile set coalesces into one join row")
    func joinThenProfileSet() async {
        var harness = self
        let join = harness.memberEvent(user: "@cresh:x", membership: "join")
        let profile = harness.memberEvent(
            user: "@cresh:x", membership: "join", displayName: "Cresh",
            prevMembership: "join")
        let timeline = await harness.timeline(events: [join, profile])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].kind == .state(
            type: "m.room.member", description: "@cresh:x joined"))
    }

    @Test("Messages from others between join and profile set do not break coalescing")
    func interleavedMessages() async {
        var harness = self
        let join = harness.memberEvent(user: "@cresh:x", membership: "join")
        let chat = harness.textEvent(user: "@alice:x", body: "welcome!")
        let profile = harness.memberEvent(
            user: "@cresh:x", membership: "join", displayName: "Cresh",
            prevMembership: "join")
        let timeline = await harness.timeline(events: [join, chat, profile])
        #expect(timeline.events.count == 2)
        #expect(timeline.events[0].kind == .state(
            type: "m.room.member", description: "@cresh:x joined"))
    }

    @Test("Profile change after the user speaks stays visible")
    func renameAfterActivity() async {
        var harness = self
        let join = harness.memberEvent(user: "@alice:x", membership: "join")
        let chat = harness.textEvent(user: "@alice:x", body: "hello")
        let rename = harness.memberEvent(
            user: "@alice:x", membership: "join", displayName: "Alicia",
            prevMembership: "join", prevDisplayName: "Alice")
        let timeline = await harness.timeline(events: [join, chat, rename])
        #expect(timeline.events.count == 3)
        if case .profileChange = timeline.events[2].kind {
        } else {
            Issue.record("Expected .profileChange, got \(timeline.events[2].kind)")
        }
    }

    @Test("Profile changes from other users are never folded into a join")
    func otherUserUnaffected() async {
        var harness = self
        let join = harness.memberEvent(user: "@cresh:x", membership: "join")
        let rename = harness.memberEvent(
            user: "@alice:x", membership: "join", displayName: "Alicia",
            prevMembership: "join", prevDisplayName: "Alice")
        let timeline = await harness.timeline(events: [join, rename])
        #expect(timeline.events.count == 2)
    }

    @Test("Leave ends the fresh-join window")
    func leaveEndsWindow() async {
        var harness = self
        let join = harness.memberEvent(user: "@cresh:x", membership: "join")
        let leave = harness.memberEvent(
            user: "@cresh:x", membership: "leave", prevMembership: "join")
        let timeline = await harness.timeline(events: [join, leave])
        #expect(timeline.events.count == 2)
    }

    @Test("Profile-less leave resolves the name from pre-transition content")
    func leaveFromPrevContent() {
        var harness = self
        let leave = harness.memberEvent(
            user: "@cresh:x", membership: "leave",
            prevMembership: "join", prevDisplayName: "Cresh")
        let wrapper = ObservableTimelineEvent.make(from: leave, localUser: nil)
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Cresh left"))
        #expect(wrapper.senderDisplayName == "Cresh")
    }

    @Test("Profile-less leave keeps the stored display name after sync state")
    func leaveKeepsStoredProfile() async {
        var harness = self
        let join = harness.memberEvent(
            user: "@cresh:x", membership: "join", displayName: "Cresh")
        let leave = harness.memberEvent(user: "@cresh:x", membership: "leave")
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(timeline: [join, leave]))
        let members = await room.members
        #expect(members[UserId(unchecked: "@cresh:x")]?.displayname == "Cresh")
        let wrapper = ObservableTimelineEvent.make(
            from: leave, localUser: nil, members: members)
        #expect(wrapper.kind == .state(
            type: "m.room.member", description: "Cresh left"))
        #expect(wrapper.senderDisplayName == "Cresh")
    }
}
