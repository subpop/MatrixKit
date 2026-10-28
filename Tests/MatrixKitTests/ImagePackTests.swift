#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing

import MatrixKitTesting
@testable import MatrixKit
import MatrixKitSwiftData

/// `m.room.image_pack` / `m.image_pack.rooms`: content decoding, folding
/// onto the store, and the spec's source priority when resolving the packs
/// available in a room.
@Suite("ImagePack")
@MainActor
struct ImagePackTests {
    // MARK: - Tables

    struct DecodeCase: Sendable {
        var id: String
        var json: String
        var imageCount: Int
        var usage: [ImagePackUsage]?
        var supportsSticker: Bool
        var supportsEmoticon: Bool
    }

    nonisolated static let decodeCases: [DecodeCase] = [
        DecodeCase(
            id: "no usage serves every usage",
            json: #"{"images":{"a":{"url":"mxc://x/a"}}}"#,
            imageCount: 1, usage: nil, supportsSticker: true, supportsEmoticon: true),
        DecodeCase(
            id: "empty usage serves every usage",
            json: #"{"images":{"a":{"url":"mxc://x/a"}},"pack":{"usage":[]}}"#,
            imageCount: 1, usage: [], supportsSticker: true, supportsEmoticon: true),
        DecodeCase(
            id: "sticker only",
            json: #"{"images":{"a":{"url":"mxc://x/a"}},"pack":{"usage":["sticker"]}}"#,
            imageCount: 1, usage: [.sticker], supportsSticker: true, supportsEmoticon: false),
        DecodeCase(
            id: "unknown usage values are dropped",
            json: #"{"images":{"a":{"url":"mxc://x/a"}},"pack":{"usage":["emoticon","avatar"]}}"#,
            imageCount: 1, usage: [.emoticon], supportsSticker: false, supportsEmoticon: true),
        DecodeCase(
            id: "image without url is dropped",
            json: #"{"images":{"ok":{"url":"mxc://x/a"},"bad":{"body":"no url"}}}"#,
            imageCount: 1, usage: nil, supportsSticker: true, supportsEmoticon: true),
        DecodeCase(
            id: "malformed shortcode is kept",
            json: #"{"images":{"not valid:":{"url":"mxc://x/a"}}}"#,
            imageCount: 1, usage: nil, supportsSticker: true, supportsEmoticon: true),
        DecodeCase(
            id: "malformed pack metadata does not drop images",
            json: #"{"images":{"a":{"url":"mxc://x/a"}},"pack":"oops"}"#,
            imageCount: 1, usage: nil, supportsSticker: true, supportsEmoticon: true),
    ]

    struct ResolveCase: Sendable {
        var id: String
        /// Expected `"<source>:<roomId>|<stateKey>"` entries, in order.
        var expected: [String]
    }

    nonisolated static let resolveCases: [ResolveCase] = [
        ResolveCase(id: "room packs sort by state key", expected: [
            "room:!room:x|a", "room:!room:x|b",
        ]),
        ResolveCase(id: "user packs come before room packs", expected: [
            "user:!other:x|fav", "room:!room:x|own",
        ]),
        ResolveCase(id: "a pack from several sources appears once, at the highest", expected: [
            "user:!room:x|own",
        ]),
        ResolveCase(id: "canonical space packs come last", expected: [
            "room:!room:x|own", "space:!space:x|shared",
        ]),
        ResolveCase(id: "space packs need a joined space", expected: [
            "room:!room:x|own",
        ]),
        ResolveCase(id: "space ancestors are followed recursively", expected: [
            "space:!space:x|near", "space:!root:x|far",
        ]),
        ResolveCase(id: "space cycles terminate", expected: [
            "space:!space:x|shared",
        ]),
        ResolveCase(id: "clearing a pack removes it", expected: []),
        ResolveCase(id: "a room listed without state keys has no packs", expected: []),
        ResolveCase(id: "packs from left rooms are not offered", expected: []),
        ResolveCase(id: "unreferenced packs are not offered globally", expected: []),
    ]

    struct StickerCase: Sendable {
        var id: String
        var image: ImagePackImage
        var shortcode: String
        var body: String
        var info: MediaInfo
    }

    nonisolated static let stickerCases: [StickerCase] = [
        StickerCase(
            id: "body and info are copied",
            image: ImagePackImage(
                url: "mxc://x/a", body: "a waving cat",
                info: MediaInfo(mimeType: "image/png", width: 512, height: 512)),
            shortcode: "cat_wave", body: "a waving cat",
            info: MediaInfo(mimeType: "image/png", width: 512, height: 512)),
        StickerCase(
            id: "a missing body falls back to the shortcode",
            image: ImagePackImage(url: "mxc://x/a"),
            shortcode: "cat_nap", body: "cat_nap", info: MediaInfo()),
        StickerCase(
            id: "animation flag is preserved",
            image: ImagePackImage(
                url: "mxc://x/a", body: "spin", info: MediaInfo(isAnimated: true)),
            shortcode: "spin", body: "spin", info: MediaInfo(isAnimated: true)),
    ]

    struct ShortcodeCase: Sendable {
        var id: String
        var shortcode: String
        var isValid: Bool
    }

    nonisolated static let shortcodeCases: [ShortcodeCase] = [
        ShortcodeCase(id: "letters, digits, dash, underscore", shortcode: "Cat_wave-2", isValid: true),
        ShortcodeCase(id: "single character", shortcode: "a", isValid: true),
        ShortcodeCase(id: "100 bytes", shortcode: String(repeating: "a", count: 100), isValid: true),
        ShortcodeCase(id: "101 bytes", shortcode: String(repeating: "a", count: 101), isValid: false),
        ShortcodeCase(id: "empty", shortcode: "", isValid: false),
        ShortcodeCase(id: "colon", shortcode: "cat:wave", isValid: false),
        ShortcodeCase(id: "slash", shortcode: "cat/wave", isValid: false),
        ShortcodeCase(id: "space", shortcode: "cat wave", isValid: false),
        ShortcodeCase(id: "dot", shortcode: "cat.wave", isValid: false),
        ShortcodeCase(id: "non-ASCII letter", shortcode: "café", isValid: false),
    ]

    // MARK: - Helpers

    private static let room = RoomId(unchecked: "!room:x")

    private func packEvent(
        _ stateKey: String, id: String = "$p", cleared: Bool = false,
        pack: [String: AnyCodable]? = nil
    ) -> MessageEvent {
        var content: [String: AnyCodable] = [:]
        if !cleared {
            content["images"] = .object([
                "wave": .object(["url": .string("mxc://x/\(stateKey)"), "body": .string("Wave")])
            ])
            if let pack { content["pack"] = .object(pack) }
        }
        return stateEvent(
            type: ImagePack.roomEventType, stateKey: stateKey, id: id + stateKey,
            content: content)
    }

    private func references(_ rooms: [String: [String]]) -> BasicEvent {
        BasicEvent(
            type: ImagePack.userAccountDataType,
            content: [
                "rooms": .object(
                    rooms.mapValues { keys in
                        .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, .object([:])) }))
                    })
            ])
    }

    private func spaceParent(_ id: String, canonical: Bool = true) -> MessageEvent {
        stateEvent(
            type: "m.space.parent", stateKey: id, id: "$sp" + id,
            content: ["canonical": .bool(canonical), "via": .array([.string("x")])])
    }

    private func name(_ value: String) -> MessageEvent {
        stateEvent(type: "m.room.name", id: "$n", content: ["name": .string(value)])
    }

    /// Applies the scenario for `id` to a fresh store.
    private func populate(_ id: String, writer: MatrixStoreWriter) async throws {
        func joined(_ rooms: [String: [MessageEvent]], accountData: [BasicEvent] = []) -> SyncDelta {
            SyncDelta(
                nextBatch: BatchToken("s"),
                joined: Dictionary(
                    uniqueKeysWithValues: rooms.map {
                        (RoomId(unchecked: $0.key), JoinedRoomDelta(state: $0.value))
                    }),
                accountData: accountData)
        }
        switch id {
        case "room packs sort by state key":
            try await writer.apply(joined(["!room:x": [packEvent("b"), packEvent("a")]]))
        case "user packs come before room packs":
            try await writer.apply(joined(
                ["!room:x": [packEvent("own")], "!other:x": [packEvent("fav"), packEvent("skipped")]],
                accountData: [references(["!other:x": ["fav"]])]))
        case "a pack from several sources appears once, at the highest":
            try await writer.apply(joined(
                ["!room:x": [packEvent("own")]],
                accountData: [references(["!room:x": ["own"]])]))
        case "canonical space packs come last":
            try await writer.apply(joined([
                "!room:x": [packEvent("own"), spaceParent("!space:x")],
                "!space:x": [packEvent("shared")],
            ]))
        case "space packs need a joined space":
            try await writer.apply(joined(["!room:x": [packEvent("own"), spaceParent("!space:x")]]))
        case "space ancestors are followed recursively":
            try await writer.apply(joined([
                "!room:x": [spaceParent("!space:x")],
                "!space:x": [packEvent("near"), spaceParent("!root:x")],
                "!root:x": [packEvent("far")],
            ]))
        case "space cycles terminate":
            try await writer.apply(joined([
                "!room:x": [spaceParent("!space:x")],
                "!space:x": [packEvent("shared"), spaceParent("!room:x")],
            ]))
        case "clearing a pack removes it":
            try await writer.apply(joined(["!room:x": [packEvent("a")]]))
            try await writer.apply(joined(["!room:x": [packEvent("a", cleared: true)]]))
        case "a room listed without state keys has no packs":
            try await writer.apply(joined(
                ["!other:x": [packEvent("fav")], "!room:x": []],
                accountData: [references(["!other:x": []])]))
        case "packs from left rooms are not offered":
            try await writer.apply(joined(
                ["!other:x": [packEvent("fav")], "!room:x": []],
                accountData: [references(["!other:x": ["fav"]])]))
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s2"),
                left: [RoomId(unchecked: "!other:x"): LeftRoomDelta()]))
        case "unreferenced packs are not offered globally":
            try await writer.apply(joined(["!other:x": [packEvent("fav")], "!room:x": []]))
        default:
            Issue.record("unhandled scenario \(id)")
        }
    }

    // MARK: - Tests

    @Test("Image pack content decodes leniently", arguments: decodeCases)
    func decoding(_ row: DecodeCase) throws {
        let content = try JSONDecoder().decode(
            ImagePackContent.self, from: Data(row.json.utf8))
        #expect(content.images.count == row.imageCount)
        #expect(content.pack?.usage == row.usage)
        let pack = ImagePack(
            roomId: Self.room, stateKey: "", source: .room, content: content)
        #expect(pack.supports(.sticker) == row.supportsSticker)
        #expect(pack.supports(.emoticon) == row.supportsEmoticon)
    }

    @Test("Pack images become m.sticker content", arguments: stickerCases)
    func stickerContent(_ row: StickerCase) {
        let content = row.image.stickerContent(shortcode: row.shortcode)
        #expect(content.body == row.body)
        #expect(content.url == row.image.url)
        #expect(content.info == row.info)
    }

    @Test("A pack image without info encodes an empty info object")
    func emptyInfoEncoding() throws {
        let content = ImagePackImage(url: "mxc://x/a").stickerContent(shortcode: "a")
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(content)) as? [String: Any])
        let info = try #require(object["info"] as? [String: Any])
        #expect(info.isEmpty)
        #expect(object["body"] as? String == "a")
        #expect(object["url"] as? String == "mxc://x/a")
    }

    @Test("Shortcodes follow the spec grammar", arguments: shortcodeCases)
    func shortcodeGrammar(_ row: ShortcodeCase) {
        #expect(ImagePack.isValidShortcode(row.shortcode) == row.isValid)
    }

    @Test("Stored account data reads back by type")
    func storedAccountData() async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            accountData: [BasicEvent(type: "x.test", content: ["k": .string("v")])]))
        let reader = MatrixStoreReader(modelContainer: container)
        #expect(try reader.accountData("x.test")?["k"]?.stringValue == "v")
        #expect(try reader.accountData("x.absent") == nil)
    }

    @Test("Pack images keep their body and info")
    func imageFields() throws {
        let json = """
            {"images":{"cat_wave":{"body":"a waving cat","url":"mxc://x/c",
            "info":{"w":512,"h":512,"mimetype":"image/webp","is_animated":true}}},
            "pack":{"display_name":"Cats","attribution":"alice","avatar_url":"mxc://x/av"}}
            """
        let content = try JSONDecoder().decode(ImagePackContent.self, from: Data(json.utf8))
        let image = try #require(content.images["cat_wave"])
        #expect(image.body == "a waving cat")
        #expect(image.info?.width == 512)
        #expect(image.info?.mimeType == "image/webp")
        #expect(image.info?.isAnimated == true)
        #expect(content.pack?.displayName == "Cats")
        #expect(content.pack?.attribution == "alice")
        #expect(content.pack?.avatarUrl == "mxc://x/av")
    }

    @Test("Resolution follows the spec's source priority", arguments: resolveCases)
    func resolution(_ row: ResolveCase) async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        try await populate(row.id, writer: writer)

        let packs = try MatrixStoreReader(modelContainer: container)
            .imagePacks(for: Self.room)
        let sources: [ImagePackSource: String] = [.user: "user", .room: "room", .space: "space"]
        #expect(packs.map { "\(sources[$0.source] ?? "?"):\($0.id)" } == row.expected)
    }

    @Test("Packs without metadata take the room's name and avatar")
    func roomFallback() async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [
                Self.room: JoinedRoomDelta(state: [
                    name("Cats"),
                    stateEvent(
                        type: "m.room.avatar", id: "$av",
                        content: ["url": .string("mxc://x/room")]),
                    packEvent("bare"),
                    packEvent("named", pack: ["display_name": .string("Dogs")]),
                ])
            ]))

        let packs = try MatrixStoreReader(modelContainer: container).imagePacks(for: Self.room)
        let bare = try #require(packs.first { $0.stateKey == "bare" })
        let named = try #require(packs.first { $0.stateKey == "named" })
        #expect(bare.displayName == "Cats")
        #expect(bare.avatarUrl == "mxc://x/room")
        #expect(named.displayName == "Dogs")
        #expect(named.avatarUrl == "mxc://x/room")
    }

    @Test("Refreshing from full state adds missing packs and drops stale ones")
    func refreshFromState() async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        let reader = MatrixStoreReader(modelContainer: container)
        // The room was synced before it had any pack rows; one stale row exists.
        try await writer.apply(SyncDelta(
            nextBatch: BatchToken("s"),
            joined: [Self.room: JoinedRoomDelta(state: [packEvent("stale")])]))

        try await writer.refreshImagePacks(
            roomId: Self.room,
            state: [
                packEvent("fresh"),
                packEvent("cleared", cleared: true),
                stateEvent(type: "m.room.name", id: "$n", content: ["name": .string("Cats")]),
            ])

        let packs = try reader.imagePacks(for: Self.room)
        #expect(packs.map(\.stateKey) == ["fresh"])
        // Unrelated state in the response is not folded in.
        #expect(packs.first?.displayName == nil)
    }

    @Test("Refreshing an unknown room stores nothing")
    func refreshUnknownRoom() async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        try await writer.refreshImagePacks(
            roomId: RoomId(unchecked: "!unknown:x"), state: [packEvent("a")])
        let reader = MatrixStoreReader(modelContainer: container)
        #expect(try reader.imagePacks(for: RoomId(unchecked: "!unknown:x")).isEmpty)
    }

    @Test("Updating a pack replaces its content")
    func update() async throws {
        let container = try MatrixStore.makeInMemory()
        let writer = MatrixStoreWriter(modelContainer: container)
        for title in ["Old", "New"] {
            try await writer.apply(SyncDelta(
                nextBatch: BatchToken("s"),
                joined: [
                    Self.room: JoinedRoomDelta(state: [
                        packEvent("a", pack: ["display_name": .string(title)])
                    ])
                ]))
        }
        let packs = try MatrixStoreReader(modelContainer: container).imagePacks(for: Self.room)
        #expect(packs.map(\.displayName) == ["New"])
    }
}
#endif
