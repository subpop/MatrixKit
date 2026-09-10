import Foundation
import MatrixKit

/// A joined call: our membership plus the SFU credentials for it.
public struct JoinedCall: Hashable, Sendable {
    public var membership: CallMembership
    public var credentials: LiveKitCredentials
    /// Delayed-event ID for the scheduled leave-on-disconnect, if the
    /// homeserver supports MSC4140.
    public var leaveDelayId: String?

    public init(
        membership: CallMembership, credentials: LiveKitCredentials,
        leaveDelayId: String? = nil
    ) {
        self.membership = membership
        self.credentials = credentials
        self.leaveDelayId = leaveDelayId
    }
}

/// MatrixRTC signaling facade: membership join/refresh/leave, SFU
/// credential exchange, and key distribution — no media. Owns a
/// `CallKeyDistributor`; the app pumps `keys.pumpToDevice()` once per
/// session and refreshes memberships on its own timer (Element Call
/// refreshes well inside the 4-hour expiry).
public actor RTCCallSession {
    private let client: MatrixClient
    public let credentials: CallCredentialService
    public let keys: CallKeyDistributor
    public let delayed: DelayedEvents

    public init(client: MatrixClient) {
        self.client = client
        self.credentials = CallCredentialService(client: client)
        self.keys = CallKeyDistributor(client: client)
        self.delayed = DelayedEvents(client: client)
    }

    // MARK: - Memberships

    /// Live `m.call` memberships from room state.
    public func memberships(roomId: RoomId) async throws -> [CallMembership] {
        let state = try await client.roomState.getState(roomId)
        return state.compactMap { event in
            guard let stateKey = event.stateKey else { return nil }
            return CallMembership.parse(
                type: event.type, stateKey: stateKey,
                sender: event.sender, content: event.content)
        }
    }

    /// Join: publish our membership, schedule leave-on-disconnect, and
    /// mint SFU credentials converging on the oldest live focus.
    public func join(
        roomId: RoomId, fociPreferred: [RTCFocus] = [RTCFocus(type: "livekit")]
    ) async throws -> JoinedCall {
        let userId = await client.session.userId
        let deviceId = await client.session.deviceId
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        let live = (try? await memberships(roomId: roomId)) ?? []
        let focusActive = CallMembership.convergenceWinner(live, nowMs: nowMs)?.focusActive
            ?? fociPreferred.first ?? RTCFocus(type: "livekit")
        let membership = CallMembership(
            membershipID: UUID().uuidString, userId: userId,
            deviceId: deviceId.value, fociPreferred: fociPreferred,
            focusActive: focusActive, createdTs: nowMs,
            expires: nowMs + 4 * 3_600_000)
        try await client.roomState.sendStateEvent(
            roomId, type: rtcMemberEventType,
            stateKey: CallMembership.stateKey(userId: userId, deviceId: deviceId.value),
            content: membership.eventContent(deviceId: deviceId.value))
        let delayId = try? await delayed.scheduleStateEvent(
            roomId: roomId, type: rtcMemberEventType,
            stateKey: CallMembership.stateKey(userId: userId, deviceId: deviceId.value),
            content: [:], delayMs: 60_000)
        let creds = try await credentials.credentials(
            roomId: roomId, membership: membership, memberships: live)
        return JoinedCall(membership: membership, credentials: creds, leaveDelayId: delayId)
    }

    /// Refresh our membership (new expiry, same ID and creation time).
    public func refresh(roomId: RoomId, membership: CallMembership) async throws {
        let deviceId = await client.session.deviceId
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        let refreshed = CallMembership(
            membershipID: membership.membershipID, userId: membership.userId,
            deviceId: membership.deviceId, fociPreferred: membership.fociPreferred,
            focusActive: membership.focusActive, createdTs: membership.createdTs,
            expires: nowMs + 4 * 3_600_000)
        try await client.roomState.sendStateEvent(
            roomId, type: rtcMemberEventType,
            stateKey: CallMembership.stateKey(
                userId: membership.userId, deviceId: membership.deviceId),
            content: refreshed.eventContent(deviceId: deviceId.value))
    }

    /// Leave: clear our membership and cancel the delayed leave.
    public func leave(roomId: RoomId, delayId: String? = nil) async throws {
        let userId = await client.session.userId
        let deviceId = await client.session.deviceId
        if let delayId {
            try? await delayed.cancel(delayId: delayId)
        }
        try await client.roomState.sendStateEvent(
            roomId, type: rtcMemberEventType,
            stateKey: CallMembership.stateKey(userId: userId, deviceId: deviceId.value),
            content: [:])
    }
}
