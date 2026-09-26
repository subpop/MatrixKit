import Foundation
import Observation

/// Display-ready message kinds for timeline rendering.
public enum MessageKind: Hashable, Sendable {
    /// Plain `m.text` message.
    case text(body: String)
    /// `m.emote` (`/me`) message.
    case emote(body: String)
    /// `m.notice` (bot/system) message.
    case notice(body: String)
    /// `m.image` with optional MXC URL and file metadata.
    case image(body: String, url: String?, info: MediaInfo?)
    /// `m.video` with optional MXC URL and file metadata.
    case video(body: String, url: String?, info: MediaInfo?)
    /// `m.audio` with optional MXC URL and file metadata.
    case audio(body: String, url: String?, info: MediaInfo?)
    /// `m.file` with optional MXC URL and file metadata.
    case file(body: String, url: String?, info: MediaInfo?)
    /// `m.location` message.
    case location(body: String)
    /// `m.location` referencing a beacon (live location share).
    case liveLocation(body: String)
    /// `m.sticker` with MXC URL and file metadata.
    case sticker(body: String, url: String?, info: MediaInfo?)
    /// `m.poll.start` (stable and MSC3381 prefixes).
    case poll(question: String)
    /// Room state change (member join/leave, rename, …) with a
    /// human-readable description.
    case state(type: String, description: String)
    /// Membership profile change (display name / avatar) with a
    /// human-readable description.
    case profileChange(description: String)
    /// VoIP / MatrixRTC signalling with a human-readable description.
    case callEvent(type: String, description: String)
    /// Redacted (deleted) event — render a placeholder.
    case redacted
    /// Encrypted event that could not be decrypted — render a fallback
    /// placeholder. Decryptable events never reach this case: successful
    /// decryption replaces the type with the plaintext inner type before
    /// classification.
    case unableToDecrypt
    /// Anything unrecognized, with the raw event type for debugging.
    case unknown(type: String)
}

/// A reply target resolved from the timeline snapshot.
public struct ResolvedReply: Hashable, Sendable {
    /// The replied-to event's ID.
    public var eventID: EventId
    /// The replied-to event's sender.
    public var senderID: UserId
    /// Sender display name, if known.
    public var senderDisplayName: String?
    /// Plain-text body of the parent.
    public var body: String
    /// HTML body of the parent, if any.
    public var formattedBody: String?
    /// MXC URL when the parent is an image.
    public var imageURL: String?

    public init(
        eventID: EventId,
        senderID: UserId,
        senderDisplayName: String? = nil,
        body: String,
        formattedBody: String? = nil,
        imageURL: String? = nil
    ) {
        self.eventID = eventID
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.formattedBody = formattedBody
        self.imageURL = imageURL
    }

    /// Fallback display name (sender ID when unknown).
    public var displayName: String { senderDisplayName ?? senderID.value }
}

/// A single timeline event prepared for SwiftUI rendering.
@Observable @MainActor
public final class ObservableTimelineEvent {
    /// Unique event ID. Stable across syncs; use for reply/react targets.
    public let eventId: EventId
    /// Sender's user ID. Resolve display names via the room's `memberDetails`.
    public let sender: UserId
    /// Send time, converted from the server's `origin_server_ts`.
    public let timestamp: Date
    /// Classified content for `switch`-based rendering.
    public let kind: MessageKind
    /// HTML body, when the event carries `org.matrix.custom.html`.
    /// Render in preference to the plain body inside `kind`.
    public let formattedBody: String?
    /// Original filename for media messages, when the event carries one.
    /// Compare against the kind's body to recover the sender's caption:
    /// a body that differs from the filename is caption text.
    public let filename: String?
    /// Encrypted file reference for encrypted attachments (`file`).
    /// Download through `MediaClient.downloadDecrypted`.
    public let encryptedFile: EncryptedFile?
    /// Sender display name resolved from room members, if known.
    public let senderDisplayName: String?
    /// Sender avatar MXC URI, if known.
    public let senderAvatarURL: MXCURI?
    /// Target user of an `m.room.member` event (the `state_key` user),
    /// when it differs from the sender — e.g. the invitee of an invite,
    /// or the user removed/banned by a moderator. Nil for non-membership
    /// events and for self-actions (joins, leaves, profile changes).
    /// Raw spec identifier only; link construction stays app-side.
    public let targetUserId: UserId?
    /// Display name used for ``targetUserId`` when the description was
    /// built, if known. Falls back to the user ID in the description.
    public let targetDisplayName: String?
    /// User IDs listed in the event's `m.mentions`, if any.
    public var mentionedUserIds: [UserId]
    /// True when the event is redacted (renders as `.redacted`).
    public let isRedacted: Bool
    /// Aggregated reactions: emoji key → sender IDs.
    public var reactions: [String: [UserId]]
    /// Reaction keys the local user added.
    public var ownReactions: Set<String>
    /// True when the local user is mentioned, the whole room is
    /// mentioned, or a highlight keyword matches the body.
    public var isHighlighted: Bool
    /// The local user when this event mentions them, else nil.
    public var highlightedMentionUserId: UserId?
    /// Highlight keywords matched in this event's body.
    public var highlightKeywords: [String]
    /// Whether the local user may edit this event (own, unredacted message).
    public var isEditable: Bool
    /// True when an `m.replace` edit was folded into this event.
    public var isEdited: Bool
    /// The resolved reply target, if this event is a reply.
    public var reply: ResolvedReply?
    /// Local delivery state for staged echoes; nil for confirmed events.
    public var sendState: SendState?
    /// Thread root when this event carries an `m.thread` relation.
    public let threadRootEventId: EventId?
    /// Bundled `m.thread` reply count (`unsigned.m.relations`), if present.
    public let threadReplyCount: Int?
    /// Whether the bundled thread summary marks local participation.
    public let threadParticipated: Bool

    public init(
        eventId: EventId,
        sender: UserId,
        timestamp: Date,
        kind: MessageKind,
        isRedacted: Bool = false,
        reactions: [String: [UserId]] = [:],
        isEditable: Bool = false,
        formattedBody: String? = nil,
        filename: String? = nil,
        encryptedFile: EncryptedFile? = nil,
        senderDisplayName: String? = nil,
        senderAvatarURL: MXCURI? = nil,
        targetUserId: UserId? = nil,
        targetDisplayName: String? = nil,
        mentionedUserIds: [UserId] = [],
        threadRootEventId: EventId? = nil,
        threadReplyCount: Int? = nil,
        threadParticipated: Bool = false
    ) {
        self.eventId = eventId
        self.sender = sender
        self.timestamp = timestamp
        self.kind = kind
        self.isRedacted = isRedacted
        self.reactions = reactions
        self.isEditable = isEditable
        self.formattedBody = formattedBody
        self.filename = filename
        self.senderDisplayName = senderDisplayName
        self.senderAvatarURL = senderAvatarURL
        self.targetUserId = targetUserId
        self.targetDisplayName = targetDisplayName
        self.mentionedUserIds = mentionedUserIds
        self.encryptedFile = encryptedFile
        self.ownReactions = []
        self.isHighlighted = false
        self.highlightedMentionUserId = nil
        self.highlightKeywords = []
        self.isEdited = false
        self.reply = nil
        self.sendState = nil
        self.threadRootEventId = threadRootEventId
        self.threadReplyCount = threadReplyCount
        self.threadParticipated = threadParticipated
    }

    /// Relative age string ("2h ago", "Yesterday", ...).
    public var age: String {
        let interval = -timestamp.timeIntervalSinceNow
        switch interval {
        case ..<60: return "Just now"
        case ..<3600: return "\(Int(interval / 60))m ago"
        case ..<86400: return "\(Int(interval / 3600))h ago"
        case ..<604800: return "\(Int(interval / 86400))d ago"
        default:
            return timestamp.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Build from a raw event. `localUser` marks own messages editable;
    /// `members` resolves sender display names and avatars.
    public static func make(
        from event: MessageEvent,
        localUser: UserId?,
        members: [UserId: MemberContent] = [:]
    ) -> ObservableTimelineEvent {
        let kind = classify(event, members: members)
        let redacted = event.isRedacted
        let member = members[event.sender]
        let content = event.messageContent
        let threadSummary = event.unsigned?["m.relations"]?.objectValue?["m.thread"]?.objectValue
        let target = membershipTarget(in: event, members: members)
        return ObservableTimelineEvent(
            eventId: event.eventId,
            sender: event.sender,
            timestamp: event.timestamp,
            kind: redacted ? .redacted : kind,
            isRedacted: redacted,
            isEditable: event.sender == localUser && !redacted,
            formattedBody: content?.formattedBody,
            filename: content?.filename,
            encryptedFile: content?.file,
            senderDisplayName: member?.displayname ?? selfMembershipName(in: event),
            senderAvatarURL: member?.avatarUrl.flatMap { try? MXCURI($0) },
            targetUserId: target?.id,
            targetDisplayName: target?.displayName,
            mentionedUserIds: mentions(in: event),
            threadRootEventId: content?.threadRootEventId,
            threadReplyCount: threadSummary?["count"]?.intValue,
            threadParticipated: threadSummary?["current_user_participated"]?.boolValue ?? false
        )
    }

    /// User IDs listed in the event's `m.mentions`.
    static func mentions(in event: MessageEvent) -> [UserId] {
        guard
            let ids = event.content["m.mentions"]?.objectValue?["user_ids"]?.arrayValue
        else { return [] }
        return ids.compactMap { $0.stringValue.map(UserId.init(unchecked:)) }
    }

    /// Whether the event mentions the whole room (`m.mentions.room`).
    static func mentionsRoom(in event: MessageEvent) -> Bool {
        event.content["m.mentions"]?.objectValue?["room"]?.boolValue ?? false
    }

    /// Target of an `m.room.member` event (the `state_key` user) with its
    /// resolved display name, or nil when the event is not a membership
    /// event or the target is the sender (self join/leave/profile change).
    static func membershipTarget(
        in event: MessageEvent, members: [UserId: MemberContent]
    ) -> (id: UserId, displayName: String?)? {
        guard
            EventType(rawValue: event.type) == .roomMember,
            let key = event.stateKey, !key.isEmpty
        else { return nil }
        let target = UserId(unchecked: key)
        guard target != event.sender else { return nil }
        // The content describes the target, so its display name is a
        // valid fallback when room state doesn't know them yet. The
        // pre-transition content covers profile-less leaves/kicks even
        // on a cold start, where state never saw the joined profile.
        return (
            target,
            members[target]?.displayname ?? event.content["displayname"]?.stringValue
                ?? previousDisplayName(in: event))
    }

    /// Display name from the event's pre-transition content, when the
    /// event itself omits the profile (servers often strip `displayname`
    /// from leave/kick content).
    static func previousDisplayName(in event: MessageEvent) -> String? {
        event.unsigned?["prev_content"]?.objectValue?["displayname"]?.stringValue
    }

    /// The event content's display name when the event is a self
    /// `m.room.member` action (join/leave/profile change), where the
    /// content describes the sender. Nil otherwise: invite/kick content
    /// describes the target, never the sender.
    static func selfMembershipName(in event: MessageEvent) -> String? {
        guard
            EventType(rawValue: event.type) == .roomMember,
            let key = event.stateKey, !key.isEmpty,
            UserId(unchecked: key) == event.sender
        else { return nil }
        return event.content["displayname"]?.stringValue ?? previousDisplayName(in: event)
    }

    /// Whether this event is an `m.replace` edit.
    ///
    /// Detected from the wire-shape relation rather than `messageContent`:
    /// edits carry no `msgtype`, so they never decode as `MessageContent`.
    static func isEdit(_ event: MessageEvent) -> Bool {
        event.wireRelation?.relType == .replacement
    }

    /// Decode the replacement content of an `m.replace` edit.
    static func editReplacement(in event: MessageEvent) -> MessageContent? {
        guard
            isEdit(event),
            let data = try? JSONEncoder().encode(event.content),
            let edit = try? JSONDecoder().decode(EditContent.self, from: data)
        else { return nil }
        return edit.newContent
    }

    /// Resolve the reply target from folded snapshot events, or nil when
    /// the parent is unknown or not a message.
    static func resolveReply(
        for event: MessageEvent,
        in eventsById: [EventId: MessageEvent],
        members: [UserId: MemberContent] = [:]
    ) -> ResolvedReply? {
        guard
            let parentId = event.messageContent?.relatesTo?.inReplyTo?.eventId,
            let parent = eventsById[parentId],
            let content = parent.messageContent
        else { return nil }
        return ResolvedReply(
            eventID: parentId,
            senderID: parent.sender,
            senderDisplayName: members[parent.sender]?.displayname,
            body: content.body,
            formattedBody: content.formattedBody,
            imageURL: content.msgtype == .image ? content.url : nil)
    }

    private static func classify(
        _ event: MessageEvent, members: [UserId: MemberContent]
    ) -> MessageKind {
        func displayName(for userId: UserId) -> String {
            members[userId]?.displayname ?? userId.value
        }
        // Ciphertext that survived decryption untouched: the event could
        // not be decrypted (missing session, bad crypto, malformed
        // payload). Decryptable events are re-typed with the plaintext
        // inner type before classification, so they never land here.
        if event.type == RoomCrypto.roomEncryptedType {
            return .unableToDecrypt
        }
        switch EventType(rawValue: event.type) {
        case .roomMessage:
            guard let content = event.messageContent else {
                return .unknown(type: event.type)
            }
            let body = content.body
            switch content.msgtype {
            case .text: return .text(body: body)
            case .emote: return .emote(body: body)
            case .notice: return .notice(body: body)
            case .image: return .image(body: body, url: content.url, info: content.info)
            case .video: return .video(body: body, url: content.url, info: content.info)
            case .audio: return .audio(body: body, url: content.url, info: content.info)
            case .file: return .file(body: body, url: content.url, info: content.info)
            case .location:
                // Live shares reference their beacon; static shares don't.
                if content.relatesTo?.relType == .reference {
                    return .liveLocation(body: body)
                }
                return .location(body: body)
            }
        case .sticker:
            return .sticker(
                body: event.content["body"]?.stringValue ?? "Sticker",
                url: event.content["url"]?.stringValue,
                info: mediaInfo(in: event.content))
        case .pollStart:
            let question = event.content["question"]?.objectValue?["org.matrix.msc1767.text"]?.stringValue
                ?? event.content["question"]?.objectValue?["body"]?.stringValue
                ?? "Poll"
            return .poll(question: question)
        case .redaction:
            return .redacted
        case .roomMember:
            return classifyMembership(event, members: members)
        case .roomName:
            let name = event.content["name"]?.stringValue ?? ""
            return .state(type: event.type, description: "Room renamed to “\(name)”")
        case .roomTopic:
            return .state(type: event.type, description: "Topic changed")
        case .roomCreate:
            return .state(type: event.type, description: "The room was created")
        case .roomAvatar:
            return .state(type: event.type, description: "Room avatar was updated")
        case .roomPowerLevels:
            return .state(type: event.type, description: "Room permissions were updated")
        case .roomEncryption:
            return .state(type: event.type, description: "Encryption was enabled")
        case .roomTombstone:
            return .state(type: event.type, description: "The room was upgraded")
        case .roomCanonicalAlias:
            return .state(type: event.type, description: "Room address was updated")
        case .roomPinnedEvents:
            return .state(type: event.type, description: "Pinned messages were updated")
        case .roomJoinRules:
            return .state(type: event.type, description: "Join rules were updated")
        case .roomHistoryVisibility:
            return .state(type: event.type, description: "History visibility was updated")
        case .roomServerACL:
            return .state(type: event.type, description: "Server access control was updated")
        case .callMember:
            let name = displayName(for: event.sender)
            return .callEvent(
                type: event.type,
                description: "\(name) updated call participation")
        case .reaction, .typing, .receipt, .presence, .fullyRead, .tag, .custom, .unknown:
            if let verb = callVerb(for: event.type) {
                return .callEvent(
                    type: event.type,
                    description: "\(displayName(for: event.sender)) \(verb)")
            }
            return .unknown(type: event.type)
        }
    }

    private static func classifyMembership(
        _ event: MessageEvent, members: [UserId: MemberContent]
    ) -> MessageKind {
        func displayName(for userId: UserId) -> String {
            members[userId]?.displayname ?? userId.value
        }
        let target = event.stateKey.map(UserId.init(unchecked:)) ?? event.sender
        // Prefer room state, then the event's own content (member
        // content always describes the state-key user), then the
        // pre-transition content (profile-less leaves/kicks), then the ID.
        let targetName = members[target]?.displayname
            ?? event.content["displayname"]?.stringValue
            ?? previousDisplayName(in: event)
            ?? target.value
        let senderName = displayName(for: event.sender)
        let membership = event.content["membership"]?.stringValue ?? "?"
        switch Membership(rawValue: membership) {
        case .join:
            // Only a join→join transition can carry a profile change: an
            // initial join (no prev_content) or a rejoin (previous
            // membership was not join) renders as a join even when it
            // sets a display name or avatar.
            if event.sender == target,
               event.unsigned?["prev_content"]?.objectValue?["membership"]?.stringValue == "join",
               let change = profileChange(in: event, name: targetName) {
                return .profileChange(description: change)
            }
            return .state(type: event.type, description: "\(targetName) joined")
        case .invite:
            return .state(type: event.type, description: "\(senderName) invited \(targetName)")
        case .leave:
            if event.sender == target {
                return .state(type: event.type, description: "\(targetName) left")
            }
            return .state(type: event.type, description: "\(senderName) removed \(targetName)")
        case .ban:
            return .state(type: event.type, description: "\(senderName) banned \(targetName)")
        case .knock:
            return .state(type: event.type, description: "\(targetName) requested to join")
        case .none:
            return .state(type: event.type, description: "\(targetName) \(membership)")
        }
    }

    /// Human-readable profile-change description, or nil when this join
    /// event carries no display-name/avatar change.
    private static func profileChange(in event: MessageEvent, name: String) -> String? {
        let content = event.content
        let previous = event.unsigned?["prev_content"]?.objectValue
        let oldName = previous?["displayname"]?.stringValue
        let newName = content["displayname"]?.stringValue
        let oldAvatar = previous?["avatar_url"]?.stringValue
        let newAvatar = content["avatar_url"]?.stringValue
        var parts: [String] = []
        if oldName != newName, let newName {
            if let oldName {
                parts.append("changed their display name from “\(oldName)” to “\(newName)”")
            } else {
                parts.append("set their display name to “\(newName)”")
            }
        }
        if oldAvatar != newAvatar {
            parts.append("changed their avatar")
        }
        guard !parts.isEmpty else { return nil }
        return "\(name) \(parts.joined(separator: " and "))"
    }

    /// User-meaningful call verb for signalling types; nil for
    /// negotiation noise (renders as `.unknown` instead).
    private static func callVerb(for type: String) -> String? {
        switch type {
        case "m.call.invite": "started a call"
        case "m.call.answer": "answered the call"
        case "m.call.hangup", "m.call.reject": "ended the call"
        default: nil
        }
    }

    private static func mediaInfo(in content: [String: AnyCodable]) -> MediaInfo? {
        guard
            let raw = content["info"],
            let data = try? JSONEncoder().encode(raw),
            let info = try? JSONDecoder().decode(MediaInfo.self, from: data)
        else { return nil }
        return info
    }
}
