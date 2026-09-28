import Foundation

/// Percent-encode a single URL path segment (room IDs, user IDs, ...).
///
/// Produces exactly-once encoding: `MatrixTransport.buildURL` concatenates
/// the path verbatim and must NOT pass it through `appendingPathComponent`
/// or a `URLComponents` round-trip (both re-encode `%` and double-encode
/// segments — e.g. `%3A` becomes `%253A`).
///
/// Note: `:` is encoded even though it appears in `.urlPathAllowed` —
/// Foundation force-encodes it. Single `%3A` is valid; servers decode it.
extension String {
    /// Percent-encode for use as one URL path segment. Public so the
    /// MatrixRTC target can build its own request paths with the same
    /// exactly-once semantics as core clients.
    public var pathSegmentEncoded: String {
        addingPercentEncoding(
            withAllowedCharacters: .matrixPathSegmentAllowed) ?? self
    }

    /// Strict query key/value encoding: unreserved characters only, so
    /// filter JSON (`{"a":1}`) and `since` tokens can't break the query.
    var queryEncoded: String {
        addingPercentEncoding(
            withAllowedCharacters: .matrixQueryAllowed) ?? self
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters — the only set `addingPercentEncoding`
    /// is guaranteed to leave untouched.
    static let matrixQueryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Single path-segment set: `.urlPathAllowed` minus `/` (which must
    /// encode as `%2F` so base64 IDs like Megolm session IDs cannot
    /// smuggle extra segments into request paths) and minus `:` (kept
    /// encoded as `%3A`: Foundation force-encodes it for the stock set,
    /// and servers expect the encoded form). `+` stays literal: legal
    /// in segments, unlike in queries.
    static let matrixPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/:")
        return set
    }()
}

extension UserId {
    public var pathSegmentEncoded: String { value.pathSegmentEncoded }
}

extension RoomId {
    public var pathSegmentEncoded: String { value.pathSegmentEncoded }
}

extension RoomAlias {
    public var pathSegmentEncoded: String { value.pathSegmentEncoded }
}

extension EventId {
    public var pathSegmentEncoded: String { value.pathSegmentEncoded }
}
