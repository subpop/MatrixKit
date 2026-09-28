import Foundation
import MatrixKit

/// A request as seen by the in-process spec harness.
public struct HarnessRequest: Sendable {
    public var method: String
    /// Path without the query string, still percent-encoded.
    public var path: String
    public var query: [String: String]
    /// Lowercased header names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Bearer token from `Authorization`, if the SDK attached one.
    public var bearer: String? {
        guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }

    /// Form-urlencoded body (`client_id=x&scope=y`) as a dictionary.
    public var formBody: [String: String] {
        var out: [String: String] = [:]
        guard let text = String(data: body, encoding: .utf8) else { return out }
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            // `+` encodes a space in form bodies.
            out[key] = value.replacingOccurrences(of: "+", with: " ")
        }
        return out
    }

    /// Decode the JSON body as an SDK model. Throws a 400-style harness
    /// response on failure so suites see spec-shaped errors, not crashes.
    public func decodeBody<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: body.isEmpty ? Data("{}".utf8) : body)
    }
}

/// A response the harness serves.
public struct HarnessResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Encode an SDK `Encodable` model as the JSON body.
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HarnessResponse {
        // The SDK's models carry explicit snake_case CodingKeys, so the
        // plain encoder produces wire-shaped JSON with no key strategy.
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HarnessResponse(status: status, body: data)
    }

    /// Raw JSON text (for fixtures and error bodies).
    public static func raw(_ json: String, status: Int = 200) -> HarnessResponse {
        HarnessResponse(status: status, body: Data(json.utf8))
    }

    /// Raw bytes (media downloads, thumbnails).
    public static func bytes(_ data: Data, status: Int = 200, contentType: String = "application/octet-stream") -> HarnessResponse {
        HarnessResponse(status: status, headers: ["Content-Type": contentType], body: data)
    }

    /// A standard Matrix error body (`errcode` + `error`).
    public static func matrixError(code: String, message: String, status: Int, retryAfterMs: Int? = nil) -> HarnessResponse {
        .json(MatrixErrorBody(errcode: code, error: message, retryAfterMs: retryAfterMs), status: status)
    }
}
