import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// `TypingTracker`: ephemeral folding, local-user exclusion, expiry,
/// and touched-room reporting.
@Suite("TypingTracker")
struct TypingTrackerTests {
    private func typing(
        _ users: [String], room: String = "!room:test"
    ) -> SyncDelta {
        SyncDelta(
            nextBatch: "s1",
            joined: [RoomId(unchecked: room): JoinedRoomDelta(ephemeral: [
                BasicEvent(
                    type: "m.typing",
                    content: ["user_ids": .array(users.map(AnyCodable.string))])
            ])])
    }

    @Test("Update lists typers and reports the room")
    func update() async {
        let tracker = TypingTracker(localUser: UserId(unchecked: "@me:test"))
        let touched = await tracker.update(
            from: typing(["@alice:test", "@bob:test"]))
        #expect(touched == [RoomId(unchecked: "!room:test")])
        let users = await tracker.users(in: RoomId(unchecked: "!room:test"))
        #expect(Set(users.map(\.value)) == ["@alice:test", "@bob:test"])
    }

    @Test("Local user never lists themselves")
    func excludesLocalUser() async {
        let tracker = TypingTracker(localUser: UserId(unchecked: "@me:test"))
        _ = await tracker.update(from: typing(["@me:test", "@alice:test"]))
        let users = await tracker.users(in: RoomId(unchecked: "!room:test"))
        #expect(users.map(\.value) == ["@alice:test"])
    }

    @Test("Later events replace the entry wholesale")
    func replaces() async {
        let tracker = TypingTracker()
        _ = await tracker.update(from: typing(["@alice:test", "@bob:test"]))
        _ = await tracker.update(from: typing(["@carol:test"]))
        let users = await tracker.users(in: RoomId(unchecked: "!room:test"))
        #expect(users.map(\.value) == ["@carol:test"])
    }

    @Test("Entries expire")
    func expiry() async {
        let tracker = TypingTracker(expiry: 0.05)
        _ = await tracker.update(from: typing(["@alice:test"]))
        #expect(await tracker.users(in: RoomId(unchecked: "!room:test")).count == 1)
        await waitUntil("typing expiry") {
            await tracker.users(in: RoomId(unchecked: "!room:test")).isEmpty
        }
    }

    @Test("Deltas without typing touch nothing")
    func untouched() async {
        let tracker = TypingTracker()
        let touched = await tracker.update(
            from: SyncDelta(nextBatch: "s1"))
        #expect(touched.isEmpty)
    }
}
