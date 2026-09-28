import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Profile compliance suite: display names, avatars, presence, and
/// user-directory search against world state.
///
/// Exercised registry endpoints: `GET|PUT /profile/{userId}[/{displayname,avatar_url}]`,
/// `GET|PUT /presence/{userId}/status`, `POST /user_directory/search`.
@Suite("ProfileCompliance")
struct ProfileComplianceTests {
    @Test("Display name and avatar round-trip")
    func nameAndAvatar() async throws {
        try await withHarness { harness in
            let (profile, _, _) = await harness.profileClient()
            let alice = UserId(unchecked: "@alice:test")
            // Seeded profile.
            #expect(try await profile.getDisplayName(alice) == "Alice")
            let full = try await profile.getProfile(alice)
            #expect(full.displayname == "Alice")
            // Write then read.
            try await profile.setDisplayName(alice, name: "Alice Liddell")
            #expect(try await profile.getDisplayName(alice) == "Alice Liddell")
            #expect(try await profile.getAvatarURL(alice) == nil)
            try await profile.setAvatarURL(alice, url: try MXCURI("mxc://test/pic"))
            #expect(try await profile.getAvatarURL(alice)?.value == "mxc://test/pic")
        }
    }

    @Test("Presence sets and reads states", arguments: [Presence.online, .offline, .unavailable])
    func presence(_ state: Presence) async throws {
        try await withHarness { harness in
            let (profile, _, _) = await harness.profileClient()
            let alice = UserId(unchecked: "@alice:test")
            #expect(try await profile.presence(alice).presence == .offline)
            try await profile.setPresence(alice, presence: state, statusMessage: "here")
            let updated = try await profile.presence(alice)
            #expect(updated.presence == state)
            #expect(updated.statusMessage == "here")
        }
    }

    @Test("Directory search matches, misses, and limits")
    func directorySearch() async throws {
        try await withHarness { harness in
            let (profile, _, _) = await harness.profileClient()
            try await profile.setDisplayName(UserId(unchecked: "@bob:test"), name: "Bob")
            let (hit, limited) = try await profile.searchUsers(query: "bob")
            #expect(hit.map(\.userId) == [UserId(unchecked: "@bob:test")])
            #expect(hit.first?.displayName == "Bob")
            #expect(!limited)
            let (miss, _) = try await profile.searchUsers(query: "no-such-user-xyz")
            #expect(miss.isEmpty)
            let (_, truncated) = try await profile.searchUsers(query: "test", limit: 1)
            #expect(truncated)
        }
    }

    @Test("Profile calls reject invalid sessions without network", arguments: [true, false])
    func profileGuards(reading: Bool) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let profile = ProfileClient(transport: transport, session: session)
        let userId = UserId(unchecked: "@a:b")
        if reading {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await profile.getProfile(userId)
            }
        } else {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await profile.setDisplayName(userId, name: "X")
            }
        }
        try? await transport.shutdown()
    }
}
