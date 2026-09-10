/// Shared model primitives: type-erased JSON, error bodies, pagination.

/// A type-erased, `Sendable` JSON value for passthrough event content
/// (state events, account data, ...).
public enum AnyCodable: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodable])
    case object([String: AnyCodable])
}

extension AnyCodable: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([AnyCodable].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: AnyCodable].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension AnyCodable {
    /// The value if `.string`.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The value if `.int`.
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// The value if `.bool`.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The value if `.object`.
    public var objectValue: [String: AnyCodable]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The value if `.array`.
    public var arrayValue: [AnyCodable]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Subscript into `.object` values (nil for other cases or missing keys).
    public subscript(key: String) -> AnyCodable? {
        objectValue?[key]
    }
}

/// Standard Matrix error response body (`errcode` + `error`).
public struct MatrixErrorBody: Hashable, Sendable, Codable {
    /// Machine-readable code (`M_FORBIDDEN`, `M_LIMIT_EXCEEDED`, …).
    public var errcode: String
    /// Human-readable message.
    public var error: String
    /// Retry delay hint for rate limits, in milliseconds.
    public var retryAfterMs: Int?

    public init(errcode: String, error: String, retryAfterMs: Int? = nil) {
        self.errcode = errcode
        self.error = error
        self.retryAfterMs = retryAfterMs
    }
}

/// A paginated chunk of events (`GET /messages`, `GET /context`, ...).
public struct PaginationChunk<Event: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    /// Pagination cursor for the start of this chunk.
    public var start: String
    /// Cursor for the next page, if more history exists.
    public var end: String?
    /// Events in this page.
    public var chunk: [Event]

    public init(start: String, end: String? = nil, chunk: [Event] = []) {
        self.start = start
        self.end = end
        self.chunk = chunk
    }
}

/// A lightweight event pointer (`event_id` only).
public struct EventReference: Hashable, Sendable, Codable {
    /// The referenced event's ID.
    public var eventId: EventId

    public init(eventId: EventId) {
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }
}

/// `.well-known/matrix/client` discovery document.
public struct ClientWellKnown: Hashable, Sendable, Codable {
    /// Homeserver delegation info.
    public var homeserver: HomeserverInfo
    /// Identity-server delegation info, if advertised.
    public var identityServer: IdentityServerInfo?

    public init(homeserver: HomeserverInfo, identityServer: IdentityServerInfo? = nil) {
        self.homeserver = homeserver
        self.identityServer = identityServer
    }

    private enum CodingKeys: String, CodingKey {
        case homeserver = "m.homeserver"
        case identityServer = "m.identity_server"
    }
}

/// The `m.homeserver` section of a well-known document.
public struct HomeserverInfo: Hashable, Sendable, Codable {
    /// Base URL clients should use (may differ from the well-known host).
    public var baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
    }
}

/// The `m.identity_server` section of a well-known document.
public struct IdentityServerInfo: Hashable, Sendable, Codable {
    /// Base URL of the delegated identity server.
    public var baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
    }
}
