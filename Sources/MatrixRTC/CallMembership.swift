import Foundation
import MatrixKit

/// One device's `m.call.member` membership (MSC3401 / Element Call).
///
/// State key: `_<userId>_<deviceId>_m.call`. `created_ts` marks when the
/// membership was established; the oldest live membership's
/// `focus_active` wins SFU convergence. `expires` bounds staleness
/// (Element Call uses 4 hours with periodic refreshes).
public struct CallMembership: Hashable, Sendable {
    /// Server-assigned membership UUID (`membershipID` in content).
    public var membershipID: String
    /// Owning user.
    public var userId: UserId
    /// Claimed device ID (from the state key).
    public var deviceId: String
    /// Foci this device can use, in preference order.
    public var fociPreferred: [RTCFocus]
    /// The focus currently in use.
    public var focusActive: RTCFocus
    /// When the membership was created (milliseconds since epoch).
    public var createdTs: Int
    /// When the membership expires without refresh (milliseconds).
    public var expires: Int

    public init(
        membershipID: String, userId: UserId, deviceId: String,
        fociPreferred: [RTCFocus], focusActive: RTCFocus,
        createdTs: Int, expires: Int
    ) {
        self.membershipID = membershipID
        self.userId = userId
        self.deviceId = deviceId
        self.fociPreferred = fociPreferred
        self.focusActive = focusActive
        self.createdTs = createdTs
        self.expires = expires
    }

    /// State key for a device's membership event.
    public static func stateKey(userId: UserId, deviceId: String) -> String {
        "_\(userId.value)_\(deviceId)_m.call"
    }

    /// Whether this membership belongs to the `m.call` application.
    /// Lenient: `application` arrives as `"m.call"` or
    /// `{"type": "m.call"}` depending on the sender.
    public static func isCallApplication(_ content: [String: AnyCodable]) -> Bool {
        if content["application"]?.stringValue == rtcApplicationID { return true }
        return content["application"]?.objectValue?["type"]?.stringValue == rtcApplicationID
    }

    /// Parse a membership from room state. Returns `nil` for empty
    /// (leave) content, non-`m.call` applications, or malformed events.
    public static func parse(
        type: String, stateKey: String, sender: UserId,
        content: [String: AnyCodable]
    ) -> CallMembership? {
        guard type == rtcMemberEventType, !content.isEmpty,
            isCallApplication(content),
            let membershipID = content["membershipID"]?.stringValue,
            let deviceId = content["device_id"]?.stringValue,
            let activeValue = content["focus_active"]?.objectValue,
            let activeType = activeValue["type"]?.stringValue,
            let createdTs = content["created_ts"]?.intValue
        else { return nil }
        _ = stateKey
        _ = sender
        let fociPreferred = content["foci_preferred"]?.arrayValue?
            .compactMap { $0.objectValue }
            .compactMap { obj -> RTCFocus? in
                guard let type = obj["type"]?.stringValue else { return nil }
                return RTCFocus(
                    type: type,
                    livekitAlias: obj["livekit_alias"]?.stringValue
                        ?? obj["focus_alias"]?.stringValue,
                    livekitServiceURL: obj["livekit_service_url"]?.stringValue)
            } ?? []
        let focusActive = RTCFocus(
            type: activeType,
            livekitAlias: activeValue["livekit_alias"]?.stringValue
                ?? activeValue["focus_alias"]?.stringValue,
            livekitServiceURL: activeValue["livekit_service_url"]?.stringValue)
        return CallMembership(
            membershipID: membershipID, userId: sender, deviceId: deviceId,
            fociPreferred: fociPreferred, focusActive: focusActive,
            createdTs: createdTs,
            expires: content["expires"]?.intValue ?? (createdTs + 4 * 3_600_000))
    }

    /// Serialize a join/refresh membership body.
    public func eventContent(deviceId: String) -> [String: AnyCodable] {
        var foci: [AnyCodable] = fociPreferred.map {
            var obj: [String: AnyCodable] = ["type": .string($0.type)]
            if let alias = $0.livekitAlias { obj["livekit_alias"] = .string(alias) }
            if let url = $0.livekitServiceURL { obj["livekit_service_url"] = .string(url) }
            return .object(obj)
        }
        // Element Call echoes the active focus in the preferred list.
        var activeObj: [String: AnyCodable] = ["type": .string(focusActive.type)]
        if let alias = focusActive.livekitAlias { activeObj["livekit_alias"] = .string(alias) }
        if let url = focusActive.livekitServiceURL {
            activeObj["livekit_service_url"] = .string(url)
        }
        foci.append(.object(activeObj))
        return [
            "application": .string(rtcApplicationID),
            "call_id": .string(""),
            "scope": .string("m.room"),
            "device_id": .string(deviceId),
            "membershipID": .string(membershipID),
            "foci_preferred": .array(foci),
            "focus_active": .object(activeObj),
            "created_ts": .int(createdTs),
            "expires": .int(expires),
        ]
    }

    /// Whether the membership has expired as of `nowMs`.
    public func isExpired(nowMs: Int) -> Bool { nowMs >= expires }

    /// Pick the convergence winner: oldest live `m.call` membership.
    public static func convergenceWinner(
        _ memberships: [CallMembership], nowMs: Int
    ) -> CallMembership? {
        memberships.filter { !$0.isExpired(nowMs: nowMs) }
            .min(by: { $0.createdTs < $1.createdTs })
    }
}
