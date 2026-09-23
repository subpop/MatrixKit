import Foundation
import Testing

@testable import MatrixKit
@testable import MatrixKitCrypto

private func echoEvent(
    id: String, txn: String, body: String = "hi",
    sender: UserId = UserId(unchecked: "@alice:x")
) -> MessageEvent {
    MessageEvent(
        type: "m.room.message",
        eventId: EventId(unchecked: id),
        sender: sender,
        originServerTs: 1_700_000_000_000,
        content: [
            "msgtype": .string("m.text"),
            "body": .string(body),
        ],
        unsigned: ["transaction_id": .string(txn)])
}

@Suite("Send pipeline")
@MainActor
struct SendPipelineTests {
    @Test("Mentions encode as m.mentions")
    func mentionsShape() throws {
        let content = MessageContent.text(
            "hi",
            mentions: Mentions(
                userIds: [UserId(unchecked: "@bob:x")], room: true))
        let data = try JSONEncoder().encode(content)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(json["m.mentions"]?["user_ids"]?.arrayValue?.first?.stringValue == "@bob:x")
        #expect(json["m.mentions"]?["room"]?.boolValue == true)
    }

    @Test("Staged echo is pending in the timeline")
    func stage() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.stageEcho(
            echoEvent(id: "local:t1", txn: "t1"), transactionId: TransactionId("t1"))
        #expect(await room.timeline.map(\.eventId.value) == ["local:t1"])
        #expect(await room.sendStates[EventId(unchecked: "local:t1")] == .pending)
    }

    @Test("Sync confirm replaces the echo with the server event")
    func confirm() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.stageEcho(
            echoEvent(id: "local:t1", txn: "t1"), transactionId: TransactionId("t1"))
        let confirmed = echoEvent(id: "$real:x", txn: "t1")
        await room.applyJoined(JoinedRoomDelta(timeline: [confirmed]))
        #expect(await room.timeline.map(\.eventId.value) == ["$real:x"])
        #expect(await room.sendStates.isEmpty)
    }

    @Test("Failed echo stays visible with its reason")
    func fail() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.stageEcho(
            echoEvent(id: "local:t1", txn: "t1"), transactionId: TransactionId("t1"))
        await room.failEcho(transactionId: TransactionId("t1"), reason: "offline")
        #expect(await room.timeline.map(\.eventId.value) == ["local:t1"])
        #expect(await room.sendStates[EventId(unchecked: "local:t1")] == .failed("offline"))
    }

    @Test("Cancelled echo is dropped")
    func cancel() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.stageEcho(
            echoEvent(id: "local:t1", txn: "t1"), transactionId: TransactionId("t1"))
        #expect(await room.cancelEcho(transactionId: TransactionId("t1")))
        #expect(await room.timeline.isEmpty)
        #expect(await room.sendStates.isEmpty)
        #expect(!(await room.cancelEcho(transactionId: TransactionId("t1"))))
    }

    @Test("Encryption state tracks m.room.encryption")
    func encryption() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        #expect(!(await room.isEncrypted))
        let state = MessageEvent(
            type: "m.room.encryption",
            eventId: EventId(unchecked: "$s:x"),
            sender: UserId(unchecked: "@alice:x"),
            originServerTs: 1,
            content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
        await room.applyJoined(JoinedRoomDelta(state: [state]))
        #expect(await room.isEncrypted)
    }

    @Test("Rendered echo carries its send state")
    func renderedSendState() async {
        let roomId = RoomId(unchecked: "!r:x")
        let room = RoomActor(roomId: roomId)
        await room.stageEcho(
            echoEvent(id: "local:t1", txn: "t1"), transactionId: TransactionId("t1"))
        let pager = FakePager()
        let timeline = await ObservableTimeline(
            timeline: Timeline(roomId: roomId, messages: pager, room: room),
            room: room,
            messages: pager,
            localUser: UserId(unchecked: "@alice:x"))
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].sendState == .pending)
    }

    @Test("Encrypted send carries mentions through decrypt")
    func encryptedMentions() async throws {        let room = RoomId(unchecked: "!r:x")
        let sender = FakeRoomSender()
        let alice = RoomCrypto(sharer: FakeSharer(), sender: sender)
        _ = try await alice.sendEncryptedContent(room, MessageContent.markdown("hi", mentions: Mentions(userIds: [UserId(unchecked: "@bob:x")])))
        let sent = await sender.sent
        #expect(sent.count == 1)
        let wire = MessageEvent(
            type: sent[0].type,
            eventId: EventId(unchecked: "$e:x"),
            sender: UserId(unchecked: "@alice:x"),
            roomId: room,
            originServerTs: 1,
            content: sent[0].content)
        let decrypted = await alice.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.content["body"] == .string("hi"))
        #expect(decrypted?.content["formatted_body"] == .string("<p>hi</p>"))
        #expect(
            decrypted?.content["m.mentions"]?["user_ids"]?.arrayValue?.first?.stringValue
                == "@bob:x")
    }

    @Test("Encrypted send uses the staged echo transaction ID")
    func encryptedTxnPassthrough() async throws {
        let room = RoomId(unchecked: "!r:x")
        let sender = FakeRoomSender()
        let alice = RoomCrypto(sharer: FakeSharer(), sender: sender)
        _ = try await alice.sendEncryptedContent(
            room, MessageContent.markdown("hi"),
            transactionId: TransactionId("staged-txn"))
        let sent = await sender.sent
        #expect(sent.count == 1)
        // The staged echo's txn must reach the wire, or sync can never
        // confirm the echo and the message renders twice.
        #expect(sent[0].txn == "staged-txn")
    }

    @Test("Encrypted reply carries m.relates_to through decrypt")
    func encryptedReply() async throws {
        let room = RoomId(unchecked: "!r:x")
        let sender = FakeRoomSender()
        let alice = RoomCrypto(sharer: FakeSharer(), sender: sender)
        let target = EventId(unchecked: "$target:x")
        _ = try await alice.sendEncryptedContent(
            room,
            MessageContent.markdown("reply hi", relatesTo: .reply(to: target)))
        let sent = await sender.sent
        #expect(sent.count == 1)
        let wire = MessageEvent(
            type: sent[0].type,
            eventId: EventId(unchecked: "$e:x"),
            sender: UserId(unchecked: "@alice:x"),
            roomId: room,
            originServerTs: 1,
            content: sent[0].content)
        let decrypted = await alice.decryptRoomEvent(wire, in: room)
        #expect(
            decrypted?.content["m.relates_to"]?["m.in_reply_to"]?["event_id"]
                == .string("$target:x"))
    }

    @Test("Encrypted attachment carries file and info through decrypt")
    func encryptedAttachment() async throws {
        let room = RoomId(unchecked: "!r:x")
        let sender = FakeRoomSender()
        let alice = RoomCrypto(sharer: FakeSharer(), sender: sender)
        let content = MessageContent(
            msgtype: .image,
            body: "photo.png",
            file: EncryptedFile(
                url: "mxc://x/cipher",
                key: AttachmentKey(key: "k"),
                iv: "iv",
                hashes: ["sha256": "h"]),
            info: MediaInfo(
                mimeType: "image/png", size: 4, width: 2, height: 2))
        _ = try await alice.sendEncryptedContent(room, content)
        let sent = await sender.sent
        #expect(sent.count == 1)
        // The outer event must be Megolm-wrapped: a bare m.room.message
        // never decrypts in encrypted rooms.
        #expect(sent[0].type == "m.room.encrypted")
        let wire = MessageEvent(
            type: sent[0].type,
            eventId: EventId(unchecked: "$e:x"),
            sender: UserId(unchecked: "@alice:x"),
            roomId: room,
            originServerTs: 1,
            content: sent[0].content)
        let decrypted = await alice.decryptRoomEvent(wire, in: room)
        #expect(decrypted?.content["msgtype"] == .string("m.image"))
        #expect(decrypted?.content["body"] == .string("photo.png"))
        #expect(
            decrypted?.content["file"]?["url"] == .string("mxc://x/cipher"))
        #expect(
            decrypted?.content["info"]?["mimetype"] == .string("image/png"))
        #expect(decrypted?.content["info"]?["w"]?.intValue == 2)
    }

    @Test("Encrypted echo confirms on sync like plaintext")
    func encryptedEchoConfirm() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        await room.stageEcho(
            echoEvent(id: "local:t9", txn: "t9"),
            transactionId: TransactionId("t9"))
        let confirmed = MessageEvent(
            type: "m.room.encrypted",
            eventId: EventId(unchecked: "$real:x"),
            sender: UserId(unchecked: "@alice:x"),
            roomId: RoomId(unchecked: "!r:x"),
            originServerTs: 1_700_000_000_001,
            content: [
                "algorithm": .string("m.megolm.v1.aes-sha2"),
                "ciphertext": .string("AAAA"),
                "sender_key": .string("k"),
                "session_id": .string("s"),
            ],
            unsigned: ["transaction_id": .string("t9")])
        await room.applyJoined(JoinedRoomDelta(timeline: [confirmed]))
        #expect(await room.timeline.map(\.eventId.value) == ["$real:x"])
        #expect(await room.sendStates.isEmpty)
    }
}
