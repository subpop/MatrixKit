import Foundation
import Testing
import MatrixKit
@testable import MatrixRTC

/// Regression tests for SFU discovery response shapes (MSC4143).
///
/// Relay once queried an obsolete per-room transports path and an
/// unpublished well-known file, so homeservers with a correctly configured
/// SFU reported "no focus available". These tests pin the shapes real
/// servers return: `rtc_transports` on
/// `GET /_matrix/client/v1/rtc/transports` and `org.matrix.msc4143.rtc_foci`
/// in `/.well-known/matrix/client`.
@Suite("FocusDiscovery")
struct FocusDiscoveryTests {
    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("v1 rtc_transports yields the LiveKit service URL")
    func v1Transports() throws {
        let response = try decode(RTCTransportsResponse.self, json: """
            {"rtc_transports": [
              {"type": "livekit", "livekit_service_url": "https://call.example.com/livekit/jwt"}
            ]}
            """)
        #expect(response.livekitServiceURL == "https://call.example.com/livekit/jwt")
    }

    @Test("legacy transports key is tolerated")
    func legacyTransportsKey() throws {
        let response = try decode(RTCTransportsResponse.self, json: """
            {"transports": [
              {"type": "m.livekit.sfu", "livekit_service_url": "https://livekit.example.com"}
            ]}
            """)
        #expect(response.livekitServiceURL == "https://livekit.example.com")
    }

    @Test("non-LiveKit transports are skipped")
    func nonLiveKitSkipped() throws {
        let response = try decode(RTCTransportsResponse.self, json: """
            {"rtc_transports": [
              {"type": "m.widget", "widget_url": "https://widget.example.com"},
              {"type": "livekit", "livekit_service_url": "https://call.example.com/livekit/jwt"}
            ]}
            """)
        #expect(response.livekitServiceURL == "https://call.example.com/livekit/jwt")
    }

    @Test("empty transports yield no URL")
    func emptyTransports() throws {
        let response = try decode(RTCTransportsResponse.self, json: """
            {"rtc_transports": []}
            """)
        #expect(response.livekitServiceURL == nil)
    }

    @Test("client well-known rtc_foci yields the LiveKit service URL")
    func wellKnownFoci() throws {
        let doc = try decode(RTCClientWellKnown.self, json: """
            {"m.homeserver": {"base_url": "https://matrix.example.com"},
             "org.matrix.msc4143.rtc_foci": [
               {"type": "livekit", "livekit_service_url": "https://rtc.example.com/livekit/jwt"}
             ]}
            """)
        #expect(doc.livekitServiceURL == "https://rtc.example.com/livekit/jwt")
    }

    @Test("well-known without foci yields no URL")
    func wellKnownWithoutFoci() throws {
        let doc = try decode(RTCClientWellKnown.self, json: """
            {"m.homeserver": {"base_url": "https://matrix.example.com"}}
            """)
        #expect(doc.livekitServiceURL == nil)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func openID() -> OpenIDToken {
        OpenIDToken(
            accessToken: "tok", tokenType: "Bearer",
            matrixServerName: "example.com", expiresIn: 3600)
    }

    @Test("v2 token request carries the required member identity")
    func v2RequestMember() throws {
        let body = V2TokenRequest(
            openIDToken: openID(), roomID: "!room:example.com",
            slotID: "m.call#!room:example.com",
            member: RTCMemberIdentity(
                id: "member-1", claimedUserId: "@alice:example.com",
                claimedDeviceId: "DEVICE1"))
        let json = try encoded(body)
        #expect(json["room_id"] as? String == "!room:example.com")
        #expect(json["slot_id"] as? String == "m.call#!room:example.com")
        let member = json["member"] as? [String: Any]
        #expect(member?["id"] as? String == "member-1")
        #expect(member?["claimed_user_id"] as? String == "@alice:example.com")
        #expect(member?["claimed_device_id"] as? String == "DEVICE1")
        let token = json["openid_token"] as? [String: Any]
        #expect(token?["access_token"] as? String == "tok")
        #expect(token?["matrix_server_name"] as? String == "example.com")
    }

    @Test("legacy token request uses the room field")
    func legacyRequestRoom() throws {
        let body = LegacyTokenRequest(
            openIDToken: openID(), room: "!room:example.com",
            deviceID: "DEVICE1")
        let json = try encoded(body)
        #expect(json["room"] as? String == "!room:example.com")
        #expect(json["room_id"] == nil)
        #expect(json["device_id"] as? String == "DEVICE1")
    }

    @Test("token response decodes url and jwt")
    func tokenResponse() throws {
        let response = try decode(SfuTokenResponse.self, json: """
            {"url": "wss://livekit.example.com", "jwt": "livekit-jwt"}
            """)
        #expect(response.url == "wss://livekit.example.com")
        #expect(response.jwt == "livekit-jwt")
    }
}
