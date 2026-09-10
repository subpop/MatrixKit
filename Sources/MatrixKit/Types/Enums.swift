/// Matrix protocol enumerations.

/// Room membership states (`m.room.member` `membership` field).
public enum Membership: String, Hashable, Sendable, Codable {
    case invite
    case join
    case knock
    case leave
    case ban
}

/// Well-known Matrix event types. Unknown types decode as `.unknown`.
public enum EventType: Hashable, Sendable {
    case roomCreate
    case roomMember
    case roomMessage
    case roomName
    case roomTopic
    case roomAvatar
    case roomPowerLevels
    case roomEncryption
    case roomTombstone
    case roomCanonicalAlias
    case roomPinnedEvents
    case roomJoinRules
    case roomHistoryVisibility
    case roomServerACL
    case reaction
    case redaction
    case sticker
    case pollStart
    case callMember
    case typing
    case receipt
    case presence
    case fullyRead
    case tag
    case custom(String)
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .roomCreate: return "m.room.create"
        case .roomMember: return "m.room.member"
        case .roomMessage: return "m.room.message"
        case .roomName: return "m.room.name"
        case .roomTopic: return "m.room.topic"
        case .roomAvatar: return "m.room.avatar"
        case .roomPowerLevels: return "m.room.power_levels"
        case .roomEncryption: return "m.room.encryption"
        case .roomTombstone: return "m.room.tombstone"
        case .roomCanonicalAlias: return "m.room.canonical_alias"
        case .roomPinnedEvents: return "m.room.pinned_events"
        case .roomJoinRules: return "m.room.join_rules"
        case .roomHistoryVisibility: return "m.room.history_visibility"
        case .roomServerACL: return "m.room.server_acl"
        case .reaction: return "m.reaction"
        case .redaction: return "m.room.redaction"
        case .sticker: return "m.sticker"
        case .pollStart: return "m.poll.start"
        case .callMember: return "org.matrix.msc3401.call.member"
        case .typing: return "m.typing"
        case .receipt: return "m.receipt"
        case .presence: return "m.presence"
        case .fullyRead: return "m.fully_read"
        case .tag: return "m.tag"
        case .custom(let s): return s
        case .unknown(let s): return s
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "m.room.create": self = .roomCreate
        case "m.room.member": self = .roomMember
        case "m.room.message": self = .roomMessage
        case "m.room.name": self = .roomName
        case "m.room.topic": self = .roomTopic
        case "m.room.avatar": self = .roomAvatar
        case "m.room.power_levels": self = .roomPowerLevels
        case "m.room.encryption": self = .roomEncryption
        case "m.room.tombstone": self = .roomTombstone
        case "m.room.canonical_alias": self = .roomCanonicalAlias
        case "m.room.pinned_events": self = .roomPinnedEvents
        case "m.room.join_rules": self = .roomJoinRules
        case "m.room.history_visibility": self = .roomHistoryVisibility
        case "m.room.server_acl": self = .roomServerACL
        case "m.reaction": self = .reaction
        case "m.room.redaction": self = .redaction
        case "m.sticker": self = .sticker
        case "m.poll.start", "org.matrix.msc3381.poll.start": self = .pollStart
        case "org.matrix.msc3401.call.member", "m.call.member": self = .callMember
        case "m.typing": self = .typing
        case "m.receipt": self = .receipt
        case "m.presence": self = .presence
        case "m.fully_read": self = .fullyRead
        case "m.tag": self = .tag
        default: self = .unknown(rawValue)
        }
    }
}

extension EventType: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Room visibility for directory listings.
public enum RoomVisibility: String, Hashable, Sendable, Codable {
    case `public`
    case `private`
}

/// Room preset used at creation time.
public enum RoomPreset: String, Hashable, Sendable, Codable {
    case privateChat = "private_chat"
    case publicChat = "public_chat"
    case trustedPrivateChat = "trusted_private_chat"
}

/// User presence states.
public enum Presence: String, Hashable, Sendable, Codable {
    case online
    case offline
    case unavailable
}

/// Message types (`msgtype` field of `m.room.message`).
public enum MessageType: String, Hashable, Sendable, Codable {
    case text = "m.text"
    case emote = "m.emote"
    case notice = "m.notice"
    case image = "m.image"
    case file = "m.file"
    case audio = "m.audio"
    case video = "m.video"
    case location = "m.location"
}

/// Relation types (`m.relates_to` `rel_type` field): replies, edits, threads, ...
public enum RelationType: String, Hashable, Sendable, Codable {
    case reply = "m.in_reply_to"
    case replacement = "m.replace"
    case annotation = "m.annotation"
    case reference = "m.reference"
    case thread = "m.thread"
}

/// Sync connection lifecycle state surfaced to SwiftUI.
public enum SyncStatus: Hashable, Sendable {
    case idle
    case syncing
    case paused
    case failed(String)
}

/// Direction for timeline pagination.
public enum PaginationDirection: String, Hashable, Sendable {
    /// Paginate backwards (older events).
    case backward = "b"
    /// Paginate forwards (newer events).
    case forward = "f"
}

/// Login flow types advertised by `GET /login`.
public enum LoginFlowType: String, Hashable, Sendable, Codable {
    case password = "m.login.password"
    case sso = "m.login.sso"
    case token = "m.login.token"
    case dummy = "m.login.dummy"
}
