/// Room details models: power levels, permissions, members, snapshots.
import Foundation

/// Power-level thresholds (`m.room.power_levels`), with spec defaults.
public struct RoomPowerLevelSettings: Hashable, Sendable {
    /// Ban threshold (default 50).
    public var ban: Int
    /// Kick threshold (default 50).
    public var kick: Int
    /// Invite threshold (default 0).
    public var invite: Int
    /// Redact-others threshold (default 50).
    public var redact: Int
    /// Default for message events (default 0).
    public var eventsDefault: Int
    /// Default for state events (default 50).
    public var stateDefault: Int
    /// Default level for users without an entry (default 0).
    public var usersDefault: Int
    /// `m.room.name` threshold (default 50).
    public var roomName: Int
    /// `m.room.topic` threshold (default 50).
    public var roomTopic: Int
    /// `m.room.avatar` threshold (default 50).
    public var roomAvatar: Int

    public init(
        ban: Int = 50, kick: Int = 50, invite: Int = 0, redact: Int = 50,
        eventsDefault: Int = 0, stateDefault: Int = 50, usersDefault: Int = 0,
        roomName: Int = 50, roomTopic: Int = 50, roomAvatar: Int = 50
    ) {
        self.ban = ban
        self.kick = kick
        self.invite = invite
        self.redact = redact
        self.eventsDefault = eventsDefault
        self.stateDefault = stateDefault
        self.usersDefault = usersDefault
        self.roomName = roomName
        self.roomTopic = roomTopic
        self.roomAvatar = roomAvatar
    }

    /// Parse thresholds from an `m.room.power_levels` content dict.
    public static func parse(_ content: [String: AnyCodable]) -> RoomPowerLevelSettings {
        let events = content["events"]?.objectValue ?? [:]
        return RoomPowerLevelSettings(
            ban: content["ban"]?.intValue ?? 50,
            kick: content["kick"]?.intValue ?? 50,
            invite: content["invite"]?.intValue ?? 0,
            redact: content["redact"]?.intValue ?? 50,
            eventsDefault: content["events_default"]?.intValue ?? 0,
            stateDefault: content["state_default"]?.intValue ?? 50,
            usersDefault: content["users_default"]?.intValue ?? 0,
            roomName: events["m.room.name"]?.intValue ?? 50,
            roomTopic: events["m.room.topic"]?.intValue ?? 50,
            roomAvatar: events["m.room.avatar"]?.intValue ?? 50)
    }

    /// Overwrite the threshold keys of a power-levels content dict,
    /// preserving users and unrelated entries (read-modify-write).
    public func applying(to content: [String: AnyCodable]) -> [String: AnyCodable] {
        var content = content
        content["ban"] = .int(ban)
        content["kick"] = .int(kick)
        content["invite"] = .int(invite)
        content["redact"] = .int(redact)
        content["events_default"] = .int(eventsDefault)
        content["state_default"] = .int(stateDefault)
        content["users_default"] = .int(usersDefault)
        var events = content["events"]?.objectValue ?? [:]
        events["m.room.name"] = .int(roomName)
        events["m.room.topic"] = .int(roomTopic)
        events["m.room.avatar"] = .int(roomAvatar)
        content["events"] = .object(events)
        return content
    }
}

/// What the local user may do in a room, derived from power levels.
public struct RoomPermissions: Hashable, Sendable {
    /// May change the room name.
    public var canEditName: Bool
    /// May change the room topic.
    public var canEditTopic: Bool
    /// May change the room avatar.
    public var canEditAvatar: Bool
    /// May invite users.
    public var canInvite: Bool
    /// May kick users.
    public var canKick: Bool
    /// May ban users.
    public var canBan: Bool
    /// May redact other users' events.
    public var canRedactOther: Bool
    /// May change power levels.
    public var canChangePermissions: Bool
    /// May pin messages.
    public var canPin: Bool
    /// May change the join rule.
    public var canEditJoinRules: Bool
    /// May change history visibility.
    public var canEditHistoryVisibility: Bool
    /// May change the canonical alias.
    public var canEditCanonicalAlias: Bool
    /// May send message events.
    public var canSendMessages: Bool

    public init(
        canEditName: Bool = false,
        canEditTopic: Bool = false,
        canEditAvatar: Bool = false,
        canInvite: Bool = false,
        canKick: Bool = false,
        canBan: Bool = false,
        canRedactOther: Bool = false,
        canChangePermissions: Bool = false,
        canPin: Bool = false,
        canEditJoinRules: Bool = false,
        canEditHistoryVisibility: Bool = false,
        canEditCanonicalAlias: Bool = false,
        canSendMessages: Bool = true
    ) {
        self.canEditName = canEditName
        self.canEditTopic = canEditTopic
        self.canEditAvatar = canEditAvatar
        self.canInvite = canInvite
        self.canKick = canKick
        self.canBan = canBan
        self.canRedactOther = canRedactOther
        self.canChangePermissions = canChangePermissions
        self.canPin = canPin
        self.canEditJoinRules = canEditJoinRules
        self.canEditHistoryVisibility = canEditHistoryVisibility
        self.canEditCanonicalAlias = canEditCanonicalAlias
        self.canSendMessages = canSendMessages
    }

    /// Whether any room-detail field is editable.
    public var canEditDetails: Bool {
        canEditName || canEditTopic || canEditAvatar || canEditCanonicalAlias
    }

    /// A user's power level under this content (`users_default`, else 0).
    public static func powerLevel(
        of userId: UserId, in content: [String: AnyCodable]
    ) -> Int {
        content["users"]?.objectValue?[userId.value]?.intValue
            ?? content["users_default"]?.intValue ?? 0
    }

    /// Evaluate permissions for `userId` under a power-levels content dict.
    public static func evaluate(
        powerLevels content: [String: AnyCodable], userId: UserId
    ) -> RoomPermissions {
        let level = powerLevel(of: userId, in: content)
        let stateDefault = content["state_default"]?.intValue ?? 50
        let events = content["events"]?.objectValue ?? [:]
        func can(_ threshold: Int) -> Bool { level >= threshold }
        func event(_ type: String, fallback: Int) -> Int {
            events[type]?.intValue ?? fallback
        }
        return RoomPermissions(
            canEditName: can(event("m.room.name", fallback: stateDefault)),
            canEditTopic: can(event("m.room.topic", fallback: stateDefault)),
            canEditAvatar: can(event("m.room.avatar", fallback: stateDefault)),
            canInvite: can(content["invite"]?.intValue ?? 0),
            canKick: can(content["kick"]?.intValue ?? 50),
            canBan: can(content["ban"]?.intValue ?? 50),
            canRedactOther: can(content["redact"]?.intValue ?? 50),
            canChangePermissions: can(event("m.room.power_levels", fallback: stateDefault)),
            canPin: can(event("m.room.pinned_events", fallback: stateDefault)),
            canEditJoinRules: can(event("m.room.join_rules", fallback: stateDefault)),
            canEditHistoryVisibility: can(
                event("m.room.history_visibility", fallback: stateDefault)),
            canEditCanonicalAlias: can(event("m.room.canonical_alias", fallback: stateDefault)),
            canSendMessages: can(event(
                "m.room.message",
                fallback: content["events_default"]?.intValue ?? 0)))
    }
}

/// One room member with role details for inspector UI.
public struct RoomMemberDetails: Hashable, Sendable, Identifiable {
    /// The member's user ID.
    public var id: String { userId.value }
    /// The member's user ID.
    public var userId: UserId
    /// Display name, if known.
    public var displayName: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Role bucket derived from the power level.
    public var role: Role
    /// Raw power level.
    public var powerLevel: Int
    /// Whether the member created the room.
    public var isCreator: Bool

    /// Role buckets: administrator (100+), moderator (50+), user.
    public enum Role: String, Sendable {
        /// Power level 100 or more.
        case administrator
        /// Power level 50 or more.
        case moderator
        /// Standard participant.
        case user

        /// Bucket for a raw power level.
        public static func of(_ powerLevel: Int) -> Role {
            if powerLevel >= 100 { .administrator } else if powerLevel >= 50 { .moderator } else { .user }
        }
    }

    public init(
        userId: UserId,
        displayName: String? = nil,
        avatarURL: MXCURI? = nil,
        role: Role = .user,
        powerLevel: Int = 0,
        isCreator: Bool = false
    ) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.role = role
        self.powerLevel = powerLevel
        self.isCreator = isCreator
    }
}

/// Full room snapshot for inspector and settings UI.
public struct RoomDetails: Hashable, Sendable {
    /// The room's ID.
    public var id: RoomId
    /// Display name, if known.
    public var name: String?
    /// Topic, if set.
    public var topic: String?
    /// Avatar MXC URI, if set.
    public var avatarURL: MXCURI?
    /// Whether the room is encrypted.
    public var isEncrypted: Bool
    /// Whether the join rule is public.
    public var isPublic: Bool
    /// Whether the room accepts knocks (`knock` or `knock_restricted`
    /// join rule).
    public var isKnockable: Bool {
        joinRule == "knock" || joinRule == "knock_restricted"
    }
    /// Whether the room is a direct chat.
    public var isDirect: Bool
    /// Canonical alias, if any.
    public var canonicalAlias: String?
    /// Alternative aliases.
    public var alternativeAliases: [String]
    /// Joined member count.
    public var memberCount: Int
    /// Members with role details.
    public var members: [RoomMemberDetails]
    /// Pinned event IDs.
    public var pinnedEventIds: [String]
    /// Raw join rule, if known.
    public var joinRule: String?
    /// Raw history visibility, if known.
    public var historyVisibility: String?
    /// Local user's permissions, if power levels are available.
    public var permissions: RoomPermissions?
    /// Power-level thresholds, if available.
    public var powerLevelSettings: RoomPowerLevelSettings?

    public init(
        id: RoomId,
        name: String? = nil,
        topic: String? = nil,
        avatarURL: MXCURI? = nil,
        isEncrypted: Bool = false,
        isPublic: Bool = false,
        isDirect: Bool = false,
        canonicalAlias: String? = nil,
        alternativeAliases: [String] = [],
        memberCount: Int = 0,
        members: [RoomMemberDetails] = [],
        pinnedEventIds: [String] = [],
        joinRule: String? = nil,
        historyVisibility: String? = nil,
        permissions: RoomPermissions? = nil,
        powerLevelSettings: RoomPowerLevelSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.avatarURL = avatarURL
        self.isEncrypted = isEncrypted
        self.isPublic = isPublic
        self.isDirect = isDirect
        self.canonicalAlias = canonicalAlias
        self.alternativeAliases = alternativeAliases
        self.memberCount = memberCount
        self.members = members
        self.pinnedEventIds = pinnedEventIds
        self.joinRule = joinRule
        self.historyVisibility = historyVisibility
        self.permissions = permissions
        self.powerLevelSettings = powerLevelSettings
    }
}
