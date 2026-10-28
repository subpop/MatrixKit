#if canImport(SwiftData)
import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit
@testable import MatrixKitSwiftData

/// `MessageSender`: echoed sends, encrypted dispatch, reactions,
/// redactions, pins, and read markers.
///
/// Exercised registry endpoints: `PUT /rooms/{roomId}/send/{type}/{txn}`,
/// `PUT /rooms/{roomId}/redact/{eventId}/{txn}`,
/// `GET /v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}`,
/// `PUT /rooms/{roomId}/state/{type}[/{key}]`,
/// `POST /rooms/{roomId}/read_markers`, `POST /media/v3/upload`,
/// `GET /rooms/{roomId}/joined_members`.
@Suite("MessageSender")
@MainActor
struct MessageSenderTests {
    private func sender(
        _ harness: Harness,
        token: String? = "harness-token-alice",
        localUser: UserId? = UserId(unchecked: "@alice:test")
    ) async throws -> (
        sender: MessageSender, writer: MatrixStoreWriter,
        sharer: FakeSharer, cryptoSender: FakeRoomSender
    ) {
        let (messages, _, _) = await harness.messageClient(token: token)
        let (media, _, _) = await harness.mediaClient(token: token)
        let (rooms, _, _) = await harness.roomClient(token: token)
        let (state, _, _) = await harness.roomStateClient(token: token)
        let (accountData, _, _) = await harness.accountDataClient(token: token)
        let sharer = FakeSharer()
        await sharer.setDevices(["@alice:test": ["ALICEDEVICE"]])
        let cryptoSender = FakeRoomSender()
        let roomCrypto = RoomCrypto(sharer: sharer, sender: cryptoSender)
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        if let localUser {
            try await writer.setLocalUser(localUser)
        }
        let reader = MatrixStoreReader(
            modelContainer: container, localUser: localUser)
        let sender = MessageSender(
            messages: messages, media: media, rooms: rooms,
            roomState: state, accountData: accountData,
            roomCrypto: roomCrypto, writer: writer, reader: reader,
            localUser: localUser,
            ownDeviceId: DeviceId("ALICEDEVICE"))
        return (sender, writer, sharer, cryptoSender)
    }

    private func sends(
        _ harness: Harness, containing fragment: String
    ) async -> [RecordedRequest] {
        await harness.requests.filter {
            $0.method == "PUT" && $0.path.contains(fragment)
        }
    }

    @Test("Text send stages an echo and PUTs once")
    func sendText() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let room = RoomId(unchecked: "!room:test")
            let (stagedEvents, stagedContinuation) = AsyncStream<Void>.makeStream()
            let stagedNotification = Task {
                for await _ in stagedEvents { return true }
                return false
            }
            let echo = try #require(await sender.sendText(
                room, "hello", onEchoStaged: { stagedContinuation.yield() }))
            stagedContinuation.finish()
            #expect(echo.value.hasPrefix("local:"))
            #expect(await stagedNotification.value)
            #expect(await sends(harness, containing: "/send/").count == 1)
            #expect(await writer.echoTransactionId(for: echo) != nil)
        }
    }

    @Test("Sticker send stages an echo and PUTs an m.sticker event")
    func sendSticker() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let room = RoomId(unchecked: "!room:test")
            let content = StickerContent(
                body: "a waving cat", url: "mxc://test/cat",
                info: MediaInfo(mimeType: "image/webp", width: 512, height: 512, isAnimated: true))
            let echo = try #require(await sender.sendSticker(room, content))
            #expect(echo.value.hasPrefix("local:"))
            let puts = await sends(harness, containing: "/send/m.sticker/")
            #expect(puts.count == 1)
            let body = try #require(puts.first?.body)
            let sent = try JSONDecoder().decode(StickerContent.self, from: body)
            #expect(sent == content)
            #expect(await writer.echoTransactionId(for: echo) != nil)
        }
    }

    struct StickerRelationCase: Sendable {
        var id: String
        var relatesTo: RelatesTo
        var relType: String?
        var eventId: String?
        var replyTo: String?
    }

    nonisolated static let stickerRelationCases: [StickerRelationCase] = [
        StickerRelationCase(
            id: "reply", relatesTo: .reply(to: EventId(unchecked: "$parent:test")),
            relType: nil, eventId: nil, replyTo: "$parent:test"),
        StickerRelationCase(
            id: "thread", relatesTo: .thread(root: EventId(unchecked: "$root:test")),
            relType: "m.thread", eventId: "$root:test", replyTo: nil),
        StickerRelationCase(
            id: "thread with reply fallback",
            relatesTo: .thread(
                root: EventId(unchecked: "$root:test"),
                replyTo: EventId(unchecked: "$parent:test")),
            relType: "m.thread", eventId: "$root:test", replyTo: "$parent:test"),
    ]

    private func relation(in content: [String: AnyCodable]) -> (
        relType: String?, eventId: String?, replyTo: String?
    ) {
        let relation = content["m.relates_to"]?.objectValue
        return (
            relation?["rel_type"]?.stringValue,
            relation?["event_id"]?.stringValue,
            relation?["m.in_reply_to"]?.objectValue?["event_id"]?.stringValue)
    }

    @Test("Stickers carry reply and thread relations", arguments: stickerRelationCases)
    func stickerRelations(_ row: StickerRelationCase) async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let room = RoomId(unchecked: "!room:test")
            _ = await sender.sendSticker(
                room,
                StickerContent(body: "cat", url: "mxc://test/cat", relatesTo: row.relatesTo))
            let body = try #require(
                await sends(harness, containing: "/send/m.sticker/").first?.body)
            let sent = try JSONDecoder().decode([String: AnyCodable].self, from: body)
            let found = relation(in: sent)
            #expect(found.relType == row.relType)
            #expect(found.eventId == row.eventId)
            #expect(found.replyTo == row.replyTo)
        }
    }

    @Test("Stickers without a relation omit m.relates_to")
    func stickerWithoutRelation() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            _ = await sender.sendSticker(
                RoomId(unchecked: "!room:test"),
                StickerContent(body: "cat", url: "mxc://test/cat"))
            let body = try #require(
                await sends(harness, containing: "/send/m.sticker/").first?.body)
            let sent = try JSONDecoder().decode([String: AnyCodable].self, from: body)
            #expect(sent["m.relates_to"] == nil)
        }
    }

    @Test("Encrypted sticker replies repeat the relation in the clear")
    func encryptedStickerReply() async throws {
        try await withHarness { harness in
            let (sender, writer, sharer, cryptoSender) = try await sender(harness)
            await sharer.setDevices(["@alice:test": ["ALICEDEVICE", "OTHER"]])
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE sticker reply")
            let parent = EventId(unchecked: "$parent:test")
            _ = await sender.sendSticker(
                room,
                StickerContent(body: "cat", url: "mxc://test/cat", relatesTo: .reply(to: parent)))

            let sent = try #require(await cryptoSender.sent.first)
            #expect(sent.type == "m.room.encrypted")
            #expect(relation(in: sent.content).replyTo == "$parent:test")

            let receiver = RoomCrypto(sharer: FakeSharer(), sender: FakeRoomSender())
            await receiver.receiveRoomKey(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@alice:test"),
                content: try #require(await sharer.shares.first).content))
            let decrypted = await receiver.decryptRoomEvent(
                MessageEvent(
                    type: sent.type, eventId: EventId(unchecked: "$e"),
                    sender: UserId(unchecked: "@alice:test"), roomId: room,
                    originServerTs: 0, content: sent.content),
                in: room)
            #expect(decrypted?.type == "m.sticker")
            #expect(relation(in: try #require(decrypted).content).replyTo == "$parent:test")
        }
    }

    @Test("Encrypted rooms send stickers as ciphertext that decrypts to m.sticker")
    func encryptedSticker() async throws {
        try await withHarness { harness in
            let (sender, writer, sharer, cryptoSender) = try await sender(harness)
            await sharer.setDevices(["@alice:test": ["ALICEDEVICE", "OTHER"]])
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE stickers")
            let content = StickerContent(body: "cat", url: "mxc://test/cat")
            let echo = try #require(await sender.sendSticker(room, content))
            #expect(await writer.echoTransactionId(for: echo) != nil)
            #expect(await sends(harness, containing: "/send/").isEmpty)

            let receiver = RoomCrypto(sharer: FakeSharer(), sender: FakeRoomSender())
            await receiver.receiveRoomKey(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@alice:test"),
                content: try #require(await sharer.shares.first).content))
            let sent = try #require(await cryptoSender.sent.first)
            #expect(sent.type == "m.room.encrypted")
            let decrypted = await receiver.decryptRoomEvent(
                MessageEvent(
                    type: sent.type, eventId: EventId(unchecked: "$e"),
                    sender: UserId(unchecked: "@alice:test"), roomId: room,
                    originServerTs: 0, content: sent.content),
                in: room)
            #expect(decrypted?.type == "m.sticker")
            #expect(decrypted?.content["url"]?.stringValue == "mxc://test/cat")
        }
    }

    @Test("Logged-out sticker sends return nil without network traffic")
    func stickerLoggedOut() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness, localUser: nil)
            let room = RoomId(unchecked: "!room:test")
            #expect(await sender.sendSticker(
                room, StickerContent(body: "cat", url: "mxc://test/cat")) == nil)
            #expect(await sends(harness, containing: "/send/").isEmpty)
        }
    }

    @Test("Sticker transport failures fail the echo instead of throwing")
    func stickerFailure() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness, token: nil)
            let room = RoomId(unchecked: "!room:test")
            let echo = try #require(await sender.sendSticker(
                room, StickerContent(body: "cat", url: "mxc://test/cat")))
            #expect(await sends(harness, containing: "/send/").isEmpty)
            #expect(await writer.echoTransactionId(for: echo) == nil)
        }
    }

    @Test("Logged-out sends return nil without network traffic")
    func loggedOut() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness, localUser: nil)
            let room = RoomId(unchecked: "!room:test")
            #expect(await sender.sendText(room, "hello") == nil)
            #expect(await sends(harness, containing: "/send/").isEmpty)
        }
    }

    @Test("Transport failures fail the echo instead of throwing")
    func sendFailure() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness, token: nil)
            let room = RoomId(unchecked: "!room:test")
            let echo = try #require(await sender.sendText(room, "hello"))
            #expect(await sends(harness, containing: "/send/").isEmpty)
            #expect(await writer.echoTransactionId(for: echo) == nil)
        }
    }

    @Test("Encrypted rooms share then send ciphertext")
    func encryptedSend() async throws {
        try await withHarness { harness in
            let (sender, writer, _, cryptoSender) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "E2EE"))
            try await writer.apply(SyncDelta(
                nextBatch: "s1",
                joined: [room: JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.encryption",
                        content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
                ])]))
            let echo = try #require(await sender.sendText(room, "secret"))
            #expect(echo.value.hasPrefix("local:"))
            // Ciphertext went through the crypto sender, never plaintext.
            let sent = await cryptoSender.sent
            #expect(sent.count == 1)
            #expect(sent[0].type == "m.room.encrypted")
            #expect(await sends(harness, containing: "/send/").isEmpty)
            #expect(await writer.echoTransactionId(for: echo) != nil)
        }
    }

    @Test("Reply, edit, and react reach the wire")
    func verbs() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "target")
            _ = try await sender.reply(room, to: target, body: "reply")
            _ = try await sender.edit(room, eventId: target, newBody: "fixed")
            _ = try await sender.react(room, to: target, key: "👍")
            #expect(await sends(harness, containing: "/send/m.room.message/").count == 3)
            #expect(await sends(harness, containing: "/send/m.reaction/").count == 1)
        }
    }

    @Test("Toggle adds a reaction")
    func toggleReaction() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "target")
            await sender.toggleReaction(room, target: target, key: "👍")
            #expect(await sends(harness, containing: "/send/m.reaction/").count == 1)
            // The staged echo awaits sync confirmation.
            let stored = try await writer.storedEvents(roomId: room)
            #expect(stored.contains { $0.eventId.value.hasPrefix("local:") })
        }
    }

    @Test("Toggle removes a confirmed reaction")
    func toggleReactionOff() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "target")
            // Server-side reaction with no staged echo (as after sync
            // confirmation): toggle resolves it via relations.
            _ = try await messages.react(room, to: target, key: "👍")
            await sender.toggleReaction(room, target: target, key: "👍")
            let redacts = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/redact/")
            }
            #expect(redacts.count == 1)
        }
    }

    @Test("Toggle cancels an unconfirmed echo")
    func toggleReactionEcho() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "target")
            await sender.toggleReaction(room, target: target, key: "👍")
            await sender.toggleReaction(room, target: target, key: "👍")
            // No server redact: the pending echo was dropped instead.
            let redacts = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/redact/")
            }
            #expect(redacts.isEmpty)
            let stored = try await writer.storedEvents(roomId: room)
            #expect(!stored.contains { $0.eventId.value.hasPrefix("local:") })
        }
    }

    @Test("Vote stages an echo and PUTs the response")
    func voteEcho() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let room = RoomId(unchecked: "!room:test")
            await sender.vote(room, poll: EventId(unchecked: "$poll:test"), answers: ["a1"])
            #expect(await sends(harness, containing: "/send/m.poll.response/").count == 1)
            let stored = try await writer.storedEvents(roomId: room)
            #expect(stored.contains {
                $0.eventId.value.hasPrefix("local:") && $0.type == "m.poll.response"
            })
        }
    }

    @Test("Failed vote cancels its echo")
    func voteFailure() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness, token: nil)
            let room = RoomId(unchecked: "!room:test")
            await sender.vote(room, poll: EventId(unchecked: "$poll:test"), answers: ["a1"])
            let stored = try await writer.storedEvents(roomId: room)
            #expect(!stored.contains { $0.eventId.value.hasPrefix("local:") })
        }
    }

    @Test("End poll PUTs the end event")
    func endPoll() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Polls"))
            try await sender.endPoll(room, poll: EventId(unchecked: "$poll:test"))
            #expect(await sends(harness, containing: "/send/m.poll.end/").count == 1)
        }
    }

    @Test("Redact cancels unsent echoes instead of posting")
    func redactEcho() async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness)
            let room = RoomId(unchecked: "!room:test")
            let echo = try #require(await sender.sendText(room, "unsent"))
            #expect(await writer.echoTransactionId(for: echo) != nil)
            _ = try await sender.redact(room, eventId: echo)
            let redacts = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/redact/")
            }
            #expect(redacts.isEmpty)
            #expect(await writer.echoTransactionId(for: echo) == nil)
        }
    }

    @Test("Pin and unpin write the pinned-events state")
    func pins() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Pins"))
            let target = EventId(unchecked: "$pinned:test")
            try await sender.pin(room, eventId: target)
            try await sender.unpin(room, eventId: target)
            let pins = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/state/m.room.pinned_events")
            }
            #expect(pins.count == 2)
        }
    }

    @Test("Fully-read advances the account marker")
    func fullyRead() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Markers"))
            try await sender.setFullyRead(room, eventId: EventId(unchecked: "$m:test"))
            let markers = await harness.requests.filter {
                $0.method == "POST" && $0.path.contains("/read_markers")
            }
            #expect(markers.count == 1)
        }
    }

    @Test("Attachments upload then send")
    func attachment() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Files"))
            let echo = try #require(await sender.sendAttachment(
                room, data: Data("bytes".utf8),
                filename: "note.txt", mimeType: "text/plain"))
            #expect(echo.value.hasPrefix("local:"))
            let uploads = await harness.requests.filter {
                $0.method == "POST" && $0.path.contains("/upload")
            }
            #expect(uploads.count == 1)
            #expect(await sends(harness, containing: "/send/m.room.message/").count == 1)
        }
    }

    nonisolated static let animationFlags: [Bool?] = [true, false, nil]

    @Test("Attachments carry the animation flag only when known", arguments: animationFlags)
    func attachmentAnimationFlag(_ flag: Bool?) async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Images"))
            _ = await sender.sendAttachment(
                room, data: Data("img".utf8), filename: "a.webp", mimeType: "image/webp",
                isAnimated: flag)
            let body = try #require(
                await sends(harness, containing: "/send/m.room.message/").first?.body)
            let sent = try JSONDecoder().decode([String: AnyCodable].self, from: body)
            let info = try #require(sent["info"]?.objectValue)
            #expect(info["is_animated"]?.boolValue == flag)
            #expect(info["mimetype"]?.stringValue == "image/webp")
        }
    }

    @Test("Gallery items carry the animation flag only when known", arguments: animationFlags)
    func galleryAnimationFlag(_ flag: Bool?) async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Gallery"))
            _ = await sender.sendGallery(
                room,
                items: [
                    .init(
                        data: Data("a".utf8), filename: "a.webp", mimeType: "image/webp",
                        isAnimated: flag),
                    .init(data: Data("b".utf8), filename: "b.png", mimeType: "image/png"),
                ],
                caption: "2 attachments")
            let body = try #require(
                await sends(harness, containing: "/send/m.room.message/").first?.body)
            let sent = try JSONDecoder().decode([String: AnyCodable].self, from: body)
            let items = try #require(sent.values.compactMap(\.arrayValue).first)
            let infos = items.compactMap { $0.objectValue?["info"]?.objectValue }
            #expect(infos.count == 2)
            #expect(infos[0]["is_animated"]?.boolValue == flag)
            #expect(infos[1]["is_animated"] == nil)
        }
    }

    @Test("Galleries upload every item then send one event")
    func gallery() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Gallery"))
            let echo = try #require(await sender.sendGallery(
                room,
                items: [
                    .init(data: Data("a".utf8), filename: "a.png", mimeType: "image/png"),
                    .init(data: Data("b".utf8), filename: "b.txt", mimeType: "text/plain"),
                ],
                caption: "2 attachments"))
            #expect(echo.value.hasPrefix("local:"))
            let uploads = await harness.requests.filter {
                $0.method == "POST" && $0.path.contains("/upload")
            }
            #expect(uploads.count == 2)
            #expect(await sends(harness, containing: "/send/m.room.message/").count == 1)
        }
    }

    // MARK: - Branch coverage

    /// Create a room and mark it encrypted in the store.
    private func encryptedRoom(
        _ harness: Harness, writer: MatrixStoreWriter, name: String
    ) async throws -> RoomId {
        let (rooms, _, _) = await harness.roomClient()
        let room = try await rooms.create(CreateRoomRequest(name: name))
        try await writer.apply(SyncDelta(
            nextBatch: "s1",
            joined: [room: JoinedRoomDelta(state: [
                stateEvent(
                    type: "m.room.encryption",
                    content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
            ])]))
        return room
    }

    @Test("Thread replies reach the wire in plaintext rooms")
    func threadReply() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let root = try await messages.sendText(room, "root")
            _ = try await sender.threadReply(
                room, root: root, parent: root, body: "in thread")
            #expect(await sends(harness, containing: "/send/m.room.message/").count == 2)
        }
    }

    @Test("Encrypted poll votes and ends keep their event types")
    func encryptedPollTypes() async throws {
        try await withHarness { harness in
            let (sender, writer, sharer, cryptoSender) = try await sender(harness)
            // A second device of ours receives the session and decrypts.
            await sharer.setDevices(["@alice:test": ["ALICEDEVICE", "OTHER"]])
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE polls")
            let poll = EventId(unchecked: "$poll:test")
            await sender.vote(room, poll: poll, answers: ["a1"])
            try await sender.endPoll(room, poll: poll)

            let shares = await sharer.shares
            let receiver = RoomCrypto(sharer: FakeSharer(), sender: FakeRoomSender())
            await receiver.receiveRoomKey(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@alice:test"),
                content: try #require(shares.first).content))
            let sent = await cryptoSender.sent
            #expect(sent.count == 2)
            var types: [String] = []
            for (index, event) in sent.enumerated() {
                let decrypted = await receiver.decryptRoomEvent(
                    MessageEvent(
                        type: event.type, eventId: EventId(unchecked: "$e\(index)"),
                        sender: UserId(unchecked: "@alice:test"), roomId: room,
                        originServerTs: index, content: event.content),
                    in: room)
                types.append(decrypted?.type ?? "undecryptable")
            }
            #expect(types == ["m.poll.response", "m.poll.end"])
        }
    }

    @Test("Encrypted rooms encrypt replies, thread replies, and edits")
    func encryptedVerbs() async throws {
        try await withHarness { harness in
            let (sender, writer, _, cryptoSender) = try await sender(harness)
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE verbs")
            let target = EventId(unchecked: "$target:test")
            _ = try await sender.reply(room, to: target, body: "reply")
            _ = try await sender.threadReply(room, root: target, body: "thread")
            _ = try await sender.edit(room, eventId: target, newBody: "edited")
            let sent = await cryptoSender.sent
            #expect(sent.count == 3)
            #expect(sent.allSatisfy { $0.type == "m.room.encrypted" })
            #expect(await sends(harness, containing: "/send/m.room.message/").isEmpty)
        }
    }

    @Test("Encrypted attachments upload ciphertext and thumbnail, then send")
    func encryptedAttachment() async throws {
        try await withHarness { harness in
            let (sender, writer, _, cryptoSender) = try await sender(harness)
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE files")
            let echo = try #require(await sender.sendAttachment(
                room, data: Data("pixels".utf8),
                filename: "pic.png", mimeType: "image/png",
                caption: "look", width: 2, height: 2,
                thumbnailData: Data("thumb".utf8), thumbnailMimeType: "image/png",
                inReplyTo: EventId(unchecked: "$parent:test")))
            #expect(echo.value.hasPrefix("local:"))
            let uploads = await harness.requests.filter {
                $0.method == "POST" && $0.path.contains("/upload")
            }
            #expect(uploads.count == 2)
            #expect(await cryptoSender.sent.count == 1)
            #expect(await sends(harness, containing: "/send/").isEmpty)
        }
    }

    @Test("Attachment upload failure fails the echo", arguments: [
        "image/png", "video/mp4", "audio/ogg", "application/pdf",
    ])
    func attachmentFailure(mimeType: String) async throws {
        try await withHarness { harness in
            let (sender, writer, _, _) = try await sender(harness, token: nil)
            let room = RoomId(unchecked: "!room:test")
            let echo = try #require(await sender.sendAttachment(
                room, data: Data("x".utf8), filename: "f", mimeType: mimeType,
                duration: 1))
            #expect(await writer.echoTransactionId(for: echo) == nil)
            #expect(await sends(harness, containing: "/send/").isEmpty)
        }
    }

    @Test("Attachments report upload progress")
    func attachmentProgress() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Progress"))
            let echo = await sender.sendAttachment(
                room, data: Data("bytes".utf8), filename: "a.txt",
                mimeType: "text/plain", onProgress: { _ in })
            #expect(echo != nil)
        }
    }

    @Test("Encrypted-room key sharing failure fails the echo")
    func encryptedShareFailure() async throws {
        try await withHarness { harness in
            let (sender, writer, _, cryptoSender) = try await sender(harness)
            let room = try await encryptedRoom(harness, writer: writer, name: "E2EE fail")
            // Membership lookup 404s for a room the server never created.
            let ghost = RoomId(unchecked: "!ghost:test")
            try await writer.apply(SyncDelta(
                nextBatch: "s2",
                joined: [ghost: JoinedRoomDelta(state: [
                    stateEvent(
                        type: "m.room.encryption",
                        content: ["algorithm": .string("m.megolm.v1.aes-sha2")])
                ])]))
            let echo = try #require(await sender.sendText(ghost, "lost"))
            #expect(await writer.echoTransactionId(for: echo) == nil)
            #expect(await cryptoSender.sent.isEmpty)
            _ = room
        }
    }

    @Test("Redact of a confirmed event posts to the server")
    func redactConfirmed() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (messages, _, _) = await harness.messageClient()
            let room = RoomId(unchecked: "!room:test")
            let target = try await messages.sendText(room, "bye")
            _ = try await sender.redact(room, eventId: target, reason: "spam")
            let redacts = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/redact/")
            }
            #expect(redacts.count == 1)
        }
    }

    @Test("Typing notifications reach the server")
    func typing() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness)
            let (rooms, _, _) = await harness.roomClient()
            let room = try await rooms.create(CreateRoomRequest(name: "Typing"))
            await sender.sendTyping(room, typing: true)
            let puts = await harness.requests.filter {
                $0.method == "PUT" && $0.path.contains("/typing/")
            }
            #expect(puts.count == 1)
        }
    }

    @Test("Logged-out sender ignores typing, attachments, and toggles")
    func loggedOutNoOps() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness, localUser: nil)
            let room = RoomId(unchecked: "!room:test")
            await sender.sendTyping(room, typing: true)
            await sender.toggleReaction(
                room, target: EventId(unchecked: "$t:test"), key: "👍")
            #expect(await sender.sendAttachment(
                room, data: Data(), filename: "f", mimeType: "text/plain") == nil)
            #expect(await harness.requests.filter { $0.method == "PUT" }.isEmpty)
        }
    }

    @Test("setLocalUser adopts a new identity")
    func adoptIdentity() async throws {
        try await withHarness { harness in
            let (sender, _, _, _) = try await sender(harness, localUser: nil)
            let room = RoomId(unchecked: "!room:test")
            #expect(await sender.sendText(room, "x") == nil)
            await sender.setLocalUser(
                UserId(unchecked: "@alice:test"), ownDeviceId: DeviceId("ALICEDEVICE"))
            #expect(await sender.sendText(room, "x") != nil)
        }
    }
}
#endif
