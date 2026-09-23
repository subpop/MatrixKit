import Foundation

/// All errors thrown by MatrixKit.
public enum MatrixError: Error, Sendable, Hashable {
    /// A malformed Matrix identifier was supplied (bad sigil, missing parts).
    case invalidIdentifier(String)
    /// A URL could not be constructed (bad homeserver, unencodable path).
    case invalidURL(String)
    /// No session / access token is available for an authenticated call.
    case notAuthenticated
    /// The transport is shutting down (client deallocated, sync stopped).
    case transportClosed
    /// A network-level failure (connection refused, TLS error, timeout).
    case networkError(String)
    /// JSON encoding of a request body failed.
    case encodingError(String)
    /// JSON decoding of a response body failed.
    case decodingError(String)
    /// The server returned a standard Matrix error (`errcode` + `error`).
    case serverError(code: String, message: String, retryAfter: Duration?)
    /// HTTP 429 — retry after the given delay, if present.
    case rateLimited(retryAfter: Duration?)
    /// HTTP 401 with `M_UNKNOWN_TOKEN` — the access token is dead.
    case unknownToken
    /// An HTTP status with no Matrix error body.
    case unexpectedStatus(Int, body: String?)
    /// Sync loop failed and exhausted its retry budget.
    case syncFailed(String)
    /// E2EE verification failed (mismatched SAS, bad commitment/MAC, wrong order).
    case verificationFailed(String)
    /// An encrypted send reached no devices: every target lacked
    /// published device keys or a claimable one-time key (stale or
    /// signed-out device records).
    case noReachableDevices(String)
    /// 4S recovery failed (wrong recovery key/passphrase, missing secrets).
    case recoveryFailed(String)
    /// A cooperative cancellation (`Task.cancel()`) stopped the operation
    /// before it finished. Partial work (e.g. already-imported backup
    /// sessions) is kept; retrying resumes from the start.
    case cancelled
    /// HTTP 401 UIAA challenge — the operation needs interactive approval.
    /// Inspect `flows` for completable stages, then retry with `UIAAuth`.
    case uiaa(UIAAChallenge)
}

extension MatrixError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidIdentifier(let msg): return "Invalid identifier: \(msg)"
        case .invalidURL(let msg): return "Invalid URL: \(msg)"
        case .notAuthenticated: return "Not authenticated: no access token"
        case .transportClosed: return "Transport is closed"
        case .networkError(let msg): return "Network error: \(msg)"
        case .encodingError(let msg): return "Encoding error: \(msg)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .serverError(let code, let message, _): return "Server error [\(code)]: \(message)"
        case .rateLimited(let after):
            if let after { return "Rate limited, retry after \(after)" }
            return "Rate limited"
        case .unknownToken: return "Unknown token: access token is invalid or expired"
        case .unexpectedStatus(let code, let body): return "Unexpected HTTP \(code): \(body ?? "<empty>")"
        case .syncFailed(let msg): return "Sync failed: \(msg)"
        case .verificationFailed(let msg): return "Verification failed: \(msg)"
        case .noReachableDevices(let msg): return "No devices could be reached: \(msg)"
        case .recoveryFailed(let msg): return "Recovery failed: \(msg)"
        case .cancelled: return "Operation cancelled"
        case .uiaa(let challenge):
            let stages = challenge.flows.map { $0.stages.joined(separator: "+") }
                .joined(separator: ", ")
            if let msg = challenge.message {
                return "Interactive auth required [\(stages)]: \(msg)"
            }
            return "Interactive auth required [\(stages)]"
        }
    }
}

extension MatrixError: LocalizedError {
    public var errorDescription: String? { description }
}

extension MatrixError {
    /// Whether the operation is worth retrying (rate limits, 5xx-style errors).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited: return true
        case .serverError(let code, _, _):
            return code == "M_UNKNOWN" || code.hasPrefix("M_5")
        case .networkError: return true
        default: return false
        }
    }

    /// Whether this error represents task cancellation rather than a
    /// real failure. Swift's `CancellationError` (thrown by the HTTP
    /// client when the awaiting task is cancelled) can't cross this
    /// module's typed `throws(MatrixError)` boundary, so it arrives
    /// wrapped in `.networkError`. Callers that cancel their own
    /// requests (paging chains, view teardown) should treat this as
    /// "never happened" instead of reporting it.
    public var isCancellation: Bool {
        if case .cancelled = self {
            return true
        }
        if case .networkError(let message) = self {
            return message.localizedStandardContains("CancellationError")
        }
        return false
    }

    /// The `retry_after_ms` hint as a `Duration`, if the server gave one.
    public var retryAfter: Duration? {
        switch self {
        case .rateLimited(let d): return d
        case .serverError(_, _, let d): return d
        default: return nil
        }
    }
}
