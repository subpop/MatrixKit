import Foundation
import Observation

/// Delivery state of a locally-echoed event.
public enum SendState: Hashable, Sendable {
    /// Staged locally; not yet confirmed by sync.
    case pending
    /// The send failed with a human-readable reason.
    case failed(String)
}

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
    /// `m.poll.start` (stable and MSC3381 prefixes) with its answers and
    /// vote state.
    case poll(PollSummary)
    /// `m.poll.end` (stable and MSC3381 prefixes) — the poll closed.
    case pollEnd
    /// In-room `m.key.verification.request` message with a
    /// human-readable description.
    case verificationRequest(description: String)
    /// `m.server_notice` (homeserver system message) with a
    /// human-readable description.
    case serverNotice(description: String)
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
    /// Classified content for `switch`-based rendering. Poll counts are
    /// folded in during ``render(_:members:localUser:highlightKeywords:sendStates:)``.
    public private(set) var kind: MessageKind
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
            kind: redacted && !survivesRedaction(event) ? .redacted : kind,
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

    /// Redacted events whose preserved content (spec redaction algorithm)
    /// still renders meaningfully. Membership keeps `membership`, so a
    /// join/leave/ban/invite/knock transition stays readable; join→join
    /// profile changes lose the profile fields and stay tombstoned.
    private static func survivesRedaction(_ event: MessageEvent) -> Bool {
        guard EventType(rawValue: event.type) == .roomMember,
              let membership = event.content["membership"]?.stringValue
        else { return false }
        let previous = event.unsigned?["prev_content"]?.objectValue?["membership"]?.stringValue
        return !(membership == "join" && previous == "join")
    }

    /// Render a snapshot into display-ready events: aggregate reactions
    /// (redacted ones excluded), fold poll votes into their polls, fold
    /// edits into their targets (last edit wins), hide
    /// reactions/redactions/edits/poll votes, resolve replies and
    /// highlights, and coalesce fresh-join profile noise. Pure —
    /// `@Query` apps call this over stored rows.
    public static func render(
        _ snapshot: [MessageEvent],
        members: [UserId: MemberContent] = [:],
        localUser: UserId? = nil,
        highlightKeywords: [String] = [],
        sendStates: [EventId: SendState] = [:]
    ) -> [ObservableTimelineEvent] {
        // Aggregate reactions: target event -> key -> senders.
        // Redacted reactions (toggle-off) must not feed the badges.
        var reactionMap: [EventId: [String: [UserId]]] = [:]
        for event in snapshot
        where EventType(rawValue: event.type) == .reaction && !event.isRedacted {
            guard
                let data = try? JSONEncoder().encode(event.content),
                let content = try? JSONDecoder().decode(ReactionContent.self, from: data)
            else { continue }
            reactionMap[content.relatesTo.eventId, default: [:]][content.relatesTo.key, default: []]
                .append(event.sender)
        }
        let polls = pollSummaries(in: snapshot, localUser: localUser)
        // Fold edits: target event -> replacement content (last edit wins).
        var editMap: [EventId: MessageContent] = [:]
        for event in snapshot {
            guard
                let target = event.messageContent?.relatesTo?.eventId,
                event.messageContent?.relatesTo?.relType == .replacement,
                let replacement = editReplacement(in: event)
            else { continue }
            editMap[target] = replacement
        }
        // Rendered sources: edit targets with folded content.
        let folded: [MessageEvent] = snapshot.map { event in
            guard
                let replacement = editMap[event.eventId],
                let data = try? JSONEncoder().encode(replacement),
                let content = try? JSONDecoder().decode(
                    [String: AnyCodable].self, from: data)
            else { return event }
            var copy = event
            copy.content = content
            return copy
        }
        let byId: [EventId: MessageEvent] = Dictionary(
            folded.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
        // Redaction events are hidden: the redacted target carries the
        // tombstone via `redacted_because`, so rendering the redaction
        // itself would print a stray "deleted" bubble (e.g. toggling a
        // reaction off). Poll responses are votes, not messages: they
        // aggregate server-side and would otherwise print stray bubbles.
        let visible = folded.filter {
            EventType(rawValue: $0.type) != .reaction
                && EventType(rawValue: $0.type) != .redaction
                && EventType(rawValue: $0.type) != .pollResponse
                && !isEdit($0)
        }
        let rendered: [ObservableTimelineEvent] = visible.map { event in
            let wrapper = make(
                from: event, localUser: localUser, members: members)
            if let summary = polls[event.eventId] {
                wrapper.kind = .poll(summary)
            }
            let reactions = reactionMap[event.eventId] ?? [:]
            wrapper.reactions = reactions
            if editMap[event.eventId] != nil {
                wrapper.isEdited = true
            }
            wrapper.reply = resolveReply(
                for: event, in: byId, members: members)
            wrapper.sendState = sendStates[event.eventId]
            if let localUser {
                wrapper.ownReactions = Set(reactions.keys.filter {
                    reactions[$0]?.contains(localUser) ?? false
                })
                let selfMentioned = wrapper.mentionedUserIds.contains(localUser)
                wrapper.highlightedMentionUserId = selfMentioned ? localUser : nil
                let matched = highlightKeywords.filter {
                    event.messageContent?.body.localizedCaseInsensitiveContains($0) ?? false
                }
                wrapper.highlightKeywords = matched
                wrapper.isHighlighted = selfMentioned
                    || mentionsRoom(in: event)
                    || !matched.isEmpty
            }
            return wrapper
        }
        return coalesceJoinProfileChanges(events: visible, rendered: rendered)
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

    /// Fold profile noise from fresh joins into a single "joined" row.
    ///
    /// A self `m.room.member` join followed by profile-carrying join
    /// events from the same user (the client setting its name/avatar at
    /// join time) renders as one join row: the later `.profileChange`
    /// rows are dropped. The fresh-join window for a user ends when they
    /// send anything else or their membership changes again, so genuine
    /// later renames still show.
    static func coalesceJoinProfileChanges(
        events: [MessageEvent], rendered: [ObservableTimelineEvent]
    ) -> [ObservableTimelineEvent] {
        var freshJoins = Set<UserId>()
        var kept: [ObservableTimelineEvent] = []
        kept.reserveCapacity(rendered.count)
        for (event, wrapper) in zip(events, rendered) {
            if EventType(rawValue: event.type) == .roomMember,
               let key = event.stateKey, !key.isEmpty
            {
                let target = UserId(unchecked: key)
                let membership = Membership(
                    rawValue: event.content["membership"]?.stringValue ?? "")
                if event.sender == target, membership == .join {
                    if case .profileChange = wrapper.kind {
                        if freshJoins.contains(target) { continue }
                        kept.append(wrapper)
                        continue
                    }
                    freshJoins.insert(target)
                    kept.append(wrapper)
                    continue
                }
                freshJoins.remove(target)
                kept.append(wrapper)
                continue
            }
            freshJoins.remove(event.sender)
            kept.append(wrapper)
        }
        return kept
    }

    /// Decode an event's content as `T` via a JSON round trip.
    private static func decoded<T: Decodable>(_ type: T.Type, from event: MessageEvent) -> T? {
        guard let data = try? JSONEncoder().encode(event.content) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The poll start as a summary with zero votes. Content that won't
    /// decode still renders as a poll, titled "Poll".
    static func pollSummary(for event: MessageEvent) -> PollSummary {
        guard let start = decoded(PollStartContent.self, from: event) else {
            return PollSummary(question: "Poll", answers: [])
        }
        return PollSummary(
            question: start.question.isEmpty ? "Poll" : start.question,
            answers: start.answers.map { PollSummary.Answer(id: $0.id, text: $0.text) },
            kind: start.kind,
            maxSelections: start.maxSelections)
    }

    /// Poll summaries keyed by `m.poll.start` event ID, with votes and end
    /// state folded in. A vote is each sender's latest response, after
    /// dropping unknown answers, truncating to `maxSelections`, and
    /// ignoring responses after the poll's end. An empty selection retracts
    /// the vote. A poll ends at the creator's earliest `m.poll.end`.
    static func pollSummaries(
        in snapshot: [MessageEvent], localUser: UserId?
    ) -> [EventId: PollSummary] {
        var polls: [EventId: (creator: UserId, summary: PollSummary)] = [:]
        for event in snapshot
        where EventType(rawValue: event.type) == .pollStart && !event.isRedacted {
            polls[event.eventId] = (event.sender, pollSummary(for: event))
        }
        guard !polls.isEmpty else { return [:] }

        var endTimestamps: [EventId: Int] = [:]
        for event in snapshot
        where EventType(rawValue: event.type) == .pollEnd && !event.isRedacted {
            guard
                let target = decoded(PollEndContent.self, from: event)?.relatesTo.eventId,
                let poll = polls[target], poll.creator == event.sender
            else { continue }
            endTimestamps[target] = min(
                endTimestamps[target] ?? event.originServerTs, event.originServerTs)
        }

        var votes: [EventId: [UserId: (ts: Int, answers: [String])]] = [:]
        for event in snapshot
        where EventType(rawValue: event.type) == .pollResponse && !event.isRedacted {
            guard
                let content = decoded(PollResponseContent.self, from: event),
                let target = content.relatesTo.eventId,
                let poll = polls[target]
            else { continue }
            if let end = endTimestamps[target], event.originServerTs > end { continue }
            let known = Set(poll.summary.answers.map(\.id))
            var selection: [String] = []
            for id in content.answers where known.contains(id) && !selection.contains(id) {
                selection.append(id)
            }
            selection = Array(selection.prefix(poll.summary.maxSelections))
            if let previous = votes[target]?[event.sender], previous.ts > event.originServerTs {
                continue
            }
            votes[target, default: [:]][event.sender] = (event.originServerTs, selection)
        }

        var summaries: [EventId: PollSummary] = [:]
        for (pollId, poll) in polls {
            var summary = poll.summary
            let selections = votes[pollId] ?? [:]
            var counts: [String: Int] = [:]
            for vote in selections.values {
                for id in vote.answers { counts[id, default: 0] += 1 }
            }
            summary.answers = summary.answers.map {
                PollSummary.Answer(id: $0.id, text: $0.text, voteCount: counts[$0.id] ?? 0)
            }
            summary.totalVotes = selections.values.filter { !$0.answers.isEmpty }.count
            summary.ownSelections = Set(localUser.flatMap { selections[$0]?.answers } ?? [])
            summary.isEnded = endTimestamps[pollId] != nil
            let top = summary.answers.map(\.voteCount).max() ?? 0
            summary.winningAnswerIds = summary.isEnded && top > 0
                ? Set(summary.answers.filter { $0.voteCount == top }.map(\.id))
                : []
            summaries[pollId] = summary
        }
        return summaries
    }

    private static func classify(
        _ event: MessageEvent, members: [UserId: MemberContent]
    ) -> MessageKind {
        func displayName(for userId: UserId) -> String {
            members[userId]?.displayname ?? userId.value
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
            case .keyVerificationRequest:
                return .verificationRequest(
                    description: "\(displayName(for: event.sender)) requested verification")
            case .badEncrypted:
                return .unableToDecrypt
            case .serverNotice:
                return .serverNotice(
                    description: Self.serverNoticeDescription(
                        for: event.content, fallback: body))
            case .unknown:
                // Unrecognized msgtype with a plain body: render the body
                // rather than dropping the event.
                return .text(body: body)
            }
        case .sticker:
            return .sticker(
                body: event.content["body"]?.stringValue ?? "Sticker",
                url: event.content["url"]?.stringValue,
                info: mediaInfo(in: event.content))
        case .pollStart:
            return .poll(pollSummary(for: event))
        case .pollEnd:
            return .pollEnd
        case .roomEncrypted:
            // Ciphertext that survived decryption untouched: the event
            // could not be decrypted (missing session, bad crypto,
            // malformed payload). Decryptable events are re-typed with
            // the plaintext inner type before classification, so they
            // never land here.
            return .unableToDecrypt
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
        case .callInvite, .callAnswer, .callHangup, .callReject:
            if let verb = callVerb(for: EventType(rawValue: event.type)) {
                return .callEvent(
                    type: event.type,
                    description: "\(displayName(for: event.sender)) \(verb)")
            }
            return .unknown(type: event.type)
        case .reaction, .pollResponse, .callCandidates, .callNegotiate,
            .callSelectAnswer, .callSDPStreamMetadataChanged,
            .typing, .receipt, .presence, .fullyRead, .tag, .custom, .unknown:
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

    /// Human-readable server-notice description: usage-limit wording
    /// when the notice type and limit are recognized, else the event's
    /// body. Notice wording is entirely client-side per spec, so novel
    /// notice types always fall back to the server-provided text.
    private static func serverNoticeDescription(
        for content: [String: AnyCodable], fallback: String
    ) -> String {
        guard
            let data = try? JSONEncoder().encode(content),
            let notice = try? JSONDecoder().decode(
                ServerNoticeContent.self, from: data),
            notice.serverNoticeType == "m.server_notice.usage_limit_reached"
        else { return fallback }
        switch notice.limitType {
        case "monthly_active_user":
            return "Your account has reached the monthly active user limit"
        case "media_quota_size":
            return "Your account has reached its media storage quota"
        default:
            return "Your account has reached its resource limit"
        }
    }

    /// User-meaningful call verb for signalling types; nil for
    /// negotiation noise (renders as `.unknown` instead).
    private static func callVerb(for type: EventType) -> String? {        switch type {
        case .callInvite: "started a call"
        case .callAnswer: "answered the call"
        case .callHangup, .callReject: "ended the call"
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
