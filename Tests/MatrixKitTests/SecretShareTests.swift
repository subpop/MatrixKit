import Foundation
import MatrixKitCrypto
import Testing

@testable import MatrixKit

/// Exercise `SecretShare` request/receive/autoload against `FakeSender`.
@Suite("SecretShare")
struct SecretShareTests {
    private func makeShare(
        store: CrossSigningStore? = nil,
        userId: UserId = UserId(unchecked: "@a:b"),
        deviceId: DeviceId = DeviceId("D"),
        olm: OlmConnector? = nil
    ) -> (share: SecretShare, sender: FakeSender, crossSigning: CrossSigning, transport: MatrixTransport) {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: userId, deviceId: deviceId,
            accessToken: "t")
        let crossSigning = CrossSigning(transport: transport, session: session)
        let sender = FakeSender()
        let share = SecretShare(
            sender: sender, session: session, crossSigning: crossSigning,
            store: store, olm: olm)
        return (share, sender, crossSigning, transport)
    }

    private func tempStore() -> CrossSigningStore {
        CrossSigningStore(keystore: InMemoryKeyStore())
    }

    /// Decode every recorded `m.secret.request` as name → request ID.
    private func requestedIDs(_ sender: FakeSender) async throws -> [String: String] {
        var out: [String: String] = [:]
        for entry in await sender.sent where entry.type == "m.secret.request" {
            let data = try JSONEncoder().encode(AnyCodableDictionary(entry.content))
            let req = try JSONDecoder().decode(SecretRequest.self, from: data)
            out[req.name] = req.requestId
            #expect(req.requestingDeviceId == "D")
            #expect(req.action == "request")
        }
        return out
    }

    private func secretEvent(requestId: String, secret: String) throws -> BasicEvent {
        let send = SecretSend(requestId: requestId, secret: secret)
        let data = try JSONEncoder().encode(send)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dictData = try JSONSerialization.data(withJSONObject: json ?? [:])
        let content = try JSONDecoder().decode(
            [String: AnyCodable].self, from: dictData)
        return BasicEvent(
            type: "m.secret.send",
            sender: UserId(unchecked: "@a:b"),
            content: content)
    }

    @Test("requestSecrets sends one request per secret name to all devices")
    func requestsAll() async throws {
        let (share, sender, _, transport) = makeShare()
        let ids = try await share.requestSecrets(
            from: UserId(unchecked: "@a:b"), deviceId: nil)
        #expect(ids.count == 3)
        #expect(await share.pendingCount == 3)
        let byName = try await requestedIDs(sender)
        #expect(Set(byName.keys) == Set(SecretName.all))
        for entry in await sender.sent {
            #expect(entry.devices == ["*"])
        }
        try? await transport.shutdown()
    }

    @Test("requestSecrets targets a single device when given")
    func requestsTargeted() async throws {
        let (share, sender, _, transport) = makeShare()
        _ = try await share.requestSecrets(
            from: UserId(unchecked: "@a:b"), deviceId: "DEV2")
        for entry in await sender.sent {
            #expect(entry.devices == ["DEV2"])
        }
        try? await transport.shutdown()
    }

    @Test("receive ignores non-secret events")
    func ignoresOtherEvents() async {
        let (share, _, _, transport) = makeShare()
        let outcome = await share.receive(
            BasicEvent(type: "m.room.message", content: [:]))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        try? await transport.shutdown()
    }

    @Test("receive rejects secrets for unknown request IDs")
    func unknownRequest() async throws {
        let (share, _, _, transport) = makeShare()
        let outcome = await share.receive(
            try secretEvent(requestId: "nope", secret: "x"))
        guard case .unknownRequest = outcome else {
            Issue.record("expected .unknownRequest, got \(outcome)")
            return
        }
        try? await transport.shutdown()
    }

    @Test("Full round-trip: bank all three, import, persist, complete")
    func roundTrip() async throws {
        let store = tempStore()
        let (share, sender, crossSigning, transport) = makeShare(store: store)

        // Donor keys: what the peer's secret.send replies would carry.
        let donorTransport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let donor = CrossSigning(
            transport: donorTransport,
            session: Session(
                homeserver: URL(string: "https://example.com")!,
                userId: UserId(unchecked: "@a:b"), deviceId: DeviceId("PEER"),
                accessToken: "t"))
        _ = await donor.generate()
        let exported = try #require(await donor.exportPrivateKeys())

        _ = try await share.requestSecrets(
            from: UserId(unchecked: "@a:b"), deviceId: nil)
        let byName = try await requestedIDs(sender)
        let secrets = [
            SecretName.master: exported.master,
            SecretName.selfSigning: exported.selfSigning,
            SecretName.userSigning: exported.userSigning,
        ]

        var outcomes: [SecretReceiveOutcome] = []
        for name in [SecretName.master, SecretName.selfSigning] {
            outcomes.append(
                await share.receive(
                    try secretEvent(
                        requestId: try #require(byName[name]),
                        secret: try #require(secrets[name]))))
        }
        // Partial: banked but not complete, keys not yet usable.
        #expect(await crossSigning.hasKeys == false)
        #expect(await share.pendingCount == 1)

        outcomes.append(
            await share.receive(
                try secretEvent(
                    requestId: try #require(byName[SecretName.userSigning]),
                    secret: try #require(secrets[SecretName.userSigning]))))
        guard case .stored = outcomes[0], case .stored = outcomes[1],
            case .completed = outcomes[2]
        else {
            Issue.record("expected stored/stored/completed, got \(outcomes)")
            return
        }
        #expect(await crossSigning.hasKeys == true)
        #expect(await share.pendingCount == 0)

        // Persisted: the backup round-trips through the store.
        let loaded = await store.load(userId: UserId(unchecked: "@a:b"))
        #expect(loaded?.masterPrivateKey == exported.master)
        #expect(loaded?.selfSigningPrivateKey == exported.selfSigning)
        #expect(loaded?.userSigningPrivateKey == exported.userSigning)

        try? await transport.shutdown()
        try? await donorTransport.shutdown()
    }

    @Test("completion notifies events() subscribers")
    func completionNotifies() async throws {
        let (share, sender, _, transport) = makeShare()
        let stream = await share.events()
        let collected = Task {
            var out: [SecretShareEvent] = []
            for await event in stream {
                out.append(event)
                break
            }
            return out
        }

        let donorTransport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let donor = CrossSigning(
            transport: donorTransport,
            session: Session(
                homeserver: URL(string: "https://example.com")!,
                userId: UserId(unchecked: "@a:b"), deviceId: DeviceId("PEER"),
                accessToken: "t"))
        _ = await donor.generate()
        let exported = try #require(await donor.exportPrivateKeys())

        _ = try await share.requestSecrets(
            from: UserId(unchecked: "@a:b"), deviceId: nil)
        let byName = try await requestedIDs(sender)
        let secrets = [
            SecretName.master: exported.master,
            SecretName.selfSigning: exported.selfSigning,
            SecretName.userSigning: exported.userSigning,
        ]
        for name in [SecretName.master, SecretName.selfSigning] {
            _ = await share.receive(
                try secretEvent(
                    requestId: try #require(byName[name]),
                    secret: try #require(secrets[name])))
        }
        // No completion yet: the subscriber sees nothing.
        #expect(collected.isCancelled == false)
        let outcome = await share.receive(
            try secretEvent(
                requestId: try #require(byName[SecretName.userSigning]),
                secret: try #require(secrets[SecretName.userSigning])))
        guard case .completed = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            try? await transport.shutdown()
            try? await donorTransport.shutdown()
            return
        }
        let events = await collected.value
        #expect(events == [.secretsCompleted])
        try? await transport.shutdown()
        try? await donorTransport.shutdown()
    }

    @Test("autoload restores persisted keys into a fresh instance")
    func autoload() async throws {
        let store = tempStore()
        let (first, _, firstKeys, firstTransport) = makeShare(store: store)
        _ = await firstKeys.generate()
        await first.persist()
        try? await firstTransport.shutdown()

        let (second, _, secondKeys, secondTransport) = makeShare(store: store)
        #expect(await secondKeys.hasKeys == false)
        await second.autoload()
        #expect(await secondKeys.hasKeys == true)
        try? await secondTransport.shutdown()
    }

    // MARK: - Responder

    private func requestEvent(
        name: String, device: String = "PEER", requestId: String = "r1",
        action: String = "request",
        from: UserId = UserId(unchecked: "@a:b")
    ) -> BasicEvent {
        BasicEvent(
            type: "m.secret.request", sender: from,
            content: [
                "action": .string(action),
                "name": .string(name),
                "requesting_device_id": .string(device),
                "request_id": .string(requestId),
            ])
    }

    @Test("request without olm answers nothing")
    func requestWithoutOlm() async {
        let (share, sender, _, transport) = makeShare()
        let outcome = await share.receive(
            requestEvent(name: SecretName.master))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        #expect(await sender.sent.isEmpty)
        try? await transport.shutdown()
    }

    @Test("request answers the held half, Olm-encrypted")
    func requestAnsweredEncrypted() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderSender = FakeSender()
        let requesterSender = FakeSender()
        let holderOlm = OlmConnector(keys: keys, sender: holderSender)
        let requesterOlm = OlmConnector(keys: keys, sender: requesterSender)
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        try await requesterOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: requesterUser, deviceId: DeviceId("REQ"))
        try await holderOlm.ensureKeys()
        try await requesterOlm.ensureKeys()

        let (share, _, holderKeys, transport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        _ = await holderKeys.generate()
        let exported = try #require(await holderKeys.exportPrivateKeys())

        let outcome = await share.receive(
            requestEvent(
                name: SecretName.master, device: "REQ",
                from: requesterUser))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        let sent = await holderSender.sent
        #expect(sent.count == 1)
        #expect(sent[0].type == "m.room.encrypted")
        let wire = BasicEvent(
            type: sent[0].type, sender: holderUser,
            content: sent[0].content)
        let inner = await requesterOlm.decrypt([wire])
        #expect(inner.count == 1)
        #expect(inner[0].type == "m.secret.send")
        #expect(inner[0].content["request_id"] == .string("r1"))
        #expect(inner[0].content["secret"] == .string(exported.master))
        try? await transport.shutdown()
    }

    @Test("spec-shape round-trip: plaintext request → encrypted answer → completed")
    func requestEncryptedRoundTrip() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderSender = FakeSender()
        let requesterSender = FakeSender()
        let holderOlm = OlmConnector(keys: keys, sender: holderSender)
        let requesterOlm = OlmConnector(keys: keys, sender: requesterSender)
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        try await requesterOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: requesterUser, deviceId: DeviceId("REQ"))
        try await holderOlm.ensureKeys()
        try await requesterOlm.ensureKeys()

        let (holderShare, _, holderKeys, holderTransport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        _ = await holderKeys.generate()
        let exported = try #require(await holderKeys.exportPrivateKeys())
        let (requesterShare, requesterShareSender, requesterKeys, requesterTransport) =
            makeShare(
                userId: requesterUser, deviceId: DeviceId("REQ"),
                olm: requesterOlm)

        // Requests go out plaintext per spec (action: "request"
        // included), never encrypted.
        let ids = try await requesterShare.requestSecrets(
            from: holderUser, deviceId: "HOLDER")
        #expect(ids.count == 3)
        let reqSends = await requesterShareSender.sent
        #expect(reqSends.count == 3)
        #expect(reqSends.allSatisfy { $0.type == "m.secret.request" })

        // Pump plaintext requests straight to the holder; answers come
        // back Olm-encrypted.
        for entry in reqSends {
            let request = BasicEvent(
                type: entry.type, sender: requesterUser,
                content: entry.content)
            let outcome = await holderShare.receive(request)
            guard case .ignored = outcome else {
                Issue.record("expected .ignored, got \(outcome)")
                return
            }
        }
        let ansSends = await holderSender.sent
        #expect(ansSends.count == 3)
        #expect(ansSends.allSatisfy { $0.type == "m.room.encrypted" })

        // Pump answers back; all three halves land, last one completes.
        var outcomes: [SecretReceiveOutcome] = []
        for entry in ansSends {
            let wire = BasicEvent(
                type: entry.type, sender: holderUser,
                content: entry.content)
            for inner in await requesterOlm.decrypt([wire]) {
                outcomes.append(await requesterShare.receive(inner))
            }
        }
        #expect(outcomes.count == 3)
        guard case .stored = outcomes[0] else {
            Issue.record("expected .stored, got \(outcomes[0])")
            return
        }
        guard case .stored = outcomes[1] else {
            Issue.record("expected .stored, got \(outcomes[1])")
            return
        }
        guard case .completed = outcomes[2] else {
            Issue.record("expected .completed, got \(outcomes[2])")
            return
        }
        let imported = try #require(await requesterKeys.exportPrivateKeys())
        #expect(imported == exported)
        try? await holderTransport.shutdown()
        try? await requesterTransport.shutdown()
    }

    @Test("request for unknown secret or without keys stays silent")
    func requestUnanswerable() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderOlm = OlmConnector(keys: keys, sender: FakeSender())
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        // Keys held, but the name is unknown.
        let (share, sender, holderKeys, transport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        _ = await holderKeys.generate()
        let outcome = await share.receive(
            requestEvent(name: "m.unknown.secret", from: requesterUser))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        #expect(await sender.sent.isEmpty)
        try? await transport.shutdown()
    }

    @Test("request_cancellation stays silent")
    func requestCancellation() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderOlm = OlmConnector(keys: keys, sender: FakeSender())
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        let (share, sender, holderKeys, transport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        _ = await holderKeys.generate()
        let outcome = await share.receive(
            requestEvent(
                name: SecretName.master, action: "request_cancellation",
                from: requesterUser))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        #expect(await sender.sent.isEmpty)
        try? await transport.shutdown()
    }

    @Test("backup key request → encrypted answer → backupKeyReceived")
    func backupKeyRoundTrip() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderSender = FakeSender()
        let requesterOlmSender = FakeSender()
        let holderOlm = OlmConnector(keys: keys, sender: holderSender)
        let requesterOlm = OlmConnector(
            keys: keys, sender: requesterOlmSender)
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        try await requesterOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: requesterUser, deviceId: DeviceId("REQ"))
        try await holderOlm.ensureKeys()
        try await requesterOlm.ensureKeys()

        let (holderShare, _, _, holderTransport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        let backupKey = Data("backup-key-material".utf8)
        await holderShare.cacheBackupKey(backupKey)
        let (requesterShare, requesterSender, _, requesterTransport) = makeShare(
            userId: requesterUser, deviceId: DeviceId("REQ"),
            olm: requesterOlm)

        // The request goes out plaintext, targeted at the holder.
        _ = try await requesterShare.requestBackupKey(
            from: holderUser, deviceId: "HOLDER")
        let reqSends = await requesterSender.sent
        #expect(reqSends.count == 1)
        #expect(reqSends[0].type == "m.secret.request")
        #expect(reqSends[0].devices == ["HOLDER"])

        // Pump the request to the holder; the answer comes back
        // Olm-encrypted.
        for entry in reqSends {
            let outcome = await holderShare.receive(
                BasicEvent(
                    type: entry.type, sender: requesterUser,
                    content: entry.content))
            guard case .ignored = outcome else {
                Issue.record("expected .ignored, got \(outcome)")
                return
            }
        }
        let ansSends = await holderSender.sent
        #expect(ansSends.count == 1)
        #expect(ansSends[0].type == "m.room.encrypted")

        // Pump the answer back; the key surfaces via events().
        let stream = await requesterShare.events()
        let collected = Task {
            var out: [SecretShareEvent] = []
            for await event in stream {
                out.append(event)
                break
            }
            return out
        }
        for entry in ansSends {
            let wire = BasicEvent(
                type: entry.type, sender: holderUser,
                content: entry.content)
            for inner in await requesterOlm.decrypt([wire]) {
                let outcome = await requesterShare.receive(inner)
                guard case .stored = outcome else {
                    Issue.record("expected .stored, got \(outcome)")
                    return
                }
            }
        }
        let events = await collected.value
        #expect(events.count == 1)
        guard case .backupKeyReceived(let received) = events[0] else {
            Issue.record("expected .backupKeyReceived, got \(events[0])")
            return
        }
        #expect(received == backupKey)
        #expect(await requesterShare.pendingCount == 0)
        try? await holderTransport.shutdown()
        try? await requesterTransport.shutdown()
    }

    @Test("backup request without a held key stays silent")
    func backupRequestUnheld() async throws {
        let holderUser = UserId(unchecked: "@holder:x")
        let requesterUser = UserId(unchecked: "@requester:x")
        let keys = FakeKeys()
        let holderOlm = OlmConnector(keys: keys, sender: FakeSender())
        try await holderOlm.configure(
            identity: DeviceIdentityKeys.generate(),
            userId: holderUser, deviceId: DeviceId("HOLDER"))
        // No cacheBackupKey call: the holder has nothing to share.
        let (share, sender, _, transport) = makeShare(
            userId: holderUser, deviceId: DeviceId("HOLDER"),
            olm: holderOlm)
        let outcome = await share.receive(
            requestEvent(
                name: SecretName.backup, device: "REQ",
                from: requesterUser))
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        #expect(await sender.sent.isEmpty)
        try? await transport.shutdown()
    }
}
