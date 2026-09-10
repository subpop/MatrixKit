import Foundation
import MatrixKit

/// Shared MatrixRTC wire constants and models (MSC3401 / MSC4143).
///
/// Signaling only: membership state events, key distribution, and SFU
/// credential exchange. Media transport (LiveKit) lives app-side.

/// State event carrying one device's call membership.
public let rtcMemberEventType = "org.matrix.msc3401.call.member"
/// To-device event carrying call encryption keys.
public let rtcEncryptionKeysEventType = "io.element.call.encryption_keys"
/// Application identifier for Element Call sessions.
public let rtcApplicationID = "m.call"

/// A LiveKit focus a participant may publish in their membership.
public struct RTCFocus: Hashable, Sendable, Codable {
    /// Focus type (e.g. `"livekit"`).
    public var type: String
    /// SFU alias for this focus (`livekit_alias`, e.g. `"de"`).
    public var livekitAlias: String?
    /// Direct SFU URL published in `foci_preferred`, when present.
    public var livekitServiceURL: String?

    public init(type: String, livekitAlias: String? = nil, livekitServiceURL: String? = nil) {
        self.type = type
        self.livekitAlias = livekitAlias
        self.livekitServiceURL = livekitServiceURL
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case livekitAlias = "livekit_alias"
        case livekitServiceURL = "livekit_service_url"
    }
}

/// SFU credentials minted for one participant (MSC4143).
public struct LiveKitCredentials: Hashable, Sendable {
    /// LiveKit server URL (`wss://…`).
    public var url: URL
    /// LiveKit access token (JWT) for this participant.
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }
}

/// Errors thrown by MatrixRTC signaling.
public enum RTCError: Error, Sendable, Hashable {
    /// No usable SFU was discovered (no `m.call.transports` state and no
    /// well-known fallback, or every candidate failed).
    case noFocusAvailable
    /// Credential exchange with the SFU failed.
    case credentialFailed(String)
    /// Encryption is required but no key could be established.
    case keyExchangeFailed(String)
}

extension RTCError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noFocusAvailable: return "No call focus (SFU) is available for this room"
        case .credentialFailed(let msg): return "Call credential exchange failed: \(msg)"
        case .keyExchangeFailed(let msg): return "Call key exchange failed: \(msg)"
        }
    }
}

extension RTCError: LocalizedError {
    public var errorDescription: String? { description }
}

/// `GET /_matrix/client/v1/rtc/transports` response (MSC4143).
///
/// Synapse answers `{ "rtc_transports": [{ "type": "livekit",
/// "livekit_service_url": "https://…" }] }`. The pre-stable `transports`
/// key is accepted for tolerance.
struct RTCTransportsResponse: Decodable {
    var rtcTransports: [TransportEntry]?
    var transports: [TransportEntry]?

    struct TransportEntry: Decodable {
        var type: String?
        var livekitServiceUrl: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case livekitServiceUrl = "livekit_service_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rtcTransports = "rtc_transports"
        case transports
    }

    /// First usable LiveKit service URL, if any.
    var livekitServiceURL: String? {
        ((rtcTransports ?? []) + (transports ?? [])).first(where: {
            $0.type == "livekit" || $0.type == "m.livekit.sfu"
                || ($0.type?.hasPrefix("m.livekit.sfu.") ?? false)
        })?.livekitServiceUrl
    }
}

/// `/.well-known/matrix/client` fragment carrying
/// `org.matrix.msc4143.rtc_foci` (MSC4143).
struct RTCClientWellKnown: Decodable {
    var rtcFoci: [FocusEntry]?

    struct FocusEntry: Decodable {
        var type: String?
        var livekitServiceUrl: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case livekitServiceUrl = "livekit_service_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rtcFoci = "org.matrix.msc4143.rtc_foci"
    }

    /// First usable LiveKit service URL, if any.
    var livekitServiceURL: String? {
        rtcFoci?.first(where: {
            $0.type == "livekit" || $0.type == "m.livekit.sfu"
                || ($0.type?.hasPrefix("m.livekit.sfu.") ?? false)
        })?.livekitServiceUrl
    }
}
