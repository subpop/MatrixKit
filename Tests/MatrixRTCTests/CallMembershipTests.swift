import Foundation
import Testing
import MatrixKit
@testable import MatrixRTC

@Suite("CallMembership")
struct CallMembershipTests {
    private func content(
        membershipID: String = "member-uuid-1",
        deviceId: String = "DEVICE1",
        createdTs: Int = 1_000_000,
        expires: Int = 1_000_000 + 4 * 3_600_000,
        application: AnyCodable = .string("m.call")
    ) -> [String: AnyCodable] {
        [
            "application": application,
            "call_id": .string(""),
            "scope": .string("m.room"),
            "device_id": .string(deviceId),
            "membershipID": .string(membershipID),
            "foci_preferred": .array([
                .object([
                    "type": .string("livekit"),
                    "livekit_alias": .string("de"),
                    "livekit_service_url": .string("https://livekit.example.com"),
                ])
            ]),
            "focus_active": .object([
                "type": .string("livekit"),
                "livekit_alias": .string("de"),
            ]),
            "created_ts": .int(createdTs),
            "expires": .int(expires),
        ]
    }

    @Test("Parses a live membership")
    func parses() throws {
        let sender = try UserId("@alice:example.com")
        let m = CallMembership.parse(
            type: rtcMemberEventType, stateKey: "_@alice:example.com_DEVICE1_m.call",
            sender: sender, content: content())
        #expect(m?.membershipID == "member-uuid-1")
        #expect(m?.deviceId == "DEVICE1")
        #expect(m?.focusActive.type == "livekit")
        #expect(m?.focusActive.livekitAlias == "de")
        #expect(m?.fociPreferred.first?.livekitServiceURL == "https://livekit.example.com")
    }

    @Test("Rejects leave (empty) content and foreign applications")
    func rejects() throws {
        let sender = try UserId("@alice:example.com")
        #expect(CallMembership.parse(
            type: rtcMemberEventType, stateKey: "k", sender: sender, content: [:]) == nil)
        #expect(CallMembership.parse(
            type: rtcMemberEventType, stateKey: "k", sender: sender,
            content: content(application: .string("m.voip"))) == nil)
        #expect(CallMembership.parse(
            type: "m.room.member", stateKey: "k", sender: sender,
            content: content()) == nil)
    }

    @Test("Accepts nested application form")
    func nestedApplication() throws {
        let sender = try UserId("@alice:example.com")
        let m = CallMembership.parse(
            type: rtcMemberEventType, stateKey: "k", sender: sender,
            content: content(application: .object(["type": .string("m.call")])))
        #expect(m != nil)
    }

    @Test("Serializes a join body that re-parses")
    func roundTrip() throws {
        let sender = try UserId("@alice:example.com")
        let original = CallMembership(
            membershipID: "uuid-9", userId: sender, deviceId: "DEV9",
            fociPreferred: [RTCFocus(type: "livekit", livekitAlias: "us")],
            focusActive: RTCFocus(type: "livekit", livekitAlias: "us"),
            createdTs: 2_000_000, expires: 2_000_000 + 4 * 3_600_000)
        let body = original.eventContent(deviceId: "DEV9")
        let parsed = CallMembership.parse(
            type: rtcMemberEventType, stateKey: "k", sender: sender, content: body)
        #expect(parsed?.membershipID == original.membershipID)
        #expect(parsed?.userId == original.userId)
        #expect(parsed?.deviceId == original.deviceId)
        #expect(parsed?.focusActive == original.focusActive)
        #expect(parsed?.createdTs == original.createdTs)
        #expect(parsed?.expires == original.expires)
        // The serializer echoes the active focus into foci_preferred
        // (Element Call behavior), so the parsed list has one extra entry.
        #expect(parsed?.fociPreferred == original.fociPreferred + [original.focusActive])
    }

    @Test("Convergence picks the oldest live membership")
    func convergence() throws {
        let alice = try UserId("@alice:example.com")
        let bob = try UserId("@bob:example.com")
        func member(_ id: String, user: UserId, ts: Int) -> CallMembership {
            CallMembership(
                membershipID: id, userId: user, deviceId: "D",
                fociPreferred: [], focusActive: RTCFocus(type: "livekit"),
                createdTs: ts, expires: ts + 4 * 3_600_000)
        }
        let old = member("old", user: alice, ts: 1_000)
        let new = member("new", user: bob, ts: 2_000)
        #expect(CallMembership.convergenceWinner([new, old], nowMs: 3_000)?.membershipID == "old")
        // Expired memberships never win.
        #expect(CallMembership.convergenceWinner([old], nowMs: 1_000 + 4 * 3_600_000 + 1) == nil)
    }

    @Test("State key format")
    func stateKey() throws {
        let user = try UserId("@alice:example.com")
        #expect(CallMembership.stateKey(userId: user, deviceId: "DEV") == "_@alice:example.com_DEV_m.call")
    }
}

@Suite("CallKeyDistributor identity")
struct CallKeyIdentityTests {
    @Test("LiveKit identity matches the Element Call derivation")
    func identityVector() {
        // SHA-256 over compact JSON ["@alice:example.com","DEVICE1","member-uuid-1"],
        // base64 without padding.
        #expect(CallKeyDistributor.liveKitIdentity(
            matrixID: "@alice:example.com", claimedDeviceID: "DEVICE1",
            memberID: "member-uuid-1") == "HD88zBAL8A1CzZ2Ddob+Kj1S5uXsvb16Nj8P5Z3Uvjg")
    }

    @Test("Legacy identity is mxid colon device")
    func legacy() {
        #expect(CallKeyDistributor.legacyIdentity(
            matrixID: "@alice:example.com", deviceID: "DEV") == "@alice:example.com:DEV")
    }

    @Test("Generated keys are 16 bytes")
    func keySize() {
        #expect(CallKeyDistributor.generateKey().count == 16)
    }
}
