import Foundation
import MatrixKit
import Testing

// MARK: - Table helpers

/// Decode a JSON literal as an SDK model. Keeps tables compact:
/// rows carry strings, the test carries one decode line.
public func decodeFixture<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Decode through a full encode round-trip: the value a test builds
/// must survive serialization, not just satisfy the initializer.
public func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Raw wire-shape assertions: decode `$json` into a string-keyed map
/// for snake_case key checks without a dedicated model.
public func rawShape(_ json: String) throws -> [String: AnyCodable] {
    try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
}

// MARK: - Harness assertions

/// Fail the test when the SDK sent anything the pinned spec does not
/// define. Call at the end of every compliance test (or use
/// `withHarness`, which does it automatically).
public func requireNoViolations(_ harness: Harness, sourceLocation: SourceLocation = #_sourceLocation) async {
    let violations = await harness.violations
    #expect(violations.isEmpty, "spec violations: \(violations.map(\.description).joined(separator: "; "))", sourceLocation: sourceLocation)
}

/// Run `body` against a fresh harness and assert spec-cleanliness on
/// the way out, even when `body` throws.
///
/// Main-actor: facade-level suites (`MatrixClient` is `@MainActor`) call
/// this from isolated tests; nonisolated callers hop over transparently.
@MainActor
public func withHarness<T: Sendable>(
    _ body: (Harness) async throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> T {
    let harness = try await Harness.start()
    do {
        let result = try await body(harness)
        await harness.shutdownClients()
        await requireNoViolations(harness, sourceLocation: sourceLocation)
        await harness.stop()
        return result
    } catch {
        await harness.shutdownClients()
        await requireNoViolations(harness, sourceLocation: sourceLocation)
        await harness.stop()
        throw error
    }
}

// MARK: - Async determinism

/// Wait until `condition` returns true, polling on a coarse beat with
/// an overall deadline. Prefer completion-gated synchronization where
/// the SDK exposes it; use this only where the SDK owns the timing
/// (sync long-poll, retry backoff) so tests never sleep-and-pray on
/// fixed delays.
public func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    @_implicitSelfCapture _ condition: @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        #expect(ContinuousClock.now < deadline, "timed out waiting for \(description)", sourceLocation: sourceLocation)
        if ContinuousClock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
