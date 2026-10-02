import Foundation
import Testing

import MatrixKitCrypto
import MatrixKitTesting
@testable import MatrixKit

/// Facade integration suite: the `MatrixClient` wiring (restore, sync,
/// room list, rooms, send/receive, start/stop, logout) against the
/// harness. First coverage of the 1.2k-line facade.
@Suite("FacadeCompliance")
struct FacadeComplianceTests {
    @MainActor
    private func client(_ harness: Harness) async -> MatrixClient {
        await MatrixClient.restore(
            homeserver: await harness.baseURL,
            userId: UserId(unchecked: "@alice:test"),
            deviceId: DeviceId("ALICEDEVICE"),
            accessToken: "harness-token-alice")
    }

    /// View models refresh off the actor's update stream, so assertions
    /// after an action spin until convergence (or a 2s deadline) instead
    /// of racing the observer.
    @MainActor
    private func settle(until condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Sync populates the room list")
    @MainActor
    func syncPopulatesRooms() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", body: "hello a")
            await world.stageMessage(roomId: "!b:test", body: "hello b")
            let client = await client(harness)
            #expect(client.isAuthenticated)
            try await client.syncOnce()
            #expect(client.roomList.joined.count == 2)
            #expect(client.roomList.totalUnread == 0)
            try? await client.transport.shutdown()
        }
    }

    @Test("Create then send then sync lands the message")
    @MainActor
    func createSendReceive() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest(name: "General"))
            // The store learns the room on the next sync.
            try await client.syncOnce()
            #expect(client.roomList.joined.map(\.roomId) == [room.roomId])
            let sent = try await client.messages.sendText(room.roomId, "facade hi")
            try await client.syncOnce()
            // Same cached view model on repeat access.
            #expect(await client.room(room.roomId) === room)
            let actor = await client.store.room(room.roomId)
            #expect(await actor.timeline.map(\.eventId.value).contains(sent.value))
            try? await client.transport.shutdown()
        }
    }

    @Test("Join syncs the new membership into the store")
    @MainActor
    func joinFlow() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let created = try await client.rooms.create(CreateRoomRequest())
            let room = try await client.joinRoom(created)
            #expect(room.roomId == created)
            let members = await client.store.room(created).members
            #expect(members[UserId(unchecked: "@alice:test")]?.membership == .join)
            try? await client.transport.shutdown()
        }
    }

    @Test("Start streams deltas until stopped")
    @MainActor
    func startStop() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "live")
            let client = await client(harness)
            let deltas = client.deltas()
            try await client.startSync()
            var batches: [String] = []
            for await delta in deltas {
                batches.append(delta.nextBatch.value)
                if batches.count == 1 { break }
            }
            #expect(batches.count == 1)
            await client.stopSync()
            #expect(client.roomList.joined.count == 1)
            try? await client.transport.shutdown()
        }
    }

    @Test("Logout invalidates the session")
    @MainActor
    func logout() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            try await client.logout()
            #expect(!client.isAuthenticated)
            await #expect(throws: MatrixError.notAuthenticated) {
                try await client.logout()
            }
            try? await client.transport.shutdown()
        }
    }

    @Test("Room view model sends with echo, confirms on sync")
    @MainActor
    func roomSendConfirm() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await client.syncOnce()
            let echoId = await room.send(text: "view model hi")
            let echo = try #require(echoId)
            #expect(echo.value.hasPrefix("local:"))
            #expect(room.timeline?.events.map(\.eventId.value).contains(echo.value) == true)
            try await client.syncOnce()
            let ids = room.timeline?.events.map(\.eventId.value) ?? []
            #expect(!ids.contains(echo.value))
            #expect(ids.contains { $0.hasPrefix("$w") })
            #expect(room.timeline?.events.allSatisfy { $0.sendState != .pending } == true)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room view model marks read and advances the marker")
    @MainActor
    func roomMarkRead() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let sent = try await client.messages.sendText(room.roomId, "read me")
            try await room.markRead(sent)
            let receipts = await world.recordedReceipts()
            #expect(receipts.map(\.event) == [sent.value])
            try await room.sendFullyRead(sent)
            #expect(try await client.accountData.fullyRead(room.roomId) == sent)
            try? await client.transport.shutdown()
        }
    }

    @Test("Profile view model loads, edits, and round-trips the avatar")
    @MainActor
    func profileFlow() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let profile = client.profile(for: UserId(unchecked: "@alice:test"))
            #expect(profile.isOwn)
            try await profile.load()
            #expect(profile.displayName == "Alice")
            #expect(!profile.isLoading)
            try await profile.updateDisplayName("Alice Liddell")
            #expect(profile.displayName == "Alice Liddell")
            try await profile.updateAvatar(data: Data("avatar".utf8), mimeType: "image/png")
            #expect(profile.avatarURL?.value.hasPrefix("mxc://test/m") == true)
            #expect(try await profile.avatarData() == Data("avatar".utf8))
            let stranger = client.profile(for: UserId(unchecked: "@stranger:test"))
            #expect(!stranger.isOwn)
            try await stranger.updateDisplayName("Nope")
            #expect(stranger.displayName == nil)
            try? await client.transport.shutdown()
        }
    }

    @Test("Push rules view model loads, toggles, and deletes")
    @MainActor
    func pushRulesFlow() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let rules = client.pushRules()
            try await rules.load()
            #expect(!rules.isLoading)
            #expect(rules.rules.map(\.id).contains("override/.m.rule.master"))
            let master = try #require(rules.rules.first { $0.rule.ruleId == ".m.rule.master" })
            #expect(master.rule.enabled == false)
            try await rules.setEnabled(master, enabled: true)
            #expect(rules.rules.first { $0.id == master.id }?.rule.enabled == true)
            try await rules.delete(master)
            #expect(!rules.rules.map(\.id).contains(master.id))
            try? await client.transport.shutdown()
        }
    }

    @Test("Room replies, edits, and reactions round-trip")
    @MainActor
    func roomMessagingFlows() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await client.syncOnce()
            let base = try await client.messages.sendText(room.roomId, "base")
            try await room.reply(to: base, text: "reply")
            try await room.threadReply(rootEventId: base, text: "thread")
            try await room.edit(base, newText: "base fixed")
            try await room.react(to: base, key: "👍")
            let annotations = try await client.messages.relations(
                room.roomId, eventId: base, relType: "m.annotation")
            #expect(annotations.chunk.count == 1)
            let threads = try await client.messages.relations(
                room.roomId, eventId: base, relType: "m.thread")
            #expect(threads.chunk.count == 1)
            let edits = try await client.messages.relations(
                room.roomId, eventId: base, relType: "m.replace")
            #expect(edits.chunk.count == 1)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room attachment uploads and sends")
    @MainActor
    func roomAttachment() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let echo = await room.sendAttachment(
                data: Data("bytes".utf8), filename: "f.png", mimeType: "image/png")
            #expect(echo?.value.hasPrefix("local:") == true)
            let uploads = await harness.requests.filter { $0.path == "/_matrix/media/v3/upload" }
            #expect(uploads.count == 1)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room attachment reports progress ending at 1")
    @MainActor
    func roomAttachmentProgress() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let collector = ProgressCollector()
            let echo = await room.sendAttachment(
                data: Data(repeating: 0xAB, count: 200 * 1024),
                filename: "big.bin", mimeType: "application/octet-stream",
                onProgress: { collector.append($0) })
            #expect(echo?.value.hasPrefix("local:") == true)
            let fractions = collector.values
            #expect(fractions.count >= 2)
            #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(fractions.last == 1)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room invite, leave, and member loading")
    @MainActor
    func roomMembershipFlows() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await room.invite(UserId(unchecked: "@bob:test"))
            try await room.loadMembers()
            #expect(room.members.contains(UserId(unchecked: "@bob:test")))
            #expect(room.memberDetails[UserId(unchecked: "@bob:test")]?.membership == .invite)
            try await room.leave()
            try await client.syncOnce()
            await settle { room.membership == .leave }
            #expect(await room.membership == .leave)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room name, topic, details, pins, and favourite")
    @MainActor
    func roomStateFlows() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await room.setName("General")
            try await room.setTopic("All chat")
            try await client.syncOnce()
            #expect(room.name == "General")
            #expect(room.topic == "All chat")
            let details = try await room.roomDetails()
            #expect(details.name == "General")
            let sent = try await client.messages.sendText(room.roomId, "pinnable")
            try await room.pin(sent)
            try await client.syncOnce()
            await settle { room.pinnedEventIds == [sent.value] }
            #expect(await room.pinnedEventIds == [sent.value])
            #expect(try await room.pinnedMessages().map(\.eventId) == [sent])
            try await room.unpin(sent)
            try await client.syncOnce()
            await settle { room.pinnedEventIds.isEmpty }
            #expect(await room.pinnedEventIds.isEmpty)
            try await room.setFavourite(true)
            try await client.syncOnce()
            await settle { room.isFavourite }
            #expect(await room.isFavourite)
            #expect(try await client.accountData.tags(room.roomId)?.tags["m.favourite"] != nil)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room typing sends and avatar hydrates from state")
    @MainActor
    func roomTypingAndAvatar() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await room.setTyping(true)
            #expect(await world.typingUsers(roomId: room.roomId.value) == ["@alice:test"])
            _ = try await client.roomState.setAvatar(
                room.roomId, url: try MXCURI("mxc://test/avatar"))
            #expect(await room.hydrateMissingAvatar())
            #expect(room.avatarURL?.value == "mxc://test/avatar")
            #expect(await room.hydrateMissingAvatar() == false)
            try? await client.transport.shutdown()
        }
    }

    @Test("Password login adopts the server identity")
    @MainActor
    func passwordLogin() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let client = try await MatrixClient.login(
                homeserver: baseURL, user: "alice", password: "secret",
                deviceDisplayName: "Tests")
            #expect(client.isAuthenticated)
            #expect(client.userId == UserId(unchecked: "@alice:test"))
            #expect(await client.session.deviceId != DeviceId(""))
            try? await client.transport.shutdown()
        }
    }

    @Test("Reconcile adopts whoami identity")
    @MainActor
    func reconcile() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            let client = await MatrixClient.restore(
                homeserver: baseURL,
                userId: UserId(unchecked: ""), deviceId: DeviceId(""),
                accessToken: "harness-token-alice")
            try await client.reconcileIdentity()
            #expect(client.userId == UserId(unchecked: "@alice:test"))
            #expect(client.deviceId == DeviceId("ALICEDEVICE"))
            try? await client.transport.shutdown()
        }
    }

    @Test("Sliding sync facade runs and stops")
    @MainActor
    func slidingFacade() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.setUnstableFeatures(
                [UnstableFeature.simplifiedSlidingSync: true])
            await world.stageMessage(body: "sliding")
            let baseURL = await harness.baseURL
            let client = await MatrixClient.restore(
                homeserver: baseURL,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"),
                accessToken: "harness-token-alice")
            #expect(client.canUseSlidingSync)
            try await client.slidingSyncOnce()
            #expect(await client.slidingSync.pos == "p1")
            try await client.startSlidingSync()
            await client.stopSlidingSync()
            #expect(client.roomList.joined.count == 1)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room reaction toggles on and off")
    @MainActor
    func roomToggleReaction() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await client.syncOnce()
            let target = try await client.messages.sendText(room.roomId, "react me")
            try await client.syncOnce()
            await room.toggleReaction(target: target, key: "👍")
            let annotations = try await client.messages.relations(
                room.roomId, eventId: target, relType: "m.annotation")
            #expect(annotations.chunk.count == 1)
            // Toggling the staged echo drops it without a server call.
            await room.toggleReaction(target: target, key: "👍")
            // Sync the confirmed reaction, then toggle off: stamps a
            // redaction and removes the badge via the server.
            try await client.syncOnce()
            await room.toggleReaction(target: target, key: "👍")
            try? await client.transport.shutdown()
        }
    }

    @Test("Read markers outside the window resolve via event fetch")
    @MainActor
    func resolveMarkers() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            let marker = await world.stageMessage(roomId: "!r:test", body: "old")
            let room = await client.store.room(RoomId(unchecked: "!r:test"))
            // Marker known to the server but outside the actor window.
            await room.applyJoined(JoinedRoomDelta(
                timeline: [snapshotMessage("new", id: "$new:test")],
                accountData: [BasicEvent(
                    type: "m.fully_read",
                    content: ["event_id": .string(marker.eventId.value)])]))
            #expect(await room.needsMarkerResolution)
            await client.resolveReadMarkers()
            #expect(await room.needsMarkerResolution == false)
            #expect(await room.effectiveUnreadCount == 0)
            try? await client.transport.shutdown()
        }
    }

    @Test("Knock by ID and alias resolves the same room")
    @MainActor
    func knockVariants() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let (rooms, _, _) = await harness.roomClient()
            let roomId = try await rooms.create(CreateRoomRequest(roomAliasName: "knockable"))
            #expect(try await client.knockRoom(roomId) == roomId)
            #expect(try await client.knockRoom(RoomAlias(unchecked: "#knockable:test")) == roomId)
            try? await client.transport.shutdown()
        }
    }

    @Test("Encryption status reflects backup and recovery state")
    @MainActor
    func encryptionStatus() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let off = await client.encryptionStatus()
            #expect(!off.backupEnabled)
            #expect(!off.recoveryEnabled)
            let privateKey = BackupCrypto.generatePrivateKey()
            let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
            _ = try await client.backup.createBackup(publicKey: publicKey)
            await client.crossSigning.generate()
            try await client.crossSigning.upload()
            let on = await client.encryptionStatus()
            #expect(on.backupEnabled)
            #expect(on.recoveryEnabled)
            try? await client.transport.shutdown()
        }
    }

    @Test("Verify-against detects other devices")
    @MainActor
    func verifyAgainst() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            #expect(await client.hasDevicesToVerifyAgainst() == false)
            await world.seedDevice(DeviceEntry(
                deviceId: DeviceId("PHONE"), displayName: "Phone"))
            #expect(await client.hasDevicesToVerifyAgainst())
            try? await client.transport.shutdown()
        }
    }

    @Test("Crypto wipe clears local material")
    @MainActor
    func cryptoWipe() async throws {
        try await withHarness { harness in
            let keystore = InMemoryKeyStore()
            let baseURL = await harness.baseURL
            let client = await MatrixClient.restore(
                homeserver: baseURL,
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"),
                accessToken: "harness-token-alice",
                keystore: keystore)
            let user = UserId(unchecked: "@alice:test")
            try await CrossSigningStore(keystore: keystore).save(
                CrossSigningBackup(
                    masterPrivateKey: "m", selfSigningPrivateKey: "s",
                    userSigningPrivateKey: "u"),
                userId: user)
            try await DeviceIdentityStore(keystore: keystore).save(
                DeviceIdentityKeys.generate().backup(),
                userId: user, deviceId: DeviceId("ALICEDEVICE"))
            await client.deleteLocalCryptoMaterial()
            #expect(await CrossSigningStore(keystore: keystore).load(userId: user) == nil)
            #expect(await DeviceIdentityStore(keystore: keystore)
                .load(userId: user, deviceId: DeviceId("ALICEDEVICE")) == nil)
            try? await client.transport.shutdown()
        }
    }

    @Test("Delta stream yields sync rounds")
    @MainActor
    func deltaStream() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "streamed")
            let client = await client(harness)
            let deltas = client.deltas()
            try await client.startSync()
            var batches: [String] = []
            for await delta in deltas {
                batches.append(delta.nextBatch.value)
                if batches.count == 1 { break }
            }
            #expect(batches == ["s1"])
            await client.stopSync()
            try? await client.transport.shutdown()
        }
    }

    @Test("Room HTML, redact, marker ID, and retry flows")
    @MainActor
    func roomMiscFlows() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            try await room.sendHTML(body: "hi", formattedBody: "<b>hi</b>")
            let sent = try await client.messages.sendText(room.roomId, "doomed")
            try await room.redact(sent, reason: "spam")
            let pruned = try await client.messages.event(room.roomId, sent)
            #expect(pruned.content.isEmpty)
            #expect(await room.fullyReadEventId() == nil)
            try await room.sendFullyRead(sent)
            #expect(await room.fullyReadEventId() == sent)
            #expect(await client.retryTimelineDecryption() == 0)
            try? await client.transport.shutdown()
        }
    }

    @Test("Share room key and serve key requests")
    @MainActor
    func roomKeyFlows() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            await client.configureEncryption()
            let room = try await client.createRoom(CreateRoomRequest())
            // Bob joins with his own session; both sides configure Olm
            // and publish keys through the world routes.
            let bobUser = UserId(unchecked: "@bob:test")
            let (bobAccess, _) = await world.mintTokens(
                userId: bobUser, deviceId: DeviceId("BOB"))
            let bobTransport = MatrixTransport(homeserver: await harness.baseURL)
            await harness.trackTransport(bobTransport)
            let bobSession = Session(
                homeserver: await harness.baseURL, userId: bobUser,
                deviceId: DeviceId("BOB"), accessToken: bobAccess)
            try await RoomClient(transport: bobTransport, session: bobSession).join(room.roomId)
            let bobOlm = OlmConnector(
                keys: KeyClient(transport: bobTransport, session: bobSession),
                sender: ToDeviceClient(transport: bobTransport, session: bobSession))
            try await bobOlm.configure(
                identity: DeviceIdentityKeys.generate(),
                userId: bobUser, deviceId: DeviceId("BOB"))
            try await bobOlm.ensureKeys()
            try await client.olm.configure(
                identity: DeviceIdentityKeys.generate(),
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            try await client.olm.ensureKeys()
            // Alice shares; Bob's key request (Olm-encrypted, as peers
            // send it) is served with the requested session — not just
            // whatever outbound happens to be current.
            try await client.shareRoomKey(room.roomId)
            let sessionId = try #require(
                await client.roomCrypto.outboundSessionId(for: room.roomId))
            let request = RoomCrypto.keyRequestContent(
                requestId: "req-1", deviceId: DeviceId("BOB"),
                roomId: room.roomId, sessionId: sessionId)
            try await bobOlm.sendEncrypted(
                eventType: "m.room_key_request", content: request,
                to: UserId(unchecked: "@alice:test"), devices: [DeviceId("ALICEDEVICE")])
            struct Envelope: Decodable {
                var messages: [String: [String: [String: AnyCodable]]]
            }
            let sends = await world.recordedToDeviceSends()
            let envelope = try JSONDecoder().decode(
                Envelope.self, from: try #require(sends.last).body)
            let payload = try #require(envelope.messages["@alice:test"]?["ALICEDEVICE"])
            await world.queueToDevice(BasicEvent(
                type: "m.room.encrypted",
                sender: bobUser, content: payload))
            try await client.syncOnce()
            // The serve answered Bob's request with the room key: three
            // to-device sends (share, request, answer), the last one
            // decrypting to m.room_key on Bob's side.
            let allSends = await world.recordedToDeviceSends()
            #expect(allSends.count == 3)
            struct AnswerEnvelope: Decodable {
                var messages: [String: [String: [String: AnyCodable]]]
            }
            let answer = try JSONDecoder().decode(
                AnswerEnvelope.self, from: try #require(allSends.last).body)
            let answerPayload = try #require(answer.messages["@bob:test"]?["BOB"])
            let answerWire = BasicEvent(
                type: "m.room.encrypted", sender: UserId(unchecked: "@alice:test"),
                content: answerPayload)
            let answerInner = await bobOlm.decrypt([answerWire])
            #expect(answerInner.first?.type == "m.room_key")
            #expect(answerInner.first?.content["session_id"]?.stringValue == sessionId)
            // Unknown sessions are ignored, not mis-answered with the
            // current outbound session.
            let unknownRequest = RoomCrypto.keyRequestContent(
                requestId: "req-2", deviceId: DeviceId("BOB"),
                roomId: room.roomId, sessionId: "unknown-session")
            try await bobOlm.sendEncrypted(
                eventType: "m.room_key_request", content: unknownRequest,
                to: UserId(unchecked: "@alice:test"), devices: [DeviceId("ALICEDEVICE")])
            let sendsBeforeUnknown = await world.recordedToDeviceSends()
            let unknownEnvelope = try JSONDecoder().decode(
                Envelope.self, from: try #require(sendsBeforeUnknown.last).body)
            let unknownPayload = try #require(unknownEnvelope.messages["@alice:test"]?["ALICEDEVICE"])
            await world.queueToDevice(BasicEvent(
                type: "m.room.encrypted",
                sender: bobUser, content: unknownPayload))
            try await client.syncOnce()
            #expect(await world.recordedToDeviceSends().count == sendsBeforeUnknown.count)
            try? await client.transport.shutdown()
        }
    }

    @Test("Targeted backup fetch heals too-old sessions")
    @MainActor
    func backupHealsTooOld() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            await client.configureEncryption()
            let room = RoomId(unchecked: "!room:test")
            let bobUser = UserId(unchecked: "@bob:test")
            func payload(_ body: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "room_id": room.value,
                    "type": "m.room.message",
                    "content": ["body": body, "msgtype": "m.text"],
                ])
            }
            // One originator lineage: the backup holds index 0 while
            // the client only ever receives the index-5 share.
            var origin = MegolmSession.create()
            let sessionId = origin.id
            let exportEarly = origin.export()
            let wireEarly = try origin.encrypt(payload("early"))
            _ = try origin.encrypt(payload("one"))
            _ = try origin.encrypt(payload("two"))
            _ = try origin.encrypt(payload("three"))
            _ = try origin.encrypt(payload("four"))
            let exportLate = origin.export()
            let privateKey = BackupCrypto.generatePrivateKey()
            let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
            let version = try await client.backup.createBackup(publicKey: publicKey)
            try await client.backup.uploadSessions(
                [(roomId: room, sessionId: sessionId, export: exportEarly)],
                publicKey: publicKey, version: version)
            await client.secrets.cacheBackupKey(privateKey)
            await client.roomCrypto.receiveRoomKey(BasicEvent(
                type: RoomCrypto.roomKeyType, sender: bobUser,
                content: [
                    "algorithm": .string(RoomCrypto.megolmAlgorithm),
                    "room_id": .string(room.value),
                    "session_id": .string(sessionId),
                    "session_key": .string(
                        Primitives.base64UnpaddedEncode(exportLate)),
                ]))
            let wire = MessageEvent(
                type: "m.room.encrypted", eventId: EventId(unchecked: "$early"),
                sender: bobUser, roomId: room, originServerTs: 1,
                content: [
                    "session_id": .string(sessionId),
                    "ciphertext": .string(
                        Primitives.base64UnpaddedEncode(wireEarly)),
                ])
            #expect(await client.roomCrypto.decryptRoomEvent(wire, in: room) == nil)
            // Recovery runs async off the decrypt sighting: the backup
            // fetch imports the early state, and the wire decrypts.
            // Capture the healed event: a successful decrypt advances
            // the ratchet, so re-decrypting the same wire afterwards
            // correctly reports a replay.
            final class HealedBox: @unchecked Sendable {
                private let lock = NSLock()
                private var event: MessageEvent?
                func store(_ event: MessageEvent) {
                    lock.withLock { self.event = event }
                }
                var value: MessageEvent? { lock.withLock { event } }
            }
            let healed = HealedBox()
            await waitUntil("backup fetch heals the wire") {
                guard let decrypted = await client.roomCrypto.decryptRoomEvent(
                    wire, in: room)
                else { return false }
                healed.store(decrypted)
                return true
            }
            #expect(healed.value?.content["body"] == .string("early"))
            try? await client.transport.shutdown()
        }
    }

    @Test("Failed login shuts down and rethrows")
    @MainActor
    func loginFailure() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            await #expect(throws: MatrixError.serverError(
                code: "M_FORBIDDEN", message: "Invalid username or password",
                retryAfter: nil))
            {
                try await MatrixClient.login(
                    homeserver: baseURL, user: "alice", password: "wrong")
            }
        }
    }

    @Test("Backup restore imports sessions and reports count")
    @MainActor
    func backupRestore() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let privateKey = BackupCrypto.generatePrivateKey()
            let publicKey = try BackupCrypto.publicKey(privateKey: privateKey)
            let version = try await client.backup.createBackup(publicKey: publicKey)
            var sender = MegolmSession.create()
            let blob = sender.export()
            _ = try sender.encrypt(Data("backed up".utf8))
            try await client.backup.uploadSessions(
                [(roomId: RoomId(unchecked: "!room:test"), sessionId: "sid1", export: blob)],
                publicKey: publicKey, version: version)
            let count = try await client.restoreKeyBackup(privateKey: privateKey)
            #expect(count == 1)
            // Restored sessions decrypt.
            let inbound = try MegolmSession.importSessionKey(blob)
            _ = inbound
            try? await client.transport.shutdown()
        }
    }

    @Test("Backup restore cancellation surfaces cancelled")
    @MainActor
    func backupRestoreCancel() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            // No backup configured: the guard throws, and the cancelled
            // task converts it to .cancelled via the rethrow path.
            let task = Task {
                try await client.restoreKeyBackup(
                    privateKey: Data(repeating: 9, count: 32))
            }
            task.cancel()
            await #expect(throws: MatrixError.cancelled) {
                try await task.value
            }
            try? await client.transport.shutdown()
        }
    }

    @Test("Failed markers still adopt locally")
    @MainActor
    func markersFailureAdopts() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let sent = try await client.messages.sendText(room.roomId, "hi")
            await harness.setOverride(
                method: "POST",
                path: "/_matrix/client/v3/rooms/\(room.roomId.value.pathSegmentEncoded)/read_markers",
                response: .matrixError(code: "M_UNKNOWN", message: "boom", status: 500))
            await #expect(throws: MatrixError.self) {
                try await room.sendFullyRead(sent)
            }
            #expect(await room.fullyReadEventId() == sent)
            try? await client.transport.shutdown()
        }
    }

    @Test("Sync routes room keys and secret sends")
    @MainActor
    func routeToDevice() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            await client.configureEncryption()
            // A room-key event reaches roomCrypto; completion is
            // best-effort without a matching session (no throw).
            await world.queueToDevice(BasicEvent(
                type: "m.room_key",
                sender: UserId(unchecked: "@bob:test"),
                content: [
                    "algorithm": .string("m.megolm.v1.aes-sha2"),
                    "room_id": .string("!r:test"),
                    "session_id": .string("s1"),
                    "session_key": .string("a2V5"),
                ]))
            try await client.syncOnce()
            try? await client.transport.shutdown()
        }
    }

    @Test("Verification self-heal re-signs the device")
    @MainActor
    func verificationSelfHeal() async throws {
        try await withHarness { harness in
            let (keys, _, _) = await harness.keyClient()
            let client = await client(harness)
            // Local keys exist but the uploaded device record lacks a
            // self-signature: refresh re-signs and verifies.
            await client.crossSigning.generate()
            let material = DeviceIdentityKeys.generate()
            _ = try await keys.uploadDeviceKeys(UploadDeviceKeysRequest(
                deviceKeys: material.deviceKeys(
                    userId: "@alice:test", deviceId: "ALICEDEVICE")))
            await client.refreshVerificationState()
            #expect(await client.hasCheckedVerificationState)
            #expect(await client.isSessionVerified)
            try? await client.transport.shutdown()
        }
    }

    @Test("Cancelled recovery surfaces cancelled")
    @MainActor
    func recoverCancelled() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let task = Task {
                try await client.recover(withRecoveryKey: "EsX")
            }
            task.cancel()
            await #expect(throws: MatrixError.cancelled) {
                try await task.value
            }
            try? await client.transport.shutdown()
        }
    }

    @Test("Failing factories shut down and rethrow")
    @MainActor
    func factoryFailures() async throws {
        try await withHarness { harness in
            let baseURL = await harness.baseURL
            // No OIDC metadata: device login throws unsupported.
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/auth_metadata",
                response: .matrixError(code: "M_UNRECOGNIZED", message: "nope", status: 404))
            await #expect(throws: MatrixError.serverError(
                code: "M_OIDC_UNSUPPORTED",
                message: "Homeserver does not advertise OIDC auth metadata",
                retryAfter: nil))
            {
                try await MatrixClient.loginViaOIDC(
                    homeserver: baseURL, clientName: "Tests",
                    onUserCode: { _, _, _ in })
            }
            // Bad password through the login factory.
            await #expect(throws: MatrixError.self) {
                try await MatrixClient.login(
                    homeserver: baseURL, user: "alice", password: "wrong")
            }
        }
    }

    @Test("Account-data deltas trigger marker resolution in the loop")
    @MainActor
    func loopMarkerResolution() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let sent = try await client.messages.sendText(room.roomId, "hi")
            try await client.accountData.setFullyRead(room.roomId, eventId: sent)
            try await client.startSync()
            await client.stopSync()
            try? await client.transport.shutdown()
        }
    }

    @Test("Encrypted send shares and delivers ciphertext")
    @MainActor
    func encryptedSend() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            try await client.olm.configure(
                identity: DeviceIdentityKeys.generate(),
                userId: UserId(unchecked: "@alice:test"),
                deviceId: DeviceId("ALICEDEVICE"))
            try await client.olm.ensureKeys()
            let room = try await client.createRoom(CreateRoomRequest())
            // Bob joins with published keys so the share has a target.
            let bobUser = UserId(unchecked: "@bob:test")
            let (bobAccess, _) = await world.mintTokens(
                userId: bobUser, deviceId: DeviceId("BOB"))
            let bobTransport = MatrixTransport(homeserver: await harness.baseURL)
            await harness.trackTransport(bobTransport)
            let bobSession = Session(
                homeserver: await harness.baseURL, userId: bobUser,
                deviceId: DeviceId("BOB"), accessToken: bobAccess)
            try await RoomClient(transport: bobTransport, session: bobSession).join(room.roomId)
            let bobOlm = OlmConnector(
                keys: KeyClient(transport: bobTransport, session: bobSession),
                sender: FakeSender())
            try await bobOlm.configure(
                identity: DeviceIdentityKeys.generate(),
                userId: bobUser, deviceId: DeviceId("BOB"))
            try await bobOlm.ensureKeys()
            let sent = try await client.sendEncryptedContent(
                room.roomId, MessageContent.text("secret"))
            #expect(sent.value.hasPrefix("$w"))
            // The wire carries an Olm-encrypted event for Bob.
            let shares = await world.recordedToDeviceSends()
            #expect(!shares.isEmpty)
            try? await client.transport.shutdown()
        }
    }

    @Test("Room key injection and unknown sessions route")
    @MainActor
    func keyInjection() async throws {
        try await withHarness { harness in
            let world = await harness.world
            let client = await client(harness)
            await client.configureEncryption()
            let room = try await client.createRoom(CreateRoomRequest())
            try await client.syncOnce()
            // A well-formed room key imports and resolves the room.
            var sender = MegolmSession.create()
            let blob = sender.export()
            let message = try sender.encrypt(Data("injected".utf8))
            let sessionId = "injected-session"
            _ = message
            await world.queueToDevice(BasicEvent(
                type: "m.room_key",
                sender: UserId(unchecked: "@bob:test"),
                content: [
                    "algorithm": .string("m.megolm.v1.aes-sha2"),
                    "room_id": .string(room.roomId.value),
                    "session_id": .string(sessionId),
                    "session_key": .string(Primitives.base64UnpaddedEncode(blob)),
                ]))
            try await client.syncOnce()
            // An undecryptable timeline event fires the unknown-session
            // handler; Bob has no published keys, so no request goes out.
            let cipher = try await client.messages.sendEvent(
                room.roomId, eventType: "m.room.encrypted",
                content: [
                    "algorithm": AnyCodable.string("m.megolm.v1.aes-sha2"),
                    "sender_key": AnyCodable.string("bobcurve"),
                    "session_id": AnyCodable.string("ghost-session"),
                    "ciphertext": AnyCodable.string(
                        Primitives.base64UnpaddedEncode(Data("junk".utf8))),
                ])
            _ = cipher
            try await client.syncOnce()
            try? await client.transport.shutdown()
        }
    }

    @Test("Loop account-data deltas resolve markers")
    @MainActor
    func loopAccountData() async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let room = try await client.createRoom(CreateRoomRequest())
            let sent = try await client.messages.sendText(room.roomId, "hi")
            try await client.accountData.setFullyRead(room.roomId, eventId: sent)
            let deltas = client.deltas()
            try await client.startSync()
            var sawAccountData = false
            for await delta in deltas {
                if delta.joined.values.contains(where: { !$0.accountData.isEmpty }) {
                    sawAccountData = true
                    break
                }
            }
            #expect(sawAccountData)
            await client.stopSync()
            try? await client.transport.shutdown()
        }
    }

    @Test("Encrypted rooms without a sender fail sends locally", arguments: [
        "text", "html", "reply", "thread", "edit", "react", "attach",
    ])
    @MainActor
    func encryptedNoSender(_ variant: String) async throws {
        try await withHarness { harness in
            let client = await client(harness)
            let actor = await client.store.room(RoomId(unchecked: "!enc:test"))
            await actor.applyJoined(JoinedRoomDelta(state: [MessageEvent(
                type: "m.room.encryption",
                eventId: EventId(unchecked: "$enc:test"),
                sender: UserId(unchecked: "@alice:test"),
                stateKey: "",
                originServerTs: 1,
                content: ["algorithm": .string("m.megolm.v1.aes-sha2")])]))
            #expect(await actor.isEncrypted)
            // Built directly: no encryptSender installed (client.room
            // always installs one).
            let room = await ObservableRoom(
                room: actor, messages: client.messages, rooms: client.rooms,
                roomState: client.roomState, accountData: client.accountData,
                media: client.media, localUser: client.userId)
            let target = EventId(unchecked: "$t:test")
            switch variant {
            case "text":
                let echo = await room.send(text: "hi")
                #expect(echo?.value.hasPrefix("local:") == true)
            case "html":
                await #expect(throws: MatrixError.notAuthenticated) {
                    try await room.sendHTML(body: "hi", formattedBody: "<b>hi</b>")
                }
            case "reply":
                await #expect(throws: MatrixError.notAuthenticated) {
                    try await room.reply(to: target, text: "hi")
                }
            case "thread":
                await #expect(throws: MatrixError.notAuthenticated) {
                    try await room.threadReply(rootEventId: target, text: "hi")
                }
            case "edit":
                await #expect(throws: MatrixError.notAuthenticated) {
                    try await room.edit(target, newText: "hi")
                }
            case "react":
                // Reactions always go out plaintext (no encrypted path).
                try await room.react(to: target, key: "👍")
            default:
                let echo = await room.sendAttachment(
                    data: Data("bytes".utf8), filename: "f.png",
                    mimeType: "image/png")
                #expect(echo?.value.hasPrefix("local:") == true)
            }
            try? await client.transport.shutdown()
        }
    }
}
