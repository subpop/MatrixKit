import Foundation
import Testing

@testable import MatrixKit

/// Knock send-side: `KnockRequest`/`KnockResponse` shapes, the distinct
/// `knock_restricted` join rule, `isKnockable` helpers, and the auth guard
/// on `RoomClient.knock` (`POST /knock/{roomIdOrAlias}`).
@Suite("Knock")
struct KnockTests {
    @Test("KnockRequest encodes a reason")
    func knockRequestWithReason() throws {
        let data = try JSONEncoder().encode(KnockRequest(reason: "Let me in"))
        let decoded = try JSONDecoder().decode(KnockRequest.self, from: data)
        #expect(decoded.reason == "Let me in")
    }

    @Test("KnockRequest encodes empty for a plain knock")
    func knockRequestWithoutReason() throws {
        let data = try JSONEncoder().encode(KnockRequest())
        let decoded = try JSONDecoder().decode(KnockRequest.self, from: data)
        #expect(decoded.reason == nil)
    }

    @Test("KnockResponse decodes the resolved room ID")
    func knockResponseDecode() throws {
        let response = try JSONDecoder().decode(
            KnockResponse.self, from: Data(#"{"room_id":"!r:example.com"}"#.utf8))
        #expect(response.roomId == RoomId(unchecked: "!r:example.com"))
    }

    @Test("knock_restricted parses distinctly from restricted")
    func knockRestrictedDistinct() {
        #expect(SpaceChildJoinRule.parse("knock_restricted") == .knockRestricted)
        #expect(SpaceChildJoinRule.parse("restricted") == .restricted)
        #expect(SpaceChildJoinRule.knockRestricted.rawValue == "knock_restricted")
    }

    @Test("SpaceChild isKnockable covers knock rules only")
    func spaceChildKnockable() {
        let base = SpaceChild(roomId: RoomId(unchecked: "!r:example.com"))
        #expect(SpaceChild(roomId: base.roomId, joinRule: .knock).isKnockable)
        #expect(SpaceChild(roomId: base.roomId, joinRule: .knockRestricted).isKnockable)
        #expect(!SpaceChild(roomId: base.roomId, joinRule: .restricted).isKnockable)
        #expect(!SpaceChild(roomId: base.roomId, joinRule: .invite).isKnockable)
        #expect(!base.isKnockable)
    }

    @Test("RoomDetails isKnockable covers knock rules only")
    func roomDetailsKnockable() {
        let id = RoomId(unchecked: "!r:example.com")
        #expect(RoomDetails(id: id, joinRule: "knock").isKnockable)
        #expect(RoomDetails(id: id, joinRule: "knock_restricted").isKnockable)
        #expect(!RoomDetails(id: id, joinRule: "invite").isKnockable)
        #expect(!RoomDetails(id: id).isKnockable)
    }

    @Test("Knock path encodes aliases with reserved characters")
    func knockPathEncoding() {
        #expect(
            RoomAlias(unchecked: "#general:example.com").pathSegmentEncoded
                == "%23general%3Aexample.com")
        #expect(
            RoomId(unchecked: "!r:example.com").pathSegmentEncoded
                == "!r%3Aexample.com")
    }

    @Test("knock rejects invalid sessions without network")
    func knockRequiresAuth() async {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let rooms = RoomClient(transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.knock(RoomId(unchecked: "!r:example.com"))
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.knock(RoomAlias(unchecked: "#general:example.com"))
        }
        try? await transport.shutdown()
    }
}
