import Foundation
import Testing

import MatrixKitTesting

@testable import MatrixKit
@testable import MatrixKitCrypto

@Suite("Send pipeline")
@MainActor
struct SendPipelineTests {
    @Test("Mentions encode as m.mentions")
    func mentionsShape() throws {        let content = MessageContent.text(
            "hi",
            mentions: Mentions(
                userIds: [UserId(unchecked: "@bob:x")], room: true))
        let data = try JSONEncoder().encode(content)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(json["m.mentions"]?["user_ids"]?.arrayValue?.first?.stringValue == "@bob:x")
        #expect(json["m.mentions"]?["room"]?.boolValue == true)
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
        _ = try await alice.sendEncryptedContent(
            room, content, deviceId: DeviceId("ALICE"))
        let sent = await sender.sent
        #expect(sent.count == 1)
        // The outer event must be Megolm-wrapped: a bare m.room.message
        // never decrypts in encrypted rooms.
        #expect(sent[0].type == "m.room.encrypted")
        // The envelope carries the sender's device: recipients cannot
        // parse `m.room.encrypted` without it.
        #expect(sent[0].content["device_id"] == .string("ALICE"))
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
}
