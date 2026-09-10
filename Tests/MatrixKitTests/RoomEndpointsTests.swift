import Foundation
import Testing

@testable import MatrixKit

/// Batch B of the missing-endpoints gap: public-directory GET, room
/// visibility, upgrades, alias listing, content reporting, push-rule
/// actions, and the SSO redirect URL builder.
@Suite("RoomEndpoints")
struct RoomEndpointsTests {
    private func makeUnauthenticated() -> (
        rooms: RoomClient, push: PushClient, auth: AuthClient, transport: MatrixTransport
    ) {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        return (
            RoomClient(transport: transport, session: session),
            PushClient(transport: transport, session: session),
            AuthClient(transport: transport, session: session),
            transport)
    }

    @Test("RoomVisibilityResponse decodes visibility")
    func visibilityDecode() throws {
        let response = try JSONDecoder().decode(
            RoomVisibilityResponse.self,
            from: Data(#"{"visibility":"private"}"#.utf8))
        #expect(response.visibility == .private)
    }

    @Test("UpgradeRoomResponse decodes the replacement room")
    func upgradeDecode() throws {
        let response = try JSONDecoder().decode(
            UpgradeRoomResponse.self,
            from: Data(#"{"replacement_room":"!new:example.com"}"#.utf8))
        #expect(response.replacementRoom == RoomId(unchecked: "!new:example.com"))
    }

    @Test("RoomAliasesResponse decodes aliases")
    func aliasesDecode() throws {
        let response = try JSONDecoder().decode(
            RoomAliasesResponse.self,
            from: Data(##"{"aliases":["#a:example.com","#b:example.com"]}"##.utf8))
        #expect(response.aliases == ["#a:example.com", "#b:example.com"])
    }

    @Test("ReportRequest encodes score and reason")
    func reportEncode() throws {
        let data = try JSONEncoder().encode(
            ReportRequest(score: -50, reason: "spam"))
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(raw["score"]?.intValue == -50)
        #expect(raw["reason"]?.stringValue == "spam")
        let empty = try JSONEncoder().encode(ReportRequest())
        let emptyRaw = try JSONDecoder().decode([String: AnyCodable].self, from: empty)
        #expect(emptyRaw.isEmpty)
    }

    @Test("RuleActionsResponse decodes rule actions")
    func ruleActionsDecode() throws {
        let response = try JSONDecoder().decode(
            RuleActionsResponse.self,
            from: Data(
                #"{"actions":["notify",{"set_tweak":"sound","value":"default"},{"set_tweak":"highlight"}]}"#
                    .utf8))
        #expect(response.actions.count == 3)
        #expect(response.actions[0] == .notify)
        #expect(response.actions[1] == .sound("default"))
        #expect(response.actions[2] == .highlight(nil))
    }

    @Test("SSO redirect URL builds from the session homeserver")
    func ssoRedirectURL() async {
        let (_, _, auth, transport) = makeUnauthenticated()
        let plain = await auth.ssoRedirectURL(redirectURL: "myapp://callback")
        #expect(
            plain?.absoluteString
                == "https://example.com/_matrix/client/v3/login/sso/redirect?redirectUrl=myapp%3A%2F%2Fcallback"
        )
        let withProvider = await auth.ssoRedirectURL(
            redirectURL: "myapp://callback", providerId: "oidc-idp")
        #expect(
            withProvider?.absoluteString
                == "https://example.com/_matrix/client/v3/login/sso/redirect/oidc-idp?redirectUrl=myapp%3A%2F%2Fcallback"
        )
        try? await transport.shutdown()
    }

    @Test("Room endpoints reject invalid sessions without network")
    func roomRequiresAuth() async {
        let (rooms, push, _, transport) = makeUnauthenticated()
        let roomId = RoomId(unchecked: "!r:example.com")
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.publicRoomsGet(limit: 10)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.aliases(roomId)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.roomVisibility(roomId)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.setRoomVisibility(roomId, visibility: .public)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.upgrade(roomId, newVersion: "11")
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await rooms.report(EventId(unchecked: "$e:example.com"), in: roomId)
        }
        await #expect(throws: MatrixError.notAuthenticated) {
            try await push.getPushRuleActions(kind: "override", ruleId: ".m.rule.master")
        }
        try? await transport.shutdown()
    }
}
