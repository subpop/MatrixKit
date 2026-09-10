import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Actor wrapping `AsyncHTTPClient` for Matrix Client-Server API calls.
///
/// Single-shot requests (no automatic retry — callers own backoff). Maps
/// HTTP statuses and Matrix error bodies onto `MatrixError`.
public actor MatrixTransport {
    private let client: HTTPClient
    private let ownsClient: Bool
    private let homeserver: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var logger: Logger

    /// Maximum response body to buffer in memory (64 MiB). Initial syncs on
    /// large homeservers (matrix.org) can exceed 10 MiB of full room state;
    /// pair with a lean `SyncFilter` (lazy members, small timeline) instead.
    private let maxBodyBytes = 64 * 1024 * 1024

    /// Body bytes kept in error snippets (truncated). Trace logs render
    /// full redacted bodies instead.
    private let maxLogBytes = 2048

    /// Token refresher consulted when a homeserver API call fails with
    /// an unknown/expired token. Returns the current access token,
    /// refreshing first on a best-effort basis (failures are swallowed:
    /// a concurrent rotation may already have refreshed). Homeserver
    /// endpoints only — auth endpoints (`postForm`, `postJSON`) never
    /// retry, since refresh itself flows through them.
    private var tokenRefresher: (@Sendable () async -> String?)?

    /// Install the token refresher (wired by `MatrixClient` to
    /// `auth.refresh` plus the session token read).
    public func setTokenRefresher(_ refresher: (@Sendable () async -> String?)?) {
        tokenRefresher = refresher
    }

    /// JSON keys whose values are redacted in debug logs.
    private static let sensitiveKeys: Set<String> = [
        "password", "access_token", "refresh_token", "token", "session",
        "code", "device_code",
    ]

    /// Create a transport. Pass your own `HTTPClient` to share an event loop
    /// (you own shutdown then); otherwise one is created and owned.
    /// `logLevel`, when given, wins; otherwise `MATRIXKIT_LOG_LEVEL` /
    /// `MATRIXKIT_DEBUG=1` apply; otherwise the bootstrapped handler's
    /// own level governs (so consumers can bridge SDK logs into their
    /// own UI via `LoggingSystem.bootstrap`).
    public init(homeserver: URL, client: HTTPClient? = nil, logLevel: Logger.Level? = nil) {
        self.homeserver = homeserver
        if let client {
            self.client = client
            self.ownsClient = false
        } else {
            self.client = HTTPClient(eventLoopGroupProvider: .singleton)
            self.ownsClient = true
        }
        let decoder = JSONDecoder()
        self.decoder = decoder
        let encoder = JSONEncoder()
        self.encoder = encoder
        var logger = Logger(label: "MatrixKit.Transport")
        if let logLevel {
            logger.logLevel = logLevel
        } else {
            Self.applyConfiguredLevel(to: &logger)
        }
        self.logger = logger
    }

    /// Change the log level at runtime (e.g. from a CLI `debug` command).
    /// `.debug` logs friendly operation summaries ("Sent sync") plus
    /// failure diagnostics; `.trace` also logs raw HTTP traffic
    /// (request/response lines with full redacted bodies).
    public func setLogLevel(_ level: Logger.Level) {
        logger.logLevel = level
    }

    /// Log level from `MATRIXKIT_LOG_LEVEL` (trace/debug/info/...) or
    /// `MATRIXKIT_DEBUG=1` (→ debug). `nil` when neither is set, so the
    /// bootstrapped `LogHandler`'s own level governs.
    static func resolveLogLevel() -> Logger.Level? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MATRIXKIT_LOG_LEVEL"]?.lowercased(),
            let level = Logger.Level(rawValue: raw)
        {
            return level
        }
        if let debug = env["MATRIXKIT_DEBUG"]?.lowercased(),
            debug == "1" || debug == "true" || debug == "yes"
        {
            return .debug
        }
        return nil
    }

    /// Apply the env-configured level to a freshly created logger, if any.
    /// Call sites use this instead of assigning `resolveLogLevel()`
    /// unconditionally, so a consumer-installed handler keeps control of
    /// verbosity when the env is silent.
    static func applyConfiguredLevel(to logger: inout Logger) {
        if let level = resolveLogLevel() {
            logger.logLevel = level
        }
    }

    /// Release the underlying HTTP client if we created it. Must be called
    /// before the transport is deinitialized, otherwise AsyncHTTPClient traps.
    public func shutdown() async throws {
        if ownsClient {
            try await client.shutdown()
        }
    }

    // MARK: - Requests

    /// Send a JSON request and decode the JSON response.
    public func send<Response: Decodable>(
        _ method: HTTPMethod,
        path: String,
        query: [String: String]? = nil,
        body: (any Encodable)? = nil,
        accessToken: String? = nil,
        timeoutSeconds: Int = 30
    ) async throws(MatrixError) -> Response {
        do {
            let (status, data) = try await sendRaw(
                method, path: path, query: query, body: body,
                contentType: body == nil ? nil : "application/json",
                accessToken: accessToken, timeoutSeconds: timeoutSeconds
            )
            return try decodeResponse(status: status, data: data, path: path)
        } catch let error {
            guard error == .unknownToken else { throw error }
            // A concurrent rotation may still be in flight: one re-read
            // after a beat before concluding the session is dead.
            var freshToken: String?
            if let tokenRefresher {
                freshToken = await tokenRefresher()
                if freshToken == accessToken {
                    try? await Task.sleep(for: .milliseconds(500))
                    freshToken = await tokenRefresher()
                }
            }
            guard
                let freshToken, !freshToken.isEmpty, freshToken != accessToken
            else {
                throw error
            }
            logger.debug("Retrying \(method.rawValue) \(path) after token refresh")
            let (status, data) = try await sendRaw(
                method, path: path, query: query, body: body,
                contentType: body == nil ? nil : "application/json",
                accessToken: freshToken, timeoutSeconds: timeoutSeconds
            )
            return try decodeResponse(status: status, data: data, path: path)
        }
    }

    /// Send a request with raw bytes and return the raw response body.
    public func sendBytes(
        _ method: HTTPMethod,
        path: String,
        query: [String: String]? = nil,
        bytes: Data,
        contentType: String,
        accessToken: String? = nil,
        timeoutSeconds: Int = 60
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        let (status, data) = try await sendRaw(
            method, path: path, query: query, rawBody: bytes,
            contentType: contentType, accessToken: accessToken,
            timeoutSeconds: timeoutSeconds
        )
        if status == 401,
           let errorBody = try? decoder.decode(MatrixErrorBody.self, from: data),
           mapErrorBody(errorBody, status: status) == .unknownToken {
            var freshToken: String?
            if let tokenRefresher {
                freshToken = await tokenRefresher()
                if freshToken == accessToken {
                    try? await Task.sleep(for: .milliseconds(500))
                    freshToken = await tokenRefresher()
                }
            }
            if let freshToken, !freshToken.isEmpty, freshToken != accessToken {
                logger.debug("Retrying \(method.rawValue) \(path) after token refresh")
                return try await sendRaw(
                    method, path: path, query: query, rawBody: bytes,
                    contentType: contentType, accessToken: freshToken,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }
        return (status, data)
    }

    // MARK: - Internals

    private func sendRaw(
        _ method: HTTPMethod,
        path: String,
        query: [String: String]?,
        body: (any Encodable)? = nil,
        rawBody: Data? = nil,
        contentType: String?,
        accessToken: String?,
        timeoutSeconds: Int
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        let urlString = try buildURL(path: path, query: query)

        let bodyData: Data?
        if let rawBody {
            bodyData = rawBody
        } else if let body {
            do {
                bodyData = try encoder.encode(body)
            } catch {
                throw .encodingError(error.localizedDescription)
            }
        } else {
            bodyData = nil
        }
        // Full bodies log at trace level; skip the redact+serialize cost otherwise.
        let preview =
            logger.logLevel <= .trace
            ? bodyData.map { Self.redactedPreview($0, limit: nil) } : nil
        return try await execute(
            urlString: urlString, method: method, bodyData: bodyData,
            contentType: contentType, accessToken: accessToken,
            timeoutSeconds: timeoutSeconds, pathForLog: path,
            bodyPreview: preview
        )
    }

    /// POST form-urlencoded fields to an absolute URL. OAuth/OIDC issuer
    /// endpoints live outside the homeserver, and their error bodies aren't
    /// Matrix-shaped, so raw status + body are returned for the caller to
    /// map. The logged preview masks sensitive values.
    public func postForm(
        url: String,
        form: [String: String],
        timeoutSeconds: Int = 30
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        let pairs = form.sorted(by: { $0.key < $1.key })
        let bodyString = pairs
            .map { "\($0.key.queryEncoded)=\($0.value.queryEncoded)" }
            .joined(separator: "&")
        let preview = pairs
            .map { key, value in
                "\(key)=\(Self.sensitiveKeys.contains(key.lowercased()) ? "<redacted>" : value)"
            }
            .joined(separator: "&")
        return try await execute(
            urlString: url, method: .post, bodyData: Data(bodyString.utf8),
            contentType: "application/x-www-form-urlencoded",
            accessToken: nil, timeoutSeconds: timeoutSeconds,
            pathForLog: url, bodyPreview: preview
        )
    }

    /// POST a JSON body to an absolute URL, returning raw status + body
    /// (for non-Matrix-shaped endpoints such as RFC 7591 registration).
    public func postJSON(
        url: String,
        body: (any Encodable)? = nil,
        timeoutSeconds: Int = 30
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        let bodyData: Data?
        if let body {
            do {
                bodyData = try encoder.encode(body)
            } catch {
                throw .encodingError(error.localizedDescription)
            }
        } else {
            bodyData = nil
        }
        // Full bodies log at trace level; skip the redact+serialize cost otherwise.
        let preview =
            logger.logLevel <= .trace
            ? bodyData.map { Self.redactedPreview($0, limit: nil) } : nil
        return try await execute(
            urlString: url, method: .post, bodyData: bodyData,
            contentType: bodyData == nil ? nil : "application/json",
            accessToken: nil, timeoutSeconds: timeoutSeconds,
            pathForLog: url, bodyPreview: preview
        )
    }

    /// GET an absolute URL, returning raw status + body (for
    /// non-Matrix-shaped endpoints such as `.well-known/matrix/call`).
    /// The GET twin of `postJSON`.
    public func getData(
        url: String,
        timeoutSeconds: Int = 30
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        try await execute(
            urlString: url, method: .get, bodyData: nil,
            contentType: nil,
            accessToken: nil, timeoutSeconds: timeoutSeconds,
            pathForLog: url, bodyPreview: nil
        )
    }

    // MARK: - Server discovery

    /// `.well-known/matrix/client` document from the transport's base
    /// authority (spec §server discovery). Only meaningful pre-resolution,
    /// when the base is still the user-declared URL.
    public func wellKnown() async throws(MatrixError) -> ClientWellKnown {
        try await send(.get, path: "/.well-known/matrix/client", timeoutSeconds: 10)
    }

    /// Resolve a user-declared homeserver URL through
    /// `.well-known/matrix/client`: adopt a valid
    /// `m.homeserver.base_url` and validate it with `GET /versions`.
    /// Any failure (missing document, invalid base URL, failed validation)
    /// returns `declared` unchanged, so resolution never breaks login.
    public static func resolveHomeserver(declared: URL) async -> URL {
        guard declared.path == "/" || declared.path.isEmpty else { return declared }
        let probe = MatrixTransport(homeserver: declared)
        do {
            let document = try await probe.wellKnown()
            guard let candidate = Self.validatedBaseURL(document) else {
                try? await probe.shutdown()
                return declared
            }
            let check = MatrixTransport(homeserver: candidate)
            do {
                let _: ServerVersions = try await check.send(
                    .get, path: "/_matrix/client/versions", timeoutSeconds: 10)
                try? await probe.shutdown()
                try? await check.shutdown()
                return candidate
            } catch {
                try? await probe.shutdown()
                try? await check.shutdown()
                return declared
            }
        } catch {
            try? await probe.shutdown()
            return declared
        }
    }

    /// Test-seam twin of `resolveHomeserver`: `fetch` maps absolute request
    /// URLs to bodies (no network). Same adopt/validate/fallback rules.
    static func resolveHomeserver(
        declared: URL,
        fetch: (@Sendable (URL) async throws -> Data)
    ) async -> URL {
        guard declared.path == "/" || declared.path.isEmpty else { return declared }
        do {
            let body = try await fetch(declared.appending(path: ".well-known/matrix/client"))
            let document = try JSONDecoder().decode(ClientWellKnown.self, from: body)
            guard let candidate = Self.validatedBaseURL(document) else { return declared }
            let versions = try await fetch(candidate.appending(path: "_matrix/client/versions"))
            _ = try JSONDecoder().decode(ServerVersions.self, from: versions)
            return candidate
        } catch {
            return declared
        }
    }

    /// Adopt `m.homeserver.base_url` when it is an absolute URL with an
    /// https scheme (http allowed for loopback only). Anything else —
    /// relative, wrong scheme, missing host — yields nil (keep declared).
    static func validatedBaseURL(_ document: ClientWellKnown) -> URL? {
        guard let url = URL(string: document.homeserver.baseURL),
            let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty
        else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        return url
    }

    private func execute(
        urlString: String,
        method: HTTPMethod,
        bodyData: Data?,
        contentType: String?,
        accessToken: String?,
        timeoutSeconds: Int,
        pathForLog: String,
        bodyPreview: String?
    ) async throws(MatrixError) -> (status: Int, data: Data) {
        do {
            var request = HTTPClientRequest(url: urlString)
            request.method = NIOHTTP1.HTTPMethod(rawValue: method.rawValue)
            if let contentType {
                request.headers.add(name: "Content-Type", value: contentType)
            }
            request.headers.add(name: "Accept", value: "application/json")
            if let accessToken {
                request.headers.add(name: "Authorization", value: "Bearer \(accessToken)")
            }
            if let bodyData {
                request.body = .bytes(ByteBuffer(bytes: bodyData))
            }
            logger.trace("→ \(method.rawValue) \(urlString)")
            if logger.logLevel <= .trace {
                logger.trace("  headers: \(Self.redactedHeaders(request.headers))")
            }
            if let bodyPreview {
                logger.trace("  body: \(bodyPreview)")
            }
            let response = try await client.execute(
                request, timeout: .seconds(Int64(timeoutSeconds)))
            let buffer = try await response.body.collect(upTo: maxBodyBytes)
            let data = Data(buffer.readableBytesView)
            logger.trace(
                "← \(Int(response.status.code)) \(method.rawValue) \(pathForLog) (\(data.count) bytes)"
            )
            // Full response bodies log at trace level; skip the
            // redact+serialize cost otherwise.
            if logger.logLevel <= .trace {
                logger.trace("  body: \(Self.redactedPreview(data, limit: nil))")
            }
            return (Int(response.status.code), data)
        } catch let error as MatrixError {
            throw error
        } catch is NIOTooManyBytesError {
            throw .networkError(
                "Response exceeded \(maxBodyBytes / 1024 / 1024) MiB buffer "
                    + "(\(method.rawValue) \(pathForLog)). Use a lean SyncFilter "
                    + "(lazy-load members, small timeline limit) to shrink sync payloads."
            )
        } catch {
            throw .networkError(error.localizedDescription)
        }
    }

    /// Assemble the request URL. `path` arrives with dynamic segments
    /// already percent-encoded exactly once (see `pathSegmentEncoded`), so
    /// this concatenates strings — never `appendingPathComponent` or a
    /// `URLComponents` parse/serialize round-trip, both of which re-encode
    /// `%` and double-encode segments (`%3A` → `%253A`).
    static func makeURLString(
        base: String, path: String, query: [String: String]?
    ) throws(MatrixError) -> String {
        var root = base
        if root.hasSuffix("/") { root.removeLast() }
        guard path.hasPrefix("/") else {
            throw .invalidURL(base + path)
        }
        var urlString = root + path
        if let query, !query.isEmpty {
            let items = query
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key.queryEncoded)=\($0.value.queryEncoded)" }
            urlString += "?" + items.joined(separator: "&")
        }
        return urlString
    }

    private func buildURL(path: String, query: [String: String]?) throws(MatrixError) -> String {
        try Self.makeURLString(
            base: homeserver.absoluteString, path: path, query: query)
    }

    private func decodeResponse<Response: Decodable>(
        status: Int, data: Data, path: String
    ) throws(MatrixError) -> Response {
        if (200..<300).contains(status) {
            // Some endpoints (logout, empty PUTs) return an empty body;
            // decoding `{}` covers both `EmptyResponse` and structs whose
            // properties all have defaults.
            let payload = data.isEmpty ? Data("{}".utf8) : data
            do {
                return try decoder.decode(Response.self, from: payload)
            } catch {
                let detail = Self.decodeDetail(error)
                let snippet = Self.redactedPreview(payload, limit: maxLogBytes)
                logger.debug("✗ decode \(path): \(detail) | body: \(snippet)")
                throw .decodingError("\(path): \(detail) | body: \(snippet)")
            }
        }
        // Non-2xx: a 401 with `flows` is a UIAA challenge, not an error.
        if status == 401,
            let challenge = try? decoder.decode(UIAAChallenge.self, from: data)
        {
            throw MatrixError.uiaa(challenge)
        }
        // Non-2xx: try a Matrix error body first.
        if let errorBody = try? decoder.decode(MatrixErrorBody.self, from: data) {
            throw mapErrorBody(errorBody, status: status)
        }
        let bodyString = Self.redactedPreview(data, limit: maxLogBytes)
        logger.debug("✗ HTTP \(status) \(path): \(bodyString)")
        throw MatrixError.unexpectedStatus(status, body: bodyString)
    }

    /// Human-readable decoding failure: which key was missing/mismatched,
    /// where in the JSON tree, and why. Replaces the opaque
    /// `error.localizedDescription` ("The data couldn't be read...").
    private static func decodeDetail(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(codingPath(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "missing value of type \(type) at \(codingPath(context.codingPath))"
        case .typeMismatch(let type, let context):
            return
                "type mismatch (expected \(type)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return
                "corrupt data at \(codingPath(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Render a `codingPath` as `$.rooms.join.<room>.timeline`.
    private static func codingPath(_ path: [any CodingKey]) -> String {
        if path.isEmpty { return "$" }
        return "$" + path.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return ".\(key.stringValue)"
        }.joined()
    }

    /// Request headers for trace logs with the bearer token masked.
    private static func redactedHeaders(_ headers: HTTPHeaders) -> String {
        headers.map { name, value in
            "\(name): \(name.lowercased() == "authorization" ? "<redacted>" : value)"
        }.joined(separator: ", ")
    }

    /// Truncated body preview for logs/errors with secrets masked.
    /// Never throws — falls back to a byte count for non-JSON bodies.
    /// A `nil` limit renders the full body (trace logs); error paths
    /// pass `maxLogBytes`.
    private static func redactedPreview(_ data: Data, limit: Int?) -> String {
        guard !data.isEmpty else { return "<empty>" }
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let redacted = redact(json)
        else {
            if let limit {
                let text = String(data: data.prefix(limit), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text ?? "<\(data.count) non-UTF8 bytes>"
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return text
            }
            return "<\(data.count) non-UTF8 bytes>"
        }
        guard
            let preview = try? JSONSerialization.data(
                withJSONObject: redacted, options: [.sortedKeys])
        else { return "<\(data.count) bytes>" }
        if let limit, preview.count > limit {
            let text = String(data: preview.prefix(limit), encoding: .utf8) ?? ""
            return text + "… (\(data.count) bytes total)"
        }
        return String(data: preview, encoding: .utf8) ?? "<\(data.count) bytes>"
    }

    /// Recursively replace sensitive values with `<redacted>`.
    private static func redact(_ value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, nested) in dict {
                if sensitiveKeys.contains(key.lowercased()) {
                    out[key] = "<redacted>"
                } else {
                    out[key] = redact(nested) ?? NSNull()
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redact($0) ?? NSNull() }
        }
        return value
    }

    private func mapErrorBody(_ body: MatrixErrorBody, status: Int) -> MatrixError {
        let retryAfter: Duration? = body.retryAfterMs.map {
            .milliseconds($0)
        }
        switch (status, body.errcode) {
        case (429, _):
            return .rateLimited(retryAfter: retryAfter)
        case (401, "M_UNKNOWN_TOKEN"), (403, "M_UNKNOWN_TOKEN"):
            return .unknownToken
        default:
            return .serverError(code: body.errcode, message: body.error, retryAfter: retryAfter)
        }
    }
}

/// Decodes `{}`. Used for endpoints with empty JSON responses.
public struct EmptyResponse: Hashable, Sendable, Codable {
    public init() {}
}
