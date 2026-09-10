import Foundation
import Testing

@testable import MatrixKit

private func stateEvent(
    type: String, sender: String = "@alice:x", stateKey: String = "",
    content: [String: AnyCodable]
) -> MessageEvent {
    MessageEvent(
        type: type,
        eventId: EventId(unchecked: "$s\(Int.random(in: 1...1_000_000)):x"),
        sender: UserId(unchecked: sender),
        stateKey: stateKey,
        originServerTs: 1,
        content: content)
}

@Suite("Room list enrichment")
@MainActor
struct RoomListEnrichmentTests {
    @Test("Parser captures room account data for joined and left rooms")
    func parserAccountData() throws {
        let json = """
        {
            "next_batch": "s1",
            "rooms": {
                "join": {"!r:x": {"account_data": {"events": [
                    {"type": "m.tag", "content": {"tags": {"m.favourite": {}}}}
                ]}}},
                "leave": {"!l:x": {"account_data": {"events": [
                    {"type": "m.tag", "content": {"tags": {}}}
                ]}}}
            }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SyncResponse.self, from: json)
        let delta = SyncResponseParser.parse(response)
        #expect(delta.joined[RoomId(unchecked: "!r:x")]?.accountData.map(\.type) == ["m.tag"])
        #expect(delta.left[RoomId(unchecked: "!l:x")]?.accountData.map(\.type) == ["m.tag"])
    }

    @Test("Room state tracks alias, pins, tombstone, and space type")
    func roomState() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.room.canonical_alias", content: [
                "alias": .string("#room:x"),
                "alt_aliases": .array([.string("#alt:x")]),
            ]),
            stateEvent(type: "m.room.pinned_events", content: [
                "pinned": .array([.string("$p:x")]),
            ]),
            stateEvent(type: "m.room.tombstone", content: [
                "replacement_room": .string("!next:x"),
            ]),
            stateEvent(type: "m.room.create", content: [
                "type": .string("m.space"),
            ]),
        ]))
        #expect(await room.canonicalAlias == "#room:x")
        #expect(await room.altAliases == ["#alt:x"])
        #expect(await room.pinnedEventIds == ["$p:x"])
        #expect(await room.successorRoomId == "!next:x")
        #expect(await room.isSpace)
    }

    @Test("Favourite flag follows room tags")
    func favourite() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let tags = { (favourite: Bool) in
            JoinedRoomDelta(accountData: [
                BasicEvent(type: "m.tag", content: [
                    "tags": .object(favourite ? ["m.favourite": .object([:])] : [:]),
                ]),
            ])
        }
        await room.applyJoined(tags(true))
        #expect(await room.isFavourite)
        await room.applyJoined(tags(false))
        #expect(!(await room.isFavourite))
    }

    @Test("Space graph edges track child/parent state, empty content clears")
    func spaceEdges() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.space.child", stateKey: "!child:x", content: [
                "via": .array([.string("x")]),
            ]),
            stateEvent(type: "m.space.parent", stateKey: "!parent:x", content: [
                "via": .array([.string("x")]),
            ]),
        ]))
        #expect(await room.spaceChildren == [RoomId(unchecked: "!child:x")])
        #expect(await room.spaceParents == [RoomId(unchecked: "!parent:x")])
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.space.child", stateKey: "!child:x", content: [:]),
        ]))
        #expect(await room.spaceChildren.isEmpty)
        #expect(await room.spaceParents == [RoomId(unchecked: "!parent:x")])
    }

    @Test("Canonical parents track the canonical flag")
    func canonicalParents() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.space.parent", stateKey: "!a:x", content: [
                "via": .array([.string("x")]),
                "canonical": .bool(true),
            ]),
            stateEvent(type: "m.space.parent", stateKey: "!z:x", content: [
                "via": .array([.string("x")]),
                "canonical": .bool(true),
            ]),
            stateEvent(type: "m.space.parent", stateKey: "!m:x", content: [
                "via": .array([.string("x")]),
            ]),
        ]))
        #expect(await room.canonicalParentIds == [
            RoomId(unchecked: "!a:x"), RoomId(unchecked: "!z:x")])
        #expect(await room.canonicalParentId == RoomId(unchecked: "!a:x"))
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.space.parent", stateKey: "!z:x", content: [
                "via": .array([.string("x")]),
                "canonical": .bool(false),
            ]),
        ]))
        #expect(await room.canonicalParentIds == [RoomId(unchecked: "!a:x")])
        await room.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.space.parent", stateKey: "!a:x", content: [:]),
        ]))
        #expect(await room.canonicalParentIds.isEmpty)
        #expect(await room.spaceParents == [
            RoomId(unchecked: "!m:x"), RoomId(unchecked: "!z:x")])
    }

    @Test("Invited and knocked spaces are flagged as spaces")
    func strippedSpace() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!s:x"), membership: .invite)
        await room.applyInvite(InvitedRoomDelta(events: [
            StrippedStateEvent(
                type: "m.room.create", stateKey: "",
                sender: UserId(unchecked: "@alice:x"),
                content: ["type": .string("m.space")]),
        ]))
        #expect(await room.isSpace)

        let knock = RoomActor(roomId: RoomId(unchecked: "!k:x"), membership: .knock)
        await knock.applyKnock(KnockedRoomDelta(events: [
            StrippedStateEvent(
                type: "m.room.create", stateKey: "",
                sender: UserId(unchecked: "@alice:x"),
                content: [:]),
        ]))
        #expect(!(await knock.isSpace))
    }

    @Test("Latest message skips non-message events")
    func latestMessage() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.appendLocalEcho(stateEvent(type: "m.room.name", content: [:]))
        await room.appendLocalEcho(MessageEvent(
            type: "m.room.message",
            eventId: EventId(unchecked: "$m:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 2,
            content: ["msgtype": .string("m.text"), "body": .string("hi")]))
        await room.appendLocalEcho(MessageEvent(
            type: "m.reaction",
            eventId: EventId(unchecked: "$e:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 3,
            content: [:]))
        #expect(await room.latestMessageEvent()?.eventId.value == "$m:x")
        #expect(await RoomActor(roomId: RoomId(unchecked: "!e:x")).latestMessageEvent() == nil)
    }

    @Test("Store pushes m.direct into room flags")
    func direct() async {
        let store = StateStore()
        let user = UserId(unchecked: "@alice:x")
        await store.setLocalUser(user)
        let room = await store.room(RoomId(unchecked: "!dm:x"))
        await store.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            accountData: [BasicEvent(type: "m.direct", content: [
                "@alice:x": .array([.string("!dm:x")]),
            ])]))
        #expect(await room.isDirect)
        #expect(await store.directRooms(for: user) == [RoomId(unchecked: "!dm:x")])
        #expect(await store.directRooms(for: UserId(unchecked: "@bob:x")).isEmpty)
    }

    @Test("ObservableRoom isDirect is spec-only: two members without m.direct is not a DM")
    func observableDirectSpecOnly() async {
        let client = await MatrixClient.restore(
            homeserver: URL(string: "https://matrix.example")!,
            userId: UserId(unchecked: "@alice:x"),
            deviceId: DeviceId("ALICE"),
            accessToken: "token")
        let actor = await client.store.room(RoomId(unchecked: "!pair:x"))
        await actor.applyJoined(JoinedRoomDelta(state: [
            stateEvent(type: "m.room.member", sender: "@alice:x", stateKey: "@alice:x", content: [
                "membership": .string("join"),
            ]),
            stateEvent(type: "m.room.member", sender: "@bob:x", stateKey: "@bob:x", content: [
                "membership": .string("join"),
            ]),
        ]))
        let room = await ObservableRoom(
            room: actor, messages: client.messages, rooms: client.rooms,
            roomState: client.roomState, accountData: client.accountData,
            media: client.media, localUser: client.userId)
        #expect(room.members.count == 2)
        #expect(!room.isDirect)

        // The same room becomes direct once m.direct account data lists it.
        await client.store.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            accountData: [BasicEvent(type: "m.direct", content: [
                "@alice:x": .array([.string("!pair:x")]),
            ])]))
        let listed = await ObservableRoom(
            room: actor, messages: client.messages, rooms: client.rooms,
            roomState: client.roomState, accountData: client.accountData,
            media: client.media, localUser: client.userId)
        #expect(listed.isDirect)
        try? await client.transport.shutdown()
    }

    @Test("ObservableRoom mirrors enrichment and invite heroes")
    func observableMirror() async {
        let client = await MatrixClient.restore(
            homeserver: URL(string: "https://matrix.example")!,
            userId: UserId(unchecked: "@alice:x"),
            deviceId: DeviceId("ALICE"),
            accessToken: "token")
        let actor = await client.store.room(RoomId(unchecked: "!r:x"))
        await actor.applyJoined(JoinedRoomDelta(
            state: [stateEvent(type: "m.room.canonical_alias", content: [
                "alias": .string("#room:x"),
            ])],
            accountData: [BasicEvent(type: "m.tag", content: [
                "tags": .object(["m.favourite": .object([:])]),
            ])]))
        let room = await ObservableRoom(
            room: actor, messages: client.messages, rooms: client.rooms,
            roomState: client.roomState, accountData: client.accountData,
            media: client.media, localUser: client.userId)
        #expect(room.canonicalAlias == "#room:x")
        #expect(room.isFavourite)

        let invited = await client.store.room(
            RoomId(unchecked: "!i:x"), membership: .invite)
        await invited.applyInvite(InvitedRoomDelta(events: [
            StrippedStateEvent(
                type: "m.room.member", stateKey: "@alice:x",
                sender: UserId(unchecked: "@bob:x"),
                content: [
                    "membership": .string("invite"),
                    "displayname": .string("Bob"),
                    "avatar_url": .string("mxc://x/bob"),
                ]),
        ]))
        let inviteRoom = await ObservableRoom(
            room: invited, messages: client.messages, rooms: client.rooms,
            roomState: client.roomState, accountData: client.accountData,
            media: client.media, localUser: client.userId)
        #expect(inviteRoom.inviterName == "Bob")
        #expect(inviteRoom.inviterAvatarURL?.value == "mxc://x/bob")
        try? await client.transport.shutdown()
    }
}
