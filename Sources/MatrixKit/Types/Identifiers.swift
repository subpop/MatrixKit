/// Strongly-typed Matrix identifiers.
///
/// Matrix identifiers (user IDs, room IDs, event IDs, ...) are opaque strings
/// with a sigil prefix (`@`, `!`, `$`, ...). These wrappers prevent mixing them
/// up at compile time. All types validate their sigil on construction and are
/// `Codable` as their wrapped string value.
import Foundation

/// A Matrix user ID: `@localpart:server` (e.g. `@alice:example.com`).
public struct UserId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws(MatrixError) {
        guard value.hasPrefix("@"), value.contains(":") else {
            throw .invalidIdentifier("Not a user ID: \(value)")
        }
        self.value = value
    }

    /// Unsafely construct without validation. Use in tests and when the
    /// server is trusted to return well-formed IDs.
    public init(unchecked value: String) {
        self.value = value
    }

    /// The localpart (`alice` in `@alice:example.com`), if parseable.
    public var localpart: String? {
        guard value.hasPrefix("@") else { return nil }
        let rest = value.dropFirst()
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<colon])
    }

    /// The server name (`example.com` in `@alice:example.com`), if parseable.
    public var serverName: String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        return String(value[value.index(after: colon)...])
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(unchecked: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Matrix room ID: `!opaque:server` (e.g. `!abc123:example.com`).
public struct RoomId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws(MatrixError) {
        guard value.hasPrefix("!"), value.contains(":") else {
            throw .invalidIdentifier("Not a room ID: \(value)")
        }
        self.value = value
    }

    public init(unchecked value: String) {
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(unchecked: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Matrix room alias: `#alias:server` (e.g. `#general:example.com`).
public struct RoomAlias: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws(MatrixError) {
        guard value.hasPrefix("#"), value.contains(":") else {
            throw .invalidIdentifier("Not a room alias: \(value)")
        }
        self.value = value
    }

    public init(unchecked value: String) {
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(unchecked: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Matrix event ID: `$opaque:server` (room v1/v2) or `$opaque` (room v3+).
public struct EventId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws(MatrixError) {
        guard value.hasPrefix("$") else {
            throw .invalidIdentifier("Not an event ID: \(value)")
        }
        self.value = value
    }

    public init(unchecked value: String) {
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(unchecked: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Matrix device ID (opaque string assigned by the server).
public struct DeviceId: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A Matrix session/login token wrapper for type safety at call sites.
public struct AccessToken: Hashable, Sendable, Codable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A `mxc://` content URI pointing at uploaded media.
public struct MXCURI: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws(MatrixError) {
        guard value.hasPrefix("mxc://") else {
            throw .invalidIdentifier("Not an MXC URI: \(value)")
        }
        self.value = value
    }

    public init(unchecked value: String) {
        self.value = value
    }

    /// The server and media ID components (`server/mediaId`), if parseable.
    public var components: (server: String, mediaId: String)? {
        let rest = value.dropFirst("mxc://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let server = String(rest[..<slash])
        let mediaId = String(rest[rest.index(after: slash)...])
        guard !server.isEmpty, !mediaId.isEmpty else { return nil }
        return (server, mediaId)
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(unchecked: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A client-generated transaction ID used to deduplicate `PUT` sends.
public struct TransactionId: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Generate a fresh random transaction ID.
    public static func random() -> TransactionId {
        TransactionId(UUID().uuidString)
    }

    public var description: String { value }
}

/// A sync batch token (`since` / `next_batch`).
public struct BatchToken: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
