import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Batch B of the missing-endpoints gap: public-directory GET, room
/// visibility, upgrades, alias listing, content reporting, push-rule
/// actions, and the SSO redirect URL builder.
@Suite("RoomEndpoints")
struct RoomEndpointsTests {
    struct VisibilityCase: Sendable {
        var json: String
        var expected: RoomVisibility
    }

    @Test("RoomVisibilityResponse decodes visibility", arguments: [
        VisibilityCase(json: #"{"visibility":"private"}"#, expected: .private),
        VisibilityCase(json: #"{"visibility":"public"}"#, expected: .public),
    ])
    func visibilityDecode(_ c: VisibilityCase) throws {
        #expect(try decodeFixture(c.json, as: RoomVisibilityResponse.self).visibility == c.expected)
    }

    @Test("UpgradeRoomResponse decodes the replacement room")
    func upgradeDecode() throws {
        let response: UpgradeRoomResponse = try decodeFixture(#"{"replacement_room":"!new:example.com"}"#)
        #expect(response.replacementRoom == RoomId(unchecked: "!new:example.com"))
    }

    @Test("RoomAliasesResponse decodes aliases")
    func aliasesDecode() throws {
        let response: RoomAliasesResponse = try decodeFixture(
            ##"{"aliases":["#a:example.com","#b:example.com"]}"##)
        #expect(response.aliases == ["#a:example.com", "#b:example.com"])
    }

    @Test("ReportRequest encodes score and reason")
    func reportEncode() throws {
        let data = try JSONEncoder().encode(ReportRequest(score: -50, reason: "spam"))
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(raw["score"]?.intValue == -50)
        #expect(raw["reason"]?.stringValue == "spam")
        let empty = try JSONEncoder().encode(ReportRequest())
        let emptyRaw = try JSONDecoder().decode([String: AnyCodable].self, from: empty)
        #expect(emptyRaw.isEmpty)
    }

    @Test("RuleActionsResponse decodes rule actions")
    func ruleActionsDecode() throws {
        let response: RuleActionsResponse = try decodeFixture(
            #"{"actions":["notify",{"set_tweak":"sound","value":"default"},{"set_tweak":"highlight"}]}"#)
        #expect(response.actions.count == 3)
        #expect(response.actions[0] == .notify)
        #expect(response.actions[1] == .sound("default"))
        #expect(response.actions[2] == .highlight(nil))
    }

    @Test("SSO redirect URL builds from the session homeserver", arguments: [
        (nil as String?, "https://example.com/_matrix/client/v3/login/sso/redirect?redirectUrl=myapp%3A%2F%2Fcallback"),
        ("oidc-idp", "https://example.com/_matrix/client/v3/login/sso/redirect/oidc-idp?redirectUrl=myapp%3A%2F%2Fcallback"),
    ])
    func ssoRedirectURL(providerId: String?, expected: String) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let auth = AuthClient(transport: transport, session: session)
        #expect(await auth.ssoRedirectURL(redirectURL: "myapp://callback", providerId: providerId)?.absoluteString == expected)
        try? await transport.shutdown()
    }

    /// Auth-guarded operations callable with no credentials. Every row
    /// must throw `.notAuthenticated` before any request leaves the SDK.
    enum GuardedCall: String, Sendable, CaseIterable {
        case publicRooms
        case aliases
        case roomVisibility
        case setRoomVisibility
        case upgrade
        case report
        case pushRuleActions
    }

    @Test("Room endpoints reject invalid sessions without network", arguments: GuardedCall.allCases)
    func roomRequiresAuth(_ call: GuardedCall) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let rooms = RoomClient(transport: transport, session: session)
        let push = PushClient(transport: transport, session: session)
        let roomId = RoomId(unchecked: "!r:example.com")
        switch call {
        case .publicRooms:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.publicRoomsGet(limit: 10) }
        case .aliases:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.aliases(roomId) }
        case .roomVisibility:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.roomVisibility(roomId) }
        case .setRoomVisibility:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.setRoomVisibility(roomId, visibility: .public)
            }
        case .upgrade:
            await #expect(throws: MatrixError.notAuthenticated) { try await rooms.upgrade(roomId, newVersion: "11") }
        case .report:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await rooms.report(EventId(unchecked: "$e:example.com"), in: roomId)
            }
        case .pushRuleActions:
            await #expect(throws: MatrixError.notAuthenticated) {
                try await push.getPushRuleActions(kind: "override", ruleId: ".m.rule.master")
            }
        }
        try? await transport.shutdown()
    }
}
