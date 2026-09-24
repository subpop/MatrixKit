import Foundation
import Testing

@testable import MatrixKit

/// `RoomActor.adoptMember`: the write path backing on-demand profile
/// healing for senders whose `m.room.member` sync omitted under lazy
/// member loading. (The heal orchestration itself is driven by
/// `ObservableRoom`'s update observer, which only progresses on a
/// pumped `MainActor`, so it is covered here at the contract level:
/// adopt publishes `membersChanged`, which is what re-renders the
/// timeline with resolved names and avatars.)
@Suite("Profile healing")
struct ProfileHealingTests {
    @Test("adoptMember stores a previously unknown sender")
    func adoptMemberStoresUnknownSender() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@gray:x")
        await room.adoptMember(
            user,
            content: MemberContent(
                membership: .join, displayname: "Grayshade",
                avatarUrl: "mxc://x/gray"))
        let stored = await room.members[user]
        #expect(stored?.displayname == "Grayshade")
        #expect(stored?.avatarUrl == "mxc://x/gray")
        #expect(stored?.membership == .join)
    }

    @Test("adoptMember keeps sync-known entries authoritative")
    func adoptMemberKeepsSyncEntries() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@a:x")
        await room.adoptMember(
            user, content: MemberContent(membership: .join, displayname: "Healed"))
        await room.adoptMember(
            user, content: MemberContent(membership: .join, displayname: "Other"))
        #expect(await room.members[user]?.displayname == "Healed")
    }

    @Test("adoptMember publishes membersChanged")
    func adoptMemberNotifies() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        var iterator = await room.updates().makeAsyncIterator()
        await room.adoptMember(
            UserId(unchecked: "@gray:x"),
            content: MemberContent(membership: .join, displayname: "Grayshade"))
        #expect(await iterator.next() == .membersChanged)
        #expect(await iterator.next() == .stateChanged)
    }

    @Test("adoptMember of a known sender publishes nothing")
    func adoptMemberKnownSenderSilent() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@a:x")
        await room.adoptMember(
            user, content: MemberContent(membership: .join, displayname: "Healed"))
        var iterator = await room.updates().makeAsyncIterator()
        await room.adoptMember(
            user, content: MemberContent(membership: .join, displayname: "Other"))
        #expect(await room.members[user]?.displayname == "Healed")
        // No notification follows a no-op adopt; the next read is ours.
        await room.adoptMember(
            UserId(unchecked: "@b:x"),
            content: MemberContent(membership: .join, displayname: "Bee"))
        #expect(await iterator.next() == .membersChanged)
    }

    @Test("mergeMemberProfiles adopts unknown users")
    func mergeAdoptsUnknownUsers() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@new:x")
        var iterator = await room.updates().makeAsyncIterator()
        await room.mergeMemberProfiles([
            user: MemberContent(
                membership: .join, displayname: "New",
                avatarUrl: "mxc://x/new")
        ])
        #expect(await room.members[user]?.displayname == "New")
        #expect(await room.members[user]?.avatarUrl == "mxc://x/new")
        #expect(await iterator.next() == .membersChanged)
        #expect(await iterator.next() == .stateChanged)
    }

    @Test("mergeMemberProfiles fills missing fields, keeps membership authoritative")
    func mergeFillsMissingFields() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@a:x")
        await room.adoptMember(
            user,
            content: MemberContent(membership: .join, displayname: "Known"))
        await room.mergeMemberProfiles([
            user: MemberContent(
                membership: .leave, displayname: "Other",
                avatarUrl: "mxc://x/a")
        ])
        let stored = await room.members[user]
        #expect(stored?.membership == .join)
        #expect(stored?.displayname == "Known")
        #expect(stored?.avatarUrl == "mxc://x/a")
    }

    @Test("mergeMemberProfiles with nothing new publishes nothing")
    func mergeNoopIsSilent() async {
        let room = RoomActor(roomId: RoomId(unchecked: "!r:x"))
        let user = UserId(unchecked: "@a:x")
        await room.adoptMember(
            user,
            content: MemberContent(
                membership: .join, displayname: "Known",
                avatarUrl: "mxc://x/a"))
        var iterator = await room.updates().makeAsyncIterator()
        await room.mergeMemberProfiles([
            user: MemberContent(
                membership: .join, displayname: "Known",
                avatarUrl: "mxc://x/a")
        ])
        // No notification follows a no-op merge; the next read is ours.
        await room.adoptMember(
            UserId(unchecked: "@b:x"),
            content: MemberContent(membership: .join, displayname: "Bee"))
        #expect(await iterator.next() == .membersChanged)
    }
}
