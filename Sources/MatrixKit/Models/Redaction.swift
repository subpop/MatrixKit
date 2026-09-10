/// Client-side redaction pruning (spec §7.9 "Redactions").
import Foundation

/// Prunes redacted event content to the protocol-required key keep-lists
/// (room versions 11/12 — v12's redaction section is word-for-word
/// identical to v11's).
///
/// Servers strip a redacted event's content and re-attach the redaction
/// under `unsigned.redacted_because` when serving it. `RoomActor` applies
/// this to locally stored redaction targets so bodies, media references,
/// and display names don't linger in memory or the on-disk snapshot while
/// waiting for a server re-delivery. Unsigned metadata (notably the
/// `redacted_because` stamp) is owned by the caller and left untouched.
public enum EventRedactor {
    /// Prune `content` to the keys the redaction algorithm preserves for
    /// `type`. Message-like, encrypted, and unknown types keep nothing.
    public static func prunedContent(
        type: String, content: [String: AnyCodable]
    ) -> [String: AnyCodable] {
        switch EventType(rawValue: type) {
        case .roomMember:
            var kept: [String: AnyCodable] = [:]
            if let membership = content["membership"] {
                kept["membership"] = membership
            }
            if let via = content["join_authorised_via_users_server"] {
                kept["join_authorised_via_users_server"] = via
            }
            if let signed = content["third_party_invite"]?.objectValue?["signed"] {
                kept["third_party_invite"] = .object(["signed": signed])
            }
            return kept
        case .roomCreate:
            return content
        case .roomJoinRules:
            return content.filter { $0.key == "join_rule" || $0.key == "allow" }
        case .roomPowerLevels:
            return content.filter { Self.powerLevelKeys.contains($0.key) }
        case .roomHistoryVisibility:
            return content.filter { $0.key == "history_visibility" }
        case .redaction:
            return content.filter { $0.key == "redacts" }
        default:
            return [:]
        }
    }

    private static let powerLevelKeys: Set<String> = [
        "ban", "events", "events_default", "invite", "kick",
        "redact", "state_default", "users", "users_default",
    ]
}
