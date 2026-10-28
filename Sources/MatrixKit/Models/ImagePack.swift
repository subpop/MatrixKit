import Foundation

/// What an image pack's images are intended for (`pack.usage`).
public enum ImagePackUsage: String, Hashable, Sendable, Codable {
    /// Images sent inline in a message's `formatted_body`.
    case emoticon
    /// Images sent as standalone `m.sticker` events.
    case sticker
}

/// One image in an `m.room.image_pack`, keyed by shortcode in the pack.
public struct ImagePackImage: Hashable, Sendable, Codable {
    /// `mxc://` URI of the image.
    public var url: String
    /// Description of the image: the `alt` of an emoticon, the `body` of a
    /// sticker. Absent bodies fall back to the shortcode when sending.
    public var body: String?
    /// Image metadata, copied into the `m.sticker` event when sent.
    public var info: MediaInfo?

    public init(url: String, body: String? = nil, info: MediaInfo? = nil) {
        self.url = url
        self.body = body
        self.info = info
    }
}

extension ImagePackImage {
    /// The `m.sticker` content for sending this image as a sticker: the
    /// image's `body` (or its shortcode when it has none) and its `info`
    /// (or an empty one).
    public func stickerContent(shortcode: String) -> StickerContent {
        StickerContent(body: body ?? shortcode, url: url, info: info ?? MediaInfo())
    }
}

extension ImagePack {
    /// Longest permitted shortcode, in bytes.
    public static let maxShortcodeLength = 100

    /// Whether `shortcode` matches the spec grammar: 1 to 100 ASCII letters,
    /// digits, `-`, or `_`. Clients should enforce this when creating or
    /// editing packs, while still rendering malformed shortcodes found in
    /// packs made elsewhere.
    public static func isValidShortcode(_ shortcode: String) -> Bool {
        let bytes = shortcode.utf8
        return (1...maxShortcodeLength).contains(bytes.count)
            && bytes.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                    || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
            }
    }
}

/// Pack-level metadata (`pack` in `m.room.image_pack`).
public struct ImagePackMeta: Hashable, Sendable, Codable {
    public var displayName: String?
    /// `mxc://` URI of the pack's avatar.
    public var avatarUrl: String?
    public var attribution: String?
    /// Intended usages. Absent or empty means every usage; unrecognized
    /// values are dropped.
    public var usage: [ImagePackUsage]?

    public init(
        displayName: String? = nil, avatarUrl: String? = nil,
        attribution: String? = nil, usage: [ImagePackUsage]? = nil
    ) {
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.attribution = attribution
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case attribution
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        attribution = try container.decodeIfPresent(String.self, forKey: .attribution)
        usage = try container.decodeIfPresent([String].self, forKey: .usage)?
            .compactMap(ImagePackUsage.init(rawValue:))
    }
}

/// Content of an `m.room.image_pack` state event.
public struct ImagePackContent: Hashable, Sendable, Codable {
    /// Images keyed by shortcode. Entries without a usable `url` are
    /// dropped; shortcodes that break the spec grammar are kept so users
    /// can find and correct them.
    public var images: [String: ImagePackImage]
    /// Absent when the pack takes its name and avatar from its room.
    public var pack: ImagePackMeta?

    public init(images: [String: ImagePackImage] = [:], pack: ImagePackMeta? = nil) {
        self.images = images
        self.pack = pack
    }

    private enum CodingKeys: String, CodingKey {
        case images
        case pack
    }

    /// Decodes an image that may be malformed into nil instead of failing
    /// the whole pack.
    private struct Lossy: Decodable {
        var image: ImagePackImage?
        init(from decoder: Decoder) throws {
            image = try? ImagePackImage(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try container.decodeIfPresent([String: Lossy].self, forKey: .images) ?? [:]
        images = lossy.compactMapValues(\.image)
        pack = try? container.decodeIfPresent(ImagePackMeta.self, forKey: .pack)
    }
}

/// Where a resolved image pack came from, in descending priority.
public enum ImagePackSource: Int, Hashable, Sendable, Comparable {
    /// Enabled globally in the user's `m.image_pack.rooms` account data.
    case user
    /// Defined in the room being viewed.
    case room
    /// Defined in a canonical space of the room being viewed.
    case space

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An image pack available in a room, with its name and avatar resolved.
public struct ImagePack: Hashable, Sendable, Identifiable {
    /// Room-scoped state event type (`m.room.image_pack`).
    public static let roomEventType = "m.room.image_pack"
    /// Account-data type listing the packs a user enabled globally.
    public static let userAccountDataType = "m.image_pack.rooms"

    /// Room whose state defines the pack.
    public var roomId: RoomId
    /// State key identifying the pack within its room.
    public var stateKey: String
    public var source: ImagePackSource
    public var content: ImagePackContent
    /// Pack display name, falling back to the defining room's name.
    public var displayName: String?
    /// Pack avatar `mxc://` URI, falling back to the defining room's avatar.
    public var avatarUrl: String?

    public var id: String { "\(roomId.value)|\(stateKey)" }

    public init(
        roomId: RoomId, stateKey: String, source: ImagePackSource,
        content: ImagePackContent, displayName: String? = nil, avatarUrl: String? = nil
    ) {
        self.roomId = roomId
        self.stateKey = stateKey
        self.source = source
        self.content = content
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    /// Whether the pack's images are intended for `usage`. Packs without a
    /// declared usage serve every usage.
    public func supports(_ usage: ImagePackUsage) -> Bool {
        guard let declared = content.pack?.usage, !declared.isEmpty else { return true }
        return declared.contains(usage)
    }
}
