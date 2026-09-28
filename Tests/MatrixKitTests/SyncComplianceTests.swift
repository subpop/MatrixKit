import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Sync compliance suite — the Wave 2 reference pattern: SDK sync engine
/// against world state, asserting wire behavior, store application, and
/// crypto-hook delivery.
///
/// Exercised registry endpoints: `GET /sync`.
@Suite("SyncCompliance")
struct SyncComplianceTests {
    @Test("Initial sync applies rooms and advances the token")
    func initialSync() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "hello")
            await world.stageMessage(body: "world")
            let (sync, _, store, _, _) = await harness.syncClient()
            let delta = try await sync.syncOnce()
            #expect(delta.nextBatch.value == "s1")
            #expect(await store.syncToken?.value == "s1")
            let room = await store.room(RoomId(unchecked: "!room:test"))
            #expect(await room.timeline.count == 2)
            #expect(await room.timeline.map(\.eventId.value) == ["$e1:test", "$e2:test"])
        }
    }

    @Test("Batches advance monotonically across syncs")
    func batchesAdvance() async throws {
        try await withHarness { harness in
            let (sync, _, _, _, _) = await harness.syncClient()
            var batches: [String] = []
            for _ in 0..<3 {
                batches.append(try await sync.syncOnce().nextBatch.value)
            }
            #expect(batches == ["s1", "s2", "s3"])
        }
    }

    @Test("Sync sends the stored cursor as since")
    func sinceCursor() async throws {
        try await withHarness { harness in
            let (sync, _, store, _, _) = await harness.syncClient()
            _ = try await sync.syncOnce()
            _ = try await sync.syncOnce()
            let syncs = await harness.requests.filter { $0.path == "/_matrix/client/v3/sync" }
            #expect(syncs.count == 2)
            #expect(syncs[0].query["since"] == nil)
            #expect(syncs[1].query["since"] == "s1")
            #expect(await store.syncToken?.value == "s2")
        }
    }

    @Test("To-device queue drains in order, exactly once")
    func toDeviceDrain() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.queueToDevice(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@bob:test"),
                content: ["session_id": .string("s1")]))
            await world.queueToDevice(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@bob:test"),
                content: ["session_id": .string("s2")]))
            let (sync, _, _, _, _) = await harness.syncClient()
            let log = HookLog()
            await sync.setCryptoHooks(log.hooks())
            let delta = try await sync.syncOnce()
            #expect(delta.toDevice.count == 2)
            let batches = await log.toDeviceBatches
            #expect(batches.count == 1)
            #expect(batches.first?.map { $0.content["session_id"]?.stringValue } == ["s1", "s2"])
            // Drained: the next sync delivers nothing and fires no hook.
            _ = try await sync.syncOnce()
            #expect(await log.toDeviceBatches.count == 1)
        }
    }

    @Test("Device lists and key counts reach hooks, lists clear after")
    func deviceLists() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.setDeviceLists(
                changed: [UserId(unchecked: "@bob:test")],
                left: [UserId(unchecked: "@carol:test")])
            await world.setOTKCount(50)
            let (sync, _, _, _, _) = await harness.syncClient()
            let log = HookLog()
            await sync.setCryptoHooks(log.hooks())
            let delta = try await sync.syncOnce()
            #expect(delta.deviceChanged == [UserId(unchecked: "@bob:test")])
            #expect(delta.deviceLeft == [UserId(unchecked: "@carol:test")])
            #expect(delta.signedKeyCount == 50)
            #expect(await log.deviceLists.count == 1)
            #expect(await log.keyCounts == [50])
            // Lists clear; key counts persist.
            _ = try await sync.syncOnce()
            #expect(await log.deviceLists.count == 1)
            #expect(await log.keyCounts == [50, 50])
        }
    }

    @Test("Filter encodes into the sync query")
    func filterQuery() async throws {
        try await withHarness { harness in
            let (sync, _, _, _, _) = await harness.syncClient()
            _ = try await sync.syncOnce(filter: SyncFilter(
                room: RoomFilter(timeline: RoomEventFilter(limit: 10)),
                eventFields: ["type", "content"]))
            let syncs = await harness.requests.filter { $0.path == "/_matrix/client/v3/sync" }
            let filter = try #require(syncs.first?.query["filter"])
            #expect(filter.contains("event_fields"))
            #expect(filter.contains("limit"))
        }
    }

    @Test("Unauthenticated sync throws before networking")
    func syncRequiresAuth() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let store = StateStore()
        let sync = SyncClient(
            connection: SyncConnection(transport: transport, session: session),
            store: store, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await sync.syncOnce()
        }
        try? await transport.shutdown()
    }

    struct SyncErrorCase: Sendable {
        var status: Int
        var body: String
        var check: @Sendable (MatrixError) -> Bool
    }

    static let syncErrorCases: [SyncErrorCase] = [
        SyncErrorCase(
            status: 401,
            body: #"{"errcode":"M_UNKNOWN_TOKEN","error":"token dead"}"#,
            check: { $0 == .unknownToken }),
        SyncErrorCase(
            status: 429,
            body: #"{"errcode":"M_LIMIT_EXCEEDED","error":"slow"}"#,
            check: { if case .rateLimited = $0 { return true }; return false }),
        SyncErrorCase(
            status: 400,
            body: #"{"errcode":"M_BAD_JSON","error":"bad"}"#,
            check: { $0 == .serverError(code: "M_BAD_JSON", message: "bad", retryAfter: nil) }),
    ]

    @Test("Sync maps error bodies onto MatrixError", arguments: syncErrorCases)
    func syncErrors(_ c: SyncErrorCase) async throws {
        try await withHarness { harness in
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v3/sync",
                response: .raw(c.body, status: c.status))
            let (sync, _, _, _, _) = await harness.syncClient()
            do {
                _ = try await sync.syncOnce()
                Issue.record("expected throw")
            } catch let error as MatrixError {
                #expect(c.check(error))
            }
        }
    }

    @Test("Start streams deltas until stopped")
    func startStop() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "live")
            let (sync, _, _, _, _) = await harness.syncClient()
            let stream = try await sync.start()
            var seen: [String] = []
            for await delta in stream {
                seen.append(delta.nextBatch.value)
                if seen.count == 2 { break }
            }
            await sync.stop()
            #expect(seen == ["s1", "s2"])
            #expect(await sync.isRunning == false)
        }
    }

    @Test("Fatal token errors end the stream via onError")
    func fatalError() async throws {
        actor ErrorBox {
            var error: MatrixError?
            func set(_ error: MatrixError) { self.error = error }
        }
        actor DoneBox {
            var ended = false
            func finish() { ended = true }
        }
        try await withHarness { harness in
            let (_, connection, _, _, _) = await harness.syncClient()
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v3/sync",
                response: .matrixError(
                    code: "M_UNKNOWN_TOKEN", message: "dead", status: 401))
            let box = ErrorBox()
            let done = DoneBox()
            let stream = await connection.stream(since: nil) { error in
                Task { await box.set(error) }
            }
            Task {
                for await _ in stream { }
                await done.finish()
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while await !done.ended, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(await done.ended)
            #expect(await box.error == .unknownToken)
            await connection.stop()
        }
    }

    @Test("Room display names fall back to members then ID")
    func displayNameFallbacks() async throws {
        try await withHarness { harness in
            let (_, _, store, _, _) = await harness.syncClient()
            let lonely = await store.room(RoomId(unchecked: "!lonely:test"))
            #expect(await lonely.displayName() == "!lonely:test")
            let social = await store.room(RoomId(unchecked: "!social:test"))
            await social.setLocalUser(UserId(unchecked: "@me:test"))
            await social.applyJoined(JoinedRoomDelta(state: [
                MessageEvent(
                    type: "m.room.member",
                    eventId: EventId(unchecked: "$m:test"),
                    sender: UserId(unchecked: "@bob:test"),
                    stateKey: "@bob:test",
                    originServerTs: 1,
                    content: ["membership": .string("join")]),
            ]))
            #expect(await social.displayName() == "@bob:test")
        }
    }
}
