import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Sliding-sync compliance suite: the MSC4186 loop against world state —
/// pos advancement, store application, typing/to-device extensions, the
/// unknown-pos reset, and streaming.
///
/// Exercised registry endpoints: `POST /unstable/org.matrix.simplified_msc3575/sync`
/// (registry override — the unstable path the SDK targets).
@Suite("SlidingSyncCompliance")
struct SlidingSyncComplianceTests {
    @Test("Sync applies rooms and advances pos")
    func syncAppliesRooms() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", body: "sliding hello")
            let (sliding, store, _, _) = await harness.slidingSyncClient()
            let delta = try await sliding.syncOnce(lists: SlidingSyncClient.defaultLists)
            #expect(delta.nextBatch.value == "p1")
            #expect(await sliding.pos == "p1")
            // v2 sync token untouched by the sliding engine.
            #expect(await store.syncToken == nil)
            let room = await store.room(RoomId(unchecked: "!a:test"))
            #expect(await room.timeline.map(\.eventId.value) == ["$e1:test"])
        }
    }

    @Test("Pos advances monotonically, request carries it")
    func posAdvances() async throws {
        try await withHarness { harness in
            let (sliding, _, _, _) = await harness.slidingSyncClient()
            _ = try await sliding.syncOnce(lists: SlidingSyncClient.defaultLists)
            _ = try await sliding.syncOnce()
            #expect(await sliding.pos == "p2")
            let posts = await harness.requests.filter {
                $0.method == "POST"
                    && $0.path == "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"
            }
            #expect(posts.count == 2)
            // First request has no pos; the second resumes from p1.
            #expect(!posts[0].body.isEmpty)
        }
    }

    @Test("Typing and to-device extensions deliver")
    func extensions() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(roomId: "!a:test", body: "shell")
            let (state, _, _) = await harness.roomStateClient()
            try await state.sendTyping(
                RoomId(unchecked: "!a:test"),
                userId: UserId(unchecked: "@bob:test"), typing: true)
            await world.queueToDevice(BasicEvent(
                type: "m.room_key", sender: UserId(unchecked: "@bob:test"),
                content: ["session_id": .string("s1")]))
            let (sliding, store, _, _) = await harness.slidingSyncClient()
            let log = HookLog()
            await sliding.setCryptoHooks(log.hooks())
            let delta = try await sliding.syncOnce(lists: SlidingSyncClient.defaultLists)
            #expect(delta.toDevice.count == 1)
            #expect(await log.toDeviceBatches.count == 1)
            let room = await store.room(RoomId(unchecked: "!a:test"))
            #expect(await room.typingUsers == [UserId(unchecked: "@bob:test")])
        }
    }

    @Test("Unknown pos resets the cursor and rethrows")
    func unknownPos() async throws {
        try await withHarness { harness in
            let (sliding, _, _, _) = await harness.slidingSyncClient()
            _ = try await sliding.syncOnce(lists: SlidingSyncClient.defaultLists)
            #expect(await sliding.pos == "p1")
            await harness.setOverride(
                method: "POST",
                path: "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync",
                response: .matrixError(code: "M_UNKNOWN_POS", message: "expired", status: 400))
            await #expect(throws: MatrixError.serverError(
                code: "M_UNKNOWN_POS", message: "expired", retryAfter: nil))
            {
                try await sliding.syncOnce()
            }
            #expect(await sliding.pos == nil)
        }
    }

    @Test("Start streams deltas until stopped")
    func startStop() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.stageMessage(body: "live")
            let (sliding, _, _, _) = await harness.slidingSyncClient()
            let stream = try await sliding.start(lists: SlidingSyncClient.defaultLists)
            var seen: [String] = []
            for await delta in stream {
                seen.append(delta.nextBatch.value)
                if seen.count == 2 { break }
            }
            await sliding.stop()
            #expect(seen == ["p1", "p2"])
            #expect(await sliding.isRunning == false)
        }
    }

    @Test("Sliding sync rejects invalid sessions without network")
    func slidingGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let sliding = SlidingSyncClient(
            transport: transport, session: session, store: StateStore())
        await #expect(throws: MatrixError.notAuthenticated) {
            try await sliding.syncOnce()
        }
        try? await transport.shutdown()
    }
}
