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

    /// Markdown message: `body` carries the raw markdown; `formatted_body`
    /// carries the generated Matrix HTML subset (always present).
    public static func markdown(
        _ body: String, relatesTo: RelatesTo? = nil, mentions: Mentions? = nil
    ) -> MessageContent {
        html(
            body, formattedBody: MatrixHTMLGenerator.html(fromMarkdown: body),
            relatesTo: relatesTo, mentions: mentions)
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
    /// Counter block (standard base64, no padding): 16 bytes on the wire.
    public var iv: String
    /// Integrity hashes (`sha256` of the ciphertext, standard base64).
    public var hashes: [String: String]
    /// Attachment protocol version (`v0`/`v1`/`v2`). Absent on the wire
    /// means v0; counter width follows the label (64-bit for v1/v2).
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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        key = try container.decode(AttachmentKey.self, forKey: .key)
        iv = try container.decode(String.self, forKey: .iv)
        hashes = try container.decode([String: String].self, forKey: .hashes)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "v0"
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

    /// Decode just the `m.relates_to` relation straight from the wire shape.
    ///
    /// Unlike `messageContent`, this does not require `msgtype`, so it also
    /// resolves relations on `EditContent`: edits reuse the `m.room.message`
    /// type but carry `body` + `m.new_content` + `m.relates_to` and no
    /// `msgtype`, which never decodes as `MessageContent`.
    public var wireRelation: RelatesTo? {
        guard
            let raw = content["m.relates_to"],
            let data = try? JSONEncoder().encode(raw),
            let decoded = try? JSONDecoder().decode(RelatesTo.self, from: data)
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

// MARK: - Markdown to Matrix HTML (formatted_body generation)

/// Generates the Matrix HTML subset from markdown for `formatted_body`.
///
/// Block constructs: paragraphs, headings, bullet and ordered lists,
/// block quotes, fenced code blocks, and thematic breaks. Inline
/// constructs: bold, italic, strikethrough, inline code, and links.
///
/// Literal text — including anything that looks like inline HTML — is
/// HTML-escaped, and bare URLs are not autolinked; compose links with
/// explicit markdown `[text](url)` syntax. Nested lists render as
/// sibling list items.
public enum MatrixHTMLGenerator {
    /// HTML-escapes literal text.
    static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }

    /// Converts markdown to the Matrix HTML subset. Unparseable input is
    /// escaped verbatim.
    public static func html(fromMarkdown markdown: String) -> String {
        let attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: markdown, options: .init(interpretedSyntax: .full))
        } catch {
            return escape(markdown)
        }
        guard !attributed.runs.isEmpty else { return "" }
        return renderBlocks(blocks(in: attributed))
    }

    // MARK: - Block splitting

    /// Normalized block kind (associated values lifted out separately).
    private enum BlockKind: Hashable {
        case paragraph
        case header
        case listItem
        case orderedList
        case unorderedList
        case codeBlock
        case blockQuote
        case thematicBreak
        case other
    }

    /// One presentation-intent component: its kind, the identity shared
    /// by all runs of its block, and kind-specific payloads.
    private struct BlockComponent {
        var kind: BlockKind
        var identity: Int
        var level: Int?
        var ordinal: Int?
        var languageHint: String?
    }

    /// One styled run of the parsed markdown.
    private struct SourceRun {
        var text: String
        var components: [BlockComponent]
        var inline: InlinePresentationIntent
        var link: URL?
    }

    private static func blockComponent(
        from component: PresentationIntent.IntentType
    ) -> BlockComponent {
        switch component.kind {
        case .paragraph:
            return BlockComponent(
                kind: .paragraph, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        case .header(let level):
            return BlockComponent(
                kind: .header, identity: component.identity, level: level,
                ordinal: nil, languageHint: nil)
        case .listItem(let ordinal):
            return BlockComponent(
                kind: .listItem, identity: component.identity, level: nil,
                ordinal: ordinal, languageHint: nil)
        case .orderedList:
            return BlockComponent(
                kind: .orderedList, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        case .unorderedList:
            return BlockComponent(
                kind: .unorderedList, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        case .codeBlock(let languageHint):
            return BlockComponent(
                kind: .codeBlock, identity: component.identity, level: nil,
                ordinal: nil, languageHint: languageHint)
        case .blockQuote:
            return BlockComponent(
                kind: .blockQuote, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        case .thematicBreak:
            return BlockComponent(
                kind: .thematicBreak, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        @unknown default:
            return BlockComponent(
                kind: .other, identity: component.identity, level: nil,
                ordinal: nil, languageHint: nil)
        }
    }

    /// Splits runs into blocks. Runs belonging to one block share the same
    /// presentation-intent component identities; a change marks a boundary.
    private static func blocks(in attributed: AttributedString) -> [[SourceRun]] {
        var current: [SourceRun] = []
        var blocks: [[SourceRun]] = []
        var currentIdentities: [Int] = []

        for run in attributed.runs {
            let sourceRun = SourceRun(
                text: String(attributed[run.range].characters),
                components: (run.presentationIntent?.components ?? []).map(
                    blockComponent(from:)),
                inline: run.inlinePresentationIntent ?? [],
                link: run.link)
            let identities = sourceRun.components.map(\.identity)
            if !current.isEmpty && identities != currentIdentities {
                blocks.append(current)
                current = []
            }
            if current.isEmpty { currentIdentities = identities }
            current.append(sourceRun)
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    // MARK: - Block rendering

    private static func renderBlocks(_ blocks: [[SourceRun]]) -> String {
        var output: [String] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            let components = block.first?.components ?? []
            let kinds = Set(components.map(\.kind))

            if kinds.contains(.codeBlock) {
                output.append(renderCodeBlock(block, components: components))
                index += 1
            } else if kinds.contains(.thematicBreak) {
                output.append("<hr />")
                index += 1
            } else if kinds.contains(.listItem) {
                let (list, next) = renderList(blocks, from: index)
                output.append(list)
                index = next
            } else if kinds.contains(.blockQuote) {
                let (quote, next) = renderQuote(blocks, from: index)
                output.append(quote)
                index = next
            } else if kinds.contains(.header) {
                let level = min(
                    max(components.compactMap(\.level).first ?? 1, 1), 6)
                output.append("<h\(level)>\(renderInline(block))</h\(level)>")
                index += 1
            } else {
                output.append("<p>\(renderInline(block))</p>")
                index += 1
            }
        }
        return output.joined(separator: "\n")
    }

    private static func renderCodeBlock(
        _ block: [SourceRun], components: [BlockComponent]
    ) -> String {
        var code = "<pre><code"
        if let hint = components.compactMap(\.languageHint).first {
            code += " class=\"language-\(escape(hint))\""
        }
        code += ">\(escape(block.map(\.text).joined()))</code></pre>"
        return code
    }

    /// Renders consecutive `listItem` blocks sharing one list container
    /// identity as a single `<ul>`/`<ol>`.
    private static func renderList(
        _ blocks: [[SourceRun]], from start: Int
    ) -> (String, Int) {
        let firstComponents = blocks[start].first?.components ?? []
        let ordered = Set(firstComponents.map(\.kind)).contains(.orderedList)
        let containerIdentity = firstComponents.last?.identity

        var items: [String] = []
        var index = start
        while index < blocks.count {
            let components = blocks[index].first?.components ?? []
            guard Set(components.map(\.kind)).contains(.listItem),
                components.last?.identity == containerIdentity
            else { break }
            items.append("<li>\(renderInline(blocks[index]))</li>")
            index += 1
        }

        let tag = ordered ? "ol" : "ul"
        var openTag = "<\(tag)"
        if ordered, let ordinal = firstComponents.compactMap(\.ordinal).first,
            ordinal > 1
        {
            openTag += " start=\"\(ordinal)\""
        }
        return ("\(openTag)>\n\(items.joined(separator: "\n"))\n</\(tag)>", index)
    }

    /// Renders consecutive blocks sharing a `blockQuote` container identity
    /// as a single `<blockquote>`.
    private static func renderQuote(
        _ blocks: [[SourceRun]], from start: Int
    ) -> (String, Int) {
        let quoteIdentity = blocks[start].first?.components.last?.identity
        var inner: [[SourceRun]] = []
        var index = start
        while index < blocks.count {
            let components = blocks[index].first?.components ?? []
            guard Set(components.map(\.kind)).contains(.blockQuote),
                components.last?.identity == quoteIdentity
            else { break }
            inner.append(
                blocks[index].map { run in
                    var run = run
                    run.components = .init(run.components.dropLast())
                    return run
                })
            index += 1
        }
        return ("<blockquote>\n\(renderBlocks(inner))\n</blockquote>", index)
    }

    // MARK: - Inline rendering

    private static func renderInline(_ runs: [SourceRun]) -> String {
        runs.map(renderRun).joined()
    }

    private static func renderRun(_ run: SourceRun) -> String {
        if run.inline.contains(.softBreak) && run.link == nil {
            return "\n"
        }

        if run.inline.contains(.code) {
            return "<code>\(escape(run.text))</code>"
        }

        var text = escape(run.text)
        if run.inline.contains(.strikethrough) { text = "<del>\(text)</del>" }
        if run.inline.contains(.emphasized) { text = "<em>\(text)</em>" }
        if run.inline.contains(.stronglyEmphasized) {
            text = "<strong>\(text)</strong>"
        }
        if let link = run.link {
            text = "<a href=\"\(escape(link.absoluteString))\">\(text)</a>"
        }
        return text
    }
}
