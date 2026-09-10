import Foundation
import Testing

@testable import MatrixKit

/// The monitor's outbound driver: start/accept/keys flow automatically off
/// inbound traffic, SAS surfaces exactly once, MAC/done finish the flow,
/// and broken flows fail paired with finish. Two monitors face each other
/// over `FakeSender`s; recorded sends are pumped peer-to-peer as events.
@Suite("VerificationMonitorDriver")
struct VerificationMonitorDriverTests {
    private struct Fixture: Sendable {
        let user: UserId
        let monitor: VerificationMonitor
        let fake: FakeSender
        let keys: FakeKeys
        let log: EventLog
        let transport: MatrixTransport
        var pumpIndex: Int = 0
    }

    private actor EventLog {
        var events: [VerificationMonitorEvent] = []
        func append(_ event: VerificationMonitorEvent) {
            events.append(event)
        }
        func matching(
            _ predicate: (VerificationMonitorEvent) -> Bool
        ) -> [VerificationMonitorEvent] {
            events.filter(predicate)
        }
    }

    private func makeFixture(
        user: String, device: String, keys: FakeKeys? = nil
    ) async -> Fixture {
        let userId = UserId(unchecked: user)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: userId, deviceId: DeviceId(device), accessToken: "token")
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let fake = FakeSender()
        let keyService = keys ?? FakeKeys()
        let monitor = VerificationMonitor(
            toDevice: ToDeviceClient(transport: transport, session: session),
            olm: OlmConnector(keys: keyService, sender: fake),
            session: session,
            keys: KeyClient(transport: transport, session: session))
        await monitor.setSenderOverrideForTesting(fake)
        return Fixture(
            user: userId, monitor: monitor, fake: fake, keys: keyService,
            log: EventLog(), transport: transport)
    }

    /// Transports own their HTTP client, which fatals on a bare deinit —
    /// shut them down before fixtures go out of scope.
    private func shutdown(_ fixtures: Fixture...) async {
        for fixture in fixtures {
            try? await fixture.transport.shutdown()
        }
    }

    private func subscribe(_ fixture: Fixture) -> Task<Void, Never> {
        Task {
            for await event in await fixture.monitor.events() {
                await fixture.log.append(event)
            }
        }
    }

    /// Wait until the subscriber task has registered, so no broadcast
    /// event is produced into zero subscribers and lost.
    private func awaitSubscription(_ fixture: Fixture) async throws {
        try await waitFor("subscription") {
            await fixture.monitor.subscriberCount > 0
        }
    }

    /// Forward freshly recorded sends as inbound events on the peer monitor.
    private func pump(from: inout Fixture, to: Fixture) async {
        let sent = await from.fake.sent
        let fresh = Array(sent.dropFirst(from.pumpIndex))
        from.pumpIndex = sent.count
        await to.monitor.receive(fresh.map {
            BasicEvent(type: $0.type, sender: from.user, content: $0.content)
        })
    }

    private func content<T: Encodable>(
        _ value: T
    ) throws -> [String: AnyCodable] {
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data)
        let dictData = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(
            [String: AnyCodable].self, from: dictData)
    }

    private func waitFor(
        _ description: String, _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func state(
        _ fixture: Fixture, txn: String
    ) async -> VerificationState? {
        guard let session = await fixture.monitor.session(for: txn) else {
            return nil
        }
        return await session.state
    }

    /// Drive a requester/responder pair to SAS, returning both fixtures,
    /// the transaction ID, and the event subscriptions (cancelled by the
    /// caller when the test ends).
    private func drivenPair() async throws -> (
        alice: Fixture, bob: Fixture, txn: String, subs: [Task<Void, Never>]
    ) {
        var alice = await makeFixture(user: "@alice:x", device: "ALICE")
        var bob = await makeFixture(user: "@bob:x", device: "BOB")
        let subs = [subscribe(alice), subscribe(bob)]
        try await awaitSubscription(alice)
        try await awaitSubscription(bob)
        let session = try await alice.monitor.requestVerification(
            userId: bob.user, deviceId: nil)
        let txn = await session.transactionId
        for _ in 0..<10 {
            await pump(from: &alice, to: bob)
            if let request = await bob.monitor.pendingRequests.first {
                _ = try await bob.monitor.acceptRequest(request)
            }
            await pump(from: &bob, to: alice)
            let aliceReady = await state(alice, txn: txn) == .keysExchanged
            let bobReady = await state(bob, txn: txn) == .keysExchanged
            if aliceReady && bobReady { break }
        }
        #expect(await state(alice, txn: txn) == .keysExchanged)
        #expect(await state(bob, txn: txn) == .keysExchanged)
        return (alice, bob, txn, subs)
    }

    @Test("Handshake drives itself to SAS, surfaced exactly once")
    func autoDriveToSAS() async throws {
        var (alice, bob, txn, subs) = try await drivenPair()
        defer { subs.forEach { $0.cancel() } }
        // Both sides surface SAS with matching emoji…
        try await waitFor("alice sasReady") {
            await alice.log.matching {
                if case .sasReady(let t, _, _) = $0 { t == txn } else { false }
            }.count == 1
        }
        try await waitFor("bob sasReady") {
            await bob.log.matching {
                if case .sasReady(let t, _, _) = $0 { t == txn } else { false }
            }.count == 1
        }
        let aliceSAS = await alice.log.matching {
            if case .sasReady = $0 { true } else { false }
        }
        let bobSAS = await bob.log.matching {
            if case .sasReady = $0 { true } else { false }
        }
        guard
            case .sasReady(_, let aliceEmoji, _) = aliceSAS.first,
            case .sasReady(_, let bobEmoji, _) = bobSAS.first
        else {
            Issue.record("Missing sasReady on either side")
            await shutdown(alice, bob)
            return
        }
        #expect(aliceEmoji == bobEmoji)
        // …and redelivering our key doesn't re-surface it.
        let sent = await alice.fake.sent
        guard let key = sent.first(where: {
            $0.type == "m.key.verification.key"
        }) else {
            Issue.record("Alice never sent her key")
            await shutdown(alice, bob)
            return
        }
        await bob.monitor.receive([BasicEvent(
            type: key.type, sender: alice.user, content: key.content)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await bob.log.matching {
            if case .sasReady = $0 { true } else { false }
        }.count == 1)
        await shutdown(alice, bob)
    }

    @Test("Confirm drives MAC then done to finish on both sides")
    func confirmDrivesToDone() async throws {
        var (alice, bob, txn, subs) = try await drivenPair()
        defer { subs.forEach { $0.cancel() } }
        let aliceKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:ALICE", key: "A")
        ]
        let bobKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:BOB", key: "B")
        ]
        await alice.monitor.setOwnKeysProvider { _ in aliceKeys }
        await bob.monitor.setOwnKeysProvider { _ in bobKeys }
        await alice.monitor.setMacKeysProvider { _ in bobKeys }
        await bob.monitor.setMacKeysProvider { _ in aliceKeys }
        guard
            let aliceSession = await alice.monitor.session(for: txn),
            let bobSession = await bob.monitor.session(for: txn)
        else {
            Issue.record("Sessions missing")
            await shutdown(alice, bob)
            return
        }
        try await alice.monitor.confirm(aliceSession)
        try await bob.monitor.confirm(bobSession)
        for _ in 0..<10 {
            await pump(from: &alice, to: bob)
            await pump(from: &bob, to: alice)
            let aliceFinished = await state(alice, txn: txn) == .done
            let bobFinished = await state(bob, txn: txn) == .done
            if aliceFinished && bobFinished { break }
        }
        #expect(await state(alice, txn: txn) == .done)
        #expect(await state(bob, txn: txn) == .done)
        // Finished may arrive twice (drive on our done, then the peer's
        // done landing in the same batch) — at-least-once is the contract.
        try await waitFor("alice finished") {
            await alice.log.matching {
                if case .sessionFinished(let t) = $0 { t == txn } else { false }
            }.count >= 1
        }
        try await waitFor("bob finished") {
            await bob.log.matching {
                if case .sessionFinished(let t) = $0 { t == txn } else { false }
            }.count >= 1
        }
        await shutdown(alice, bob)
    }

    @Test("Peer approving first neither completes nor blocks our side")
    func peerApproveFirstWaitsForUs() async throws {
        var (alice, bob, txn, subs) = try await drivenPair()
        defer { subs.forEach { $0.cancel() } }
        let aliceKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:ALICE", key: "A")
        ]
        let bobKeys = [
            VerificationSession.KeyToMAC(id: "ed25519:BOB", key: "B")
        ]
        await alice.monitor.setOwnKeysProvider { _ in aliceKeys }
        await bob.monitor.setOwnKeysProvider { _ in bobKeys }
        await alice.monitor.setMacKeysProvider { _ in bobKeys }
        await bob.monitor.setMacKeysProvider { _ in aliceKeys }
        guard
            let aliceSession = await alice.monitor.session(for: txn),
            let bobSession = await bob.monitor.session(for: txn)
        else {
            Issue.record("Sessions missing")
            await shutdown(alice, bob)
            return
        }
        // Bob approves first; Alice hasn't.
        try await bob.monitor.confirm(bobSession)
        await pump(from: &bob, to: alice)
        #expect(await state(alice, txn: txn) == .macReceived)
        // Alice verified his MAC but sent nothing back and finished nothing.
        #expect(await alice.fake.sent.filter {
            $0.type == "m.key.verification.mac"
        }.isEmpty)
        #expect(await alice.fake.sent.filter {
            $0.type == "m.key.verification.done"
        }.isEmpty)
        #expect(await bob.fake.sent.filter {
            $0.type == "m.key.verification.done"
        }.isEmpty)
        #expect(await alice.log.matching {
            if case .sessionFinished = $0 { true } else { false }
        }.isEmpty)
        // Alice approves after: her MAC goes out, done follows, both finish.
        try await alice.monitor.confirm(aliceSession)
        for _ in 0..<10 {
            await pump(from: &alice, to: bob)
            await pump(from: &bob, to: alice)
            let aliceFinished = await state(alice, txn: txn) == .done
            let bobFinished = await state(bob, txn: txn) == .done
            if aliceFinished && bobFinished { break }
        }
        #expect(await state(alice, txn: txn) == .done)
        #expect(await state(bob, txn: txn) == .done)
        await shutdown(alice, bob)
    }

    @Test("Peer cancel finishes the flow without stalling")
    func peerCancelFinishes() async throws {
        let (alice, bob, txn, subs) = try await drivenPair()
        defer { subs.forEach { $0.cancel() } }
        let cancel = try content(VerificationCancel(
            code: "m.user", reason: "", transactionId: txn))
        await alice.monitor.receive([BasicEvent(
            type: "m.key.verification.cancel",
            sender: UserId(unchecked: "@bob:x"), content: cancel)])
        try await waitFor("cancel finished") {
            await alice.log.matching {
                if case .sessionFinished(let t) = $0 { t == txn } else { false }
            }.count == 1
        }
        #expect(await alice.log.matching {
            if case .failed = $0 { true } else { false }
        }.isEmpty)
        await shutdown(alice, bob)
    }

    @Test("Broken flow reports failed paired with finish")
    func brokenFlowFailsPaired() async throws {
        let (alice, bob, txn, subs) = try await drivenPair()
        defer { subs.forEach { $0.cancel() } }
        // Key pool resolves locally; the MAC itself is bogus.
        await alice.monitor.setMacKeysProvider { _ in [] }
        // A MAC covering no keys fails verification outright.
        let badMac = try content(VerificationMac(
            keys: "junk", mac: [:], transactionId: txn))
        await alice.monitor.receive([BasicEvent(
            type: "m.key.verification.mac",
            sender: UserId(unchecked: "@bob:x"), content: badMac)])
        try await waitFor("failed") {
            await alice.log.matching {
                if case .failed(let t, _) = $0 { t == txn } else { false }
            }.count == 1
        }
        try await waitFor("failed then finished") {
            await alice.log.matching {
                if case .sessionFinished(let t) = $0 { t == txn } else { false }
            }.count == 1
        }
        let events = await alice.log.events
        let failedIndex = events.firstIndex {
            if case .failed = $0 { true } else { false }
        }
        let finishedIndex = events.firstIndex {
            if case .sessionFinished = $0 { true } else { false }
        }
        #expect(failedIndex != nil && finishedIndex != nil
            && failedIndex! < finishedIndex!)
        await shutdown(alice, bob)
    }

    @Test("Self-verify broadcast goes to our other devices, not ours")
    func selfBroadcastExcludesSelf() async throws {
        let keys = FakeKeys()
        let user = "@alice:x"
        await keys.seedDevice(user: user, device: "ALICE")
        await keys.seedDevice(user: user, device: "PHONE")
        let alice = await makeFixture(user: user, device: "ALICE", keys: keys)
        _ = try await alice.monitor.requestVerification(
            userId: alice.user, deviceId: nil)
        let requests = await alice.fake.sent.filter {
            $0.type == "m.key.verification.request"
        }
        #expect(requests.count == 1)
        #expect(requests.first?.devices == ["PHONE"])
        await shutdown(alice)
    }

    @Test("Self-verify with no other devices falls back to broadcast")
    func selfBroadcastSingleDeviceFallback() async throws {
        let alice = await makeFixture(user: "@alice:x", device: "ALICE")
        _ = try await alice.monitor.requestVerification(
            userId: alice.user, deviceId: nil)
        let requests = await alice.fake.sent.filter {
            $0.type == "m.key.verification.request"
        }
        #expect(requests.count == 1)
        #expect(requests.first?.devices == ["*"])
        await shutdown(alice)
    }

    @Test("Our own device's request echo never surfaces")
    func ownRequestEchoNeverSurfaces() async throws {
        let alice = await makeFixture(user: "@alice:x", device: "ALICE")
        let sub = subscribe(alice)
        defer { sub.cancel() }
        try await awaitSubscription(alice)
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        // Echo of our own request: same user, our device, untracked flow.
        let echo = try content(VerificationRequest(
            fromDevice: "ALICE", methods: ["m.sas.v1"],
            timestamp: nowMs, transactionId: UUID().uuidString))
        await alice.monitor.receive([BasicEvent(
            type: "m.key.verification.request", sender: alice.user,
            content: echo)])
        // A request from another of our devices DOES surface.
        let legit = try content(VerificationRequest(
            fromDevice: "PHONE", methods: ["m.sas.v1"],
            timestamp: nowMs, transactionId: UUID().uuidString))
        await alice.monitor.receive([BasicEvent(
            type: "m.key.verification.request", sender: alice.user,
            content: legit)])
        try await waitFor("other-device request surfaces") {
            await alice.log.matching {
                if case .requestReceived = $0 { true } else { false }
            }.count == 1
        }
        #expect(await alice.monitor.pendingRequests.count == 1)
        #expect(await alice.monitor.pendingRequests.first?.deviceId == "PHONE")
        await shutdown(alice)
    }
}
