import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Knock send-side: `KnockRequest`/`KnockResponse` shapes, the distinct
/// `knock_restricted` join rule, `isKnockable` helpers, and the auth guard
/// on `RoomClient.knock` (`POST /knock/{roomIdOrAlias}`).
@Suite("Knock")
struct KnockTests {
    @Test("KnockRequest round-trips with and without a reason", arguments: [
        "Let me in", nil as String?,
    ])
    func knockRequest(reason: String?) throws {
        let decoded: KnockRequest = try roundTrip(KnockRequest(reason: reason))
        #expect(decoded.reason == reason)
    }

    @Test("KnockResponse decodes the resolved room ID")
    func knockResponseDecode() throws {
        let response = try JSONDecoder().decode(
            KnockResponse.self, from: Data(#"{"room_id":"!r:example.com"}"#.utf8))
        #expect(response.roomId == RoomId(unchecked: "!r:example.com"))
    }

    @Test("Join rules parse distinctly", arguments: [
        ("knock_restricted", SpaceChildJoinRule.knockRestricted),
        ("restricted", SpaceChildJoinRule.restricted),
        ("knock", SpaceChildJoinRule.knock),
        ("invite", SpaceChildJoinRule.invite),
    ])
    func joinRuleParse(raw: String, expected: SpaceChildJoinRule) {
        #expect(SpaceChildJoinRule.parse(raw) == expected)
    }

    @Test("isKnockable covers knock rules only", arguments: [
        (SpaceChildJoinRule.knock, true),
        (SpaceChildJoinRule.knockRestricted, true),
        (SpaceChildJoinRule.restricted, false),
        (SpaceChildJoinRule.invite, false),
        (nil as SpaceChildJoinRule?, false),
    ])
    func spaceChildKnockable(rule: SpaceChildJoinRule?, expected: Bool) {
        let roomId = RoomId(unchecked: "!r:example.com")
        #expect(SpaceChild(roomId: roomId, joinRule: rule).isKnockable == expected)
        #expect(RoomDetails(id: roomId, joinRule: rule?.rawValue).isKnockable == expected)
    }

    @Test("Knock path encodes aliases with reserved characters", arguments: [
        (RoomAlias(unchecked: "#general:example.com").pathSegmentEncoded, "%23general%3Aexample.com"),
        (RoomId(unchecked: "!r:example.com").pathSegmentEncoded, "!r%3Aexample.com"),
    ])
    func knockPathEncoding(encoded: String, expected: String) {
        #expect(encoded == expected)
    }

    @Test("knock rejects invalid sessions without network", arguments: [true, false])
    func knockRequiresAuth(useAlias: Bool) async {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let rooms = RoomClient(transport: transport, session: session)
        if useAlias {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.knock(RoomAlias(unchecked: "#general:example.com"))
            }
        } else {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.knock(RoomId(unchecked: "!r:example.com"))
            }
        }
        try? await transport.shutdown()
    }
}
