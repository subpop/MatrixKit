import Foundation
import MatrixKit

/// MSC4143 credential exchange: discover the call focus (SFU) for a room
/// and mint a LiveKit access token for this device.
///
/// Discovery order mirrors Element Call:
/// 1. The convergence winner's `focus_active.livekit_service_url` (or the
///    matching `foci_preferred` entry), when the room has live memberships.
/// 2. `GET /_matrix/client/v1/rtc/transports` on the homeserver (falling
///    back to the unstable `org.matrix.msc4143` prefix), which lists the
///    transports the server supports (`rtc_transports`).
/// 3. `GET https://<server>/.well-known/matrix/client` exposing
///    `org.matrix.msc4143.rtc_foci`.
/// Token minting tries the legacy `/sfu/get` endpoint first, then the
/// v2 `/get_token` endpoint (`slot_id: "m.call#<roomId>"`).
public actor CallCredentialService {
    private let client: MatrixClient

    public init(client: MatrixClient) {
        self.client = client
    }

    /// Mint SFU credentials for `roomId`, converging on the winner's
    /// focus when the room already has live memberships. `membership` is
    /// our freshly published membership — the JWT service binds the
    /// LiveKit token to its identity.
    ///
    /// Throws `RTCError` for discovery/exchange failures and
    /// `MatrixError` for transport failures.
    public func credentials(
        roomId: RoomId, membership: CallMembership,
        memberships: [CallMembership]
    ) async throws -> LiveKitCredentials {
        let focus = pickFocus(memberships: memberships)
        let transports = try await sfuTransports(roomId: roomId, focus: focus, memberships: memberships)
        let openID = try await client.auth.openIDToken()
        let request = TokenRequest(
            openIDToken: openID, roomId: roomId,
            member: RTCMemberIdentity(
                id: membership.membershipID,
                claimedUserId: membership.userId.value,
                claimedDeviceId: membership.deviceId))
        // Legacy endpoint first: homeservers that only know MSC4143-v1
        // answer here and would 404 the v2 path.
        var failures: [String] = []
        for base in transports {
            do {
                return try await legacyToken(base: base, request: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("legacy /sfu/get: \(error)")
            }
        }
        for base in transports {
            do {
                return try await v2Token(base: base, request: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("v2 /get_token: \(error)")
            }
        }
        if failures.isEmpty {
            throw RTCError.credentialFailed("SFU at \(transports) minted no token")
        }
        throw RTCError.credentialFailed("SFU at \(transports): \(failures.joined(separator: "; "))")
    }

    // MARK: - Focus discovery

    /// Convergence winner's focus, defaulting to plain LiveKit.
    func pickFocus(memberships: [CallMembership]) -> RTCFocus {
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        if let winner = CallMembership.convergenceWinner(memberships, nowMs: nowMs) {
            return winner.focusActive
        }
        return RTCFocus(type: "livekit")
    }

    /// Resolve SFU base URL(s): the winner's published service URL first,
    /// then the homeserver transports endpoint, then the client
    /// well-known `org.matrix.msc4143.rtc_foci` fallback.
    func sfuTransports(
        roomId: RoomId, focus: RTCFocus, memberships: [CallMembership]
    ) async throws -> [String] {
        if focus.type == "livekit" {
            if let url = membershipServiceURL(focus: focus, memberships: memberships),
                !url.isEmpty { return [url] }
            if let url = await transportsEndpoint(),
                !url.isEmpty { return [url] }
            if let url = await wellKnownSFU(), !url.isEmpty { return [url] }
        }
        throw RTCError.noFocusAvailable
    }

    /// The winner's `focus_active.service_url`, or the matching
    /// `foci_preferred` entry's URL by alias.
    private func membershipServiceURL(
        focus: RTCFocus, memberships: [CallMembership]
    ) -> String? {
        let nowMs = Int(Date.now.timeIntervalSince1970 * 1000)
        guard let winner = CallMembership.convergenceWinner(memberships, nowMs: nowMs) else {
            return nil
        }
        if let url = winner.focusActive.livekitServiceURL { return url }
        return winner.fociPreferred.first(where: {
            $0.livekitAlias == focus.livekitAlias
        })?.livekitServiceURL
    }

    /// Homeserver transports endpoint (MSC4143): stable `v1` path first,
    /// then the unstable prefix. Room-independent; each failed path falls
    /// through to the next instead of aborting discovery.
    private func transportsEndpoint() async -> String? {
        for path in [
            "/_matrix/client/v1/rtc/transports",
            "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports",
        ] {
            if let response: RTCTransportsResponse = try? await client.transport.send(
                .get,
                path: path,
                accessToken: await client.session.accessToken),
                let url = response.livekitServiceURL, !url.isEmpty {
                return url
            }
        }
        return nil
    }

    /// Client well-known fallback: `org.matrix.msc4143.rtc_foci` in
    /// `https://<server>/.well-known/matrix/client`.
    private func wellKnownSFU() async -> String? {
        guard let serverName = await client.session.userId.serverName else { return nil }
        let url = "https://\(serverName)/.well-known/matrix/client"
        guard let (status, data) = try? await client.transport.getData(url: url),
            status == 200,
            let doc = try? JSONDecoder().decode(RTCClientWellKnown.self, from: data),
            let sfu = doc.livekitServiceURL, !sfu.isEmpty
        else { return nil }
        return sfu
    }

    // MARK: - Token minting

    /// Shared inputs for both token endpoints.
    struct TokenRequest {
        var openIDToken: OpenIDToken
        var roomId: RoomId
        var member: RTCMemberIdentity
    }

    private func legacyToken(
        base: String, request: TokenRequest
    ) async throws -> LiveKitCredentials {
        let body = LegacyTokenRequest(
            openIDToken: request.openIDToken, room: request.roomId.value,
            deviceID: request.member.claimedDeviceId)
        let (status, data) = try await client.transport.postJSON(
            url: base + "/sfu/get", body: body)
        guard status == 200 else {
            throw RTCError.credentialFailed(
                "legacy /sfu/get HTTP \(status): \(responsePreview(data))")
        }
        let response = try JSONDecoder().decode(SfuTokenResponse.self, from: data)
        guard let url = URL(string: response.url) else {
            throw RTCError.credentialFailed("legacy /sfu/get returned an unusable URL")
        }
        return LiveKitCredentials(url: url, token: response.jwt)
    }

    private func v2Token(
        base: String, request: TokenRequest
    ) async throws -> LiveKitCredentials {
        let body = V2TokenRequest(
            openIDToken: request.openIDToken, roomID: request.roomId.value,
            slotID: "m.call#\(request.roomId.value)", member: request.member)
        let (status, data) = try await client.transport.postJSON(
            url: base + "/get_token", body: body)
        guard status == 200 else {
            throw RTCError.credentialFailed(
                "v2 /get_token HTTP \(status): \(responsePreview(data))")
        }
        let response = try JSONDecoder().decode(SfuTokenResponse.self, from: data)
        guard let url = URL(string: response.url) else {
            throw RTCError.credentialFailed("v2 /get_token returned an unusable URL")
        }
        return LiveKitCredentials(url: url, token: response.jwt)
    }
}

/// First 200 characters of a failure body, for error messages.
private func responsePreview(_ data: Data) -> String {
    String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
}

/// Member identity the JWT service binds the token to
/// (`member: {id, claimed_user_id, claimed_device_id}` — all required).
struct RTCMemberIdentity: Codable {
    var id: String
    var claimedUserId: String
    var claimedDeviceId: String

    private enum CodingKeys: String, CodingKey {
        case id
        case claimedUserId = "claimed_user_id"
        case claimedDeviceId = "claimed_device_id"
    }
}

/// `POST {sfu}/sfu/get` body (deprecated standalone endpoint, still served).
/// Note the room field is `room`, not `room_id`.
struct LegacyTokenRequest: Encodable {
    var openIDToken: OpenIDToken
    var room: String
    var deviceID: String

    private enum CodingKeys: String, CodingKey {
        case openIDToken = "openid_token"
        case room
        case deviceID = "device_id"
    }
}

/// `POST {sfu}/get_token` body.
struct V2TokenRequest: Encodable {
    var openIDToken: OpenIDToken
    var roomID: String
    var slotID: String
    var member: RTCMemberIdentity

    private enum CodingKeys: String, CodingKey {
        case openIDToken = "openid_token"
        case roomID = "room_id"
        case slotID = "slot_id"
        case member
    }
}

/// Token response shared by both endpoints: `{url, jwt}`.
struct SfuTokenResponse: Decodable {
    var url: String
    var jwt: String
}
