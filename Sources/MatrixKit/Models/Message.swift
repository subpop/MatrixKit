/// Messaging models: message content, relations, timeline events.
import Foundation

/// `m.relates_to` — links a message to another event (reply, edit, reaction...).
public struct RelatesTo: Hashable, Sendable, Codable {
    /// Related event ID (the edited/reacted-to event). Absent for replies,
    /// which use `inReplyTo` instead.
    public var eventId: EventId?
    /// Relation type (`.replacement` for edits, `.annotation` for reactions).
    public var relType: RelationType?
    /// Reply target for rich replies.
    public var inReplyTo: InReplyTo?

    public init(
        eventId: EventId? = nil,
        relType: RelationType? = nil,
        inReplyTo: InReplyTo? = nil
    ) {
        self.eventId = eventId
        self.relType = relType
        self.inReplyTo = inReplyTo
    }

    /// Convenience for a rich reply (`m.in_reply_to`).
    public static func reply(to eventId: EventId) -> RelatesTo {
        RelatesTo(inReplyTo: InReplyTo(eventId: eventId))
    }

    /// Convenience for an edit (`m.replace`).
    public static func edit(of eventId: EventId) -> RelatesTo {
        RelatesTo(eventId: eventId, relType: .replacement)
    }

    /// Convenience for a reaction (`m.annotation`).
    public static func reaction(to eventId: EventId, key: String) -> RelatesTo {
        RelatesTo(eventId: eventId, relType: .annotation)
    }

    /// Convenience for a threaded reply: `m.thread` rooted at `root`,
    /// with an `m.in_reply_to` fallback to the direct parent.
    public static func thread(root: EventId, replyTo parent: EventId? = nil) -> RelatesTo {
        RelatesTo(
            eventId: root, relType: .thread,
            inReplyTo: parent.map(InReplyTo.init(eventId:)))
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case relType = "rel_type"
        case inReplyTo = "m.in_reply_to"
    }
}

/// The `m.in_reply_to` fallback target.
public struct InReplyTo: Hashable, Sendable, Codable {
    /// The replied-to event's ID.
    public var eventId: EventId

    public init(eventId: EventId) {
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }
}

/// `m.mentions` — notification routing for user and room mentions.
public struct Mentions: Hashable, Sendable, Codable {
    /// User IDs to notify.
    public var userIds: [UserId]?
    /// Whether the whole room is mentioned (`@room`).
    public var room: Bool?

    public init(userIds: [UserId]? = nil, room: Bool? = nil) {
        self.userIds = userIds
        self.room = room
    }

    private enum CodingKeys: String, CodingKey {
        case userIds = "user_ids"
        case room
    }
}

/// `m.room.message` content.
public struct MessageContent: Hashable, Sendable, Codable {
    /// Message type (`m.text`, `m.image`, …). Drives `MessageKind` rendering.
    public var msgtype: MessageType
    /// Plain-text body. Always present; doubles as the HTML fallback.
    /// For media messages this is the human-readable description, which
    /// serves as the caption when it differs from ``filename``.
    public var body: String
    /// Original filename for media messages (`m.image`, `m.video`, …).
    /// Compare against ``body`` to recover the sender's caption text.
    public var filename: String?
    /// HTML body, when `format` is `org.matrix.custom.html`.
    public var formattedBody: String?
    /// Body format marker (`org.matrix.custom.html` for rich text).
    public var format: String?
    /// Reply/edit/reaction linkage, if any.
    public var relatesTo: RelatesTo?
    /// Mention routing, if any.
    public var mentions: Mentions?
    /// Encrypted file reference (top-level `file` for encrypted media).
    public var file: EncryptedFile?
    /// MXC URI for media messages.
    public var url: String?
    /// File dimensions, duration, thumbnails, … for media messages.
    public var info: MediaInfo?

    public init(
        msgtype: MessageType = .text,
        body: String,
        filename: String? = nil,
        formattedBody: String? = nil,
        format: String? = nil,
        relatesTo: RelatesTo? = nil,
        mentions: Mentions? = nil,
        file: EncryptedFile? = nil,
        url: String? = nil,
        info: MediaInfo? = nil
    ) {
        self.msgtype = msgtype
        self.body = body
        self.filename = filename
        self.formattedBody = formattedBody
        self.format = format
        self.relatesTo = relatesTo
        self.mentions = mentions
        self.file = file
        self.url = url
        self.info = info
    }

    /// Plain-text message.
    public static func text(
        _ body: String, relatesTo: RelatesTo? = nil, mentions: Mentions? = nil
    ) -> MessageContent {
        MessageContent(msgtype: .text, body: body, relatesTo: relatesTo, mentions: mentions)
    }

    /// Thread root when this content carries an `m.thread` relation.
    public var threadRootEventId: EventId? {
        guard relatesTo?.relType == .thread else { return nil }
        return relatesTo?.eventId
    }

    /// HTML-formatted message (with plain-text fallback).
    public static func html(
        _ body: String, formattedBody: String, relatesTo: RelatesTo? = nil,
        mentions: Mentions? = nil
    ) -> MessageContent {
        MessageContent(
            msgtype: .text,
            body: body,
            formattedBody: formattedBody,
            format: "org.matrix.custom.html",
            relatesTo: relatesTo,
            mentions: mentions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case msgtype
        case body
        case filename
        case formattedBody = "formatted_body"
        case format
        case relatesTo = "m.relates_to"
        case mentions = "m.mentions"
        case file
        case url
        case info
    }
}

/// Attachment metadata for media messages (`m.image`, `m.video`, ...).
public struct MediaInfo: Hashable, Sendable, Codable {
    /// MIME type (e.g. `image/png`).
    public var mimeType: String?
    /// File size in bytes.
    public var size: Int?
    /// Image/video width in pixels.
    public var width: Int?
    /// Image/video height in pixels.
    public var height: Int?
    /// Audio/video duration in milliseconds.
    public var duration: Int?
    /// MXC URI of the thumbnail, if the server generated one.
    public var thumbnailUrl: String?
    /// Thumbnail dimensions and size.
    public var thumbnailInfo: ThumbnailInfo?
    /// Encrypted thumbnail reference.
    public var thumbnailFile: EncryptedFile?

    public init(
        mimeType: String? = nil,
        size: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Int? = nil,
        thumbnailUrl: String? = nil,
        thumbnailInfo: ThumbnailInfo? = nil,
        thumbnailFile: EncryptedFile? = nil
    ) {
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.thumbnailUrl = thumbnailUrl
        self.thumbnailInfo = thumbnailInfo
        self.thumbnailFile = thumbnailFile
    }

    private enum CodingKeys: String, CodingKey {
        case mimeType = "mimetype"
        case size
        case width = "w"
        case height = "h"
        case duration
        case thumbnailUrl = "thumbnail_url"
        case thumbnailInfo = "thumbnail_info"
        case thumbnailFile = "thumbnail_file"
    }
}
/// Thumbnail metadata nested inside `MediaInfo`.
public struct ThumbnailInfo: Hashable, Sendable, Codable {

    /// Thumbnail MIME type.
    public var mimeType: String?
    /// Thumbnail size in bytes.
    public var size: Int?
    /// Thumbnail width in pixels.
    public var width: Int?
    /// Thumbnail height in pixels.
    public var height: Int?

    public init(mimeType: String? = nil, size: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case mimeType = "mimetype"
        case size
        case width = "w"
        case height = "h"
    }
}

/// JWK octet key for encrypted attachments (`A256CTR`).
public struct AttachmentKey: Hashable, Sendable, Codable {
    /// Key type (always `oct` here).
    public var keyType: String
    /// Key operations.
    public var keyOps: [String]
    /// Algorithm (always `A256CTR` here).
    public var algorithm: String
    /// Key material (base64url, no padding).
    public var key: String
    /// Whether the key is extractable.
    public var extractable: Bool

    public init(
        keyType: String = "oct",
        keyOps: [String] = ["encrypt", "decrypt"],
        algorithm: String = "A256CTR",
        key: String,
        extractable: Bool = true
    ) {
        self.keyType = keyType
        self.keyOps = keyOps
        self.algorithm = algorithm
        self.key = key
        self.extractable = extractable
    }

    private enum CodingKeys: String, CodingKey {
        case keyType = "kty"
        case keyOps = "key_ops"
        case algorithm = "alg"
        case key = "k"
        case extractable = "ext"
    }
}

/// Encrypted file reference (`file` / `thumbnail_file`).
public struct EncryptedFile: Hashable, Sendable, Codable {
    /// MXC URI of the ciphertext.
    public var url: String
    /// Decryption key.
    public var key: AttachmentKey
    /// Initialization vector (base64url, no padding).
    public var iv: String
    /// Integrity hashes (`sha256` of the ciphertext, base64url).
    public var hashes: [String: String]
    /// Key version (always `v2` here).
    public var version: String

    public init(
        url: String,
        key: AttachmentKey,
        iv: String,
        hashes: [String: String] = [:],
        version: String = "v2"
    ) {
        self.url = url
        self.key = key
        self.iv = iv
        self.hashes = hashes
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case key
        case iv
        case hashes
        case version = "v"
    }
}

/// A timeline message event as decoded from sync or `/messages`.
public struct MessageEvent: Hashable, Sendable, Codable {
    /// Matrix event type (`m.room.message`, `m.room.member`, …).
    public var type: String
    /// Unique event ID. Use for replies, reactions, and receipts.
    public var eventId: EventId
    /// Sender's user ID.
    public var sender: UserId
    /// Room ID. Absent in sync timelines (implied by the enclosing section).
    public var roomId: RoomId?
    /// State key for state events (e.g. the user ID for `m.room.member`).
    public var stateKey: String?
    /// Target of an `m.room.redaction` event (the redacted event's ID).
    public var redacts: EventId?
    /// Send time in milliseconds since the Unix epoch. See `timestamp`.
    public var originServerTs: Int
    /// Type-erased event payload. Decode via `messageContent` for messages.
    public var content: [String: AnyCodable]
    /// Server-supplied metadata (transaction IDs, `redacted_because`, …).
    public var unsigned: [String: AnyCodable]?

    public init(
        type: String,
        eventId: EventId,
        sender: UserId,
        roomId: RoomId? = nil,
        stateKey: String? = nil,
        redacts: EventId? = nil,
        originServerTs: Int,
        content: [String: AnyCodable],
        unsigned: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.eventId = eventId
        self.sender = sender
        self.roomId = roomId
        self.stateKey = stateKey
        self.redacts = redacts
        self.originServerTs = originServerTs
        self.content = content
        self.unsigned = unsigned
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case sender
        case roomId = "room_id"
        case stateKey = "state_key"
        case redacts
        case originServerTs = "origin_server_ts"
        case content
        case unsigned
    }

    /// The event timestamp as a `Date`.
    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(originServerTs) / 1000)
    }

    /// Decode `content` as `m.room.message`.
    public var messageContent: MessageContent? {
        // Re-encode through JSON to decode the concrete content type.
        guard
            let data = try? JSONEncoder().encode(content),
            let decoded = try? JSONDecoder().decode(MessageContent.self, from: data)
        else { return nil }
        return decoded
    }

    /// Whether this event is a redaction.
    public var isRedacted: Bool {
        type == EventType.redaction.rawValue
            || (unsigned?["redacted_because"] != nil)
    }
}

/// `PUT /rooms/{roomId}/send/{eventType}/{txnId}` response body.
public struct SendEventResponse: Hashable, Sendable, Codable {
    /// Server-assigned ID of the sent event.
    public var eventId: EventId

    public init(eventId: EventId) {
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }
}

/// `PUT /rooms/{roomId}/redact/{eventId}/{txnId}` request body.
public struct RedactRequest: Hashable, Sendable, Codable {
    /// Human-readable reason shown in the redaction event.
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

/// `m.reaction` content (`m.annotation` relation + emoji key).
public struct ReactionContent: Hashable, Sendable, Codable {
    /// Target event plus emoji key.
    public var relatesTo: ReactionRelation

    public init(relatesTo: ReactionRelation) {
        self.relatesTo = relatesTo
    }

    public static func reaction(to eventId: EventId, key: String) -> ReactionContent {
        ReactionContent(relatesTo: ReactionRelation(eventId: eventId, key: key))
    }

    private enum CodingKeys: String, CodingKey {
        case relatesTo = "m.relates_to"
    }
}

/// The `m.relates_to` payload of a reaction.
public struct ReactionRelation: Hashable, Sendable, Codable {
    /// The reacted-to event's ID.
    public var eventId: EventId
    /// Always `m.annotation` for reactions.
    public var relType: String
    /// Emoji (or custom) key, e.g. `👍`.
    public var key: String

    public init(eventId: EventId, key: String) {
        self.eventId = eventId
        self.relType = RelationType.annotation.rawValue
        self.key = key
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case relType = "rel_type"
        case key
    }
}
