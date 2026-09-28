import Foundation
import MatrixKit

/// Recording `ToDeviceSender` for driving verification flows in-process.
///
/// Shared fake (moved from `VerificationTests`): every suite that
/// captures to-device sends uses this instead of a per-file copy.
/// `sent` logs `(type, content, devices)` in order for table assertions;
/// `last(_:event:)` decodes the latest send of a type as an SDK model.
public actor FakeSender: ToDeviceSender {
    public var sent: [(type: String, content: [String: AnyCodable], devices: [String])] = []

    public init() {}

    /// Clear the log between table rows sharing one sender.
    public func reset() {
        sent = []
    }

    public func send(
        eventType: String, content: [String: AnyCodable],
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        sent.append((eventType, content, devices))
    }

    public func send<T: Encodable & Sendable>(
        eventType: String, content: T,
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError("Fake cannot encode content: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dictData = try? JSONSerialization.data(withJSONObject: json),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: dictData)
        else {
            throw .encodingError("Fake cannot encode content")
        }
        sent.append((eventType, dict, devices))
    }

    public func last<T: Decodable>(_ type: T.Type, event: String) throws -> T {
        guard let entry = sent.last(where: { $0.type == event }) else {
            throw MatrixError.verificationFailed("No \(event) recorded")
        }
        let data = try JSONEncoder().encode(AnyCodableDictionary(entry.content))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Explicit fan-out (mirrors the protocol extension default, which
    /// cannot witness the requirement from outside the defining module).
    public func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String
    ) async throws(MatrixError) {
        for (user, devices) in messages {
            for (device, content) in devices {
                try await send(
                    eventType: eventType, content: content,
                    to: UserId(unchecked: user), devices: [device])
            }
        }
    }
}

/// `ToDeviceSender` that fails the next N sends with a canned error, for
/// exercising the transient-retry paths on terminal verification sends.
public actor FlakySender: ToDeviceSender {
    public var sent: [(type: String, content: [String: AnyCodable], devices: [String])] = []
    public var attempts: [String: Int] = [:]
    public var failuresRemaining = 0
    public var failure: MatrixError = .networkError("boom")

    public init() {}

    public func failNext(_ n: Int, with error: MatrixError = .networkError("boom")) {
        failuresRemaining = n
        failure = error
    }

    public func doneSends() -> Int {
        sent.filter { $0.type == "m.key.verification.done" }.count
    }

    public func doneAttempts() -> Int {
        attempts["m.key.verification.done"] ?? 0
    }

    public func macSends() -> Int {
        sent.filter { $0.type == "m.key.verification.mac" }.count
    }

    public func last<T: Decodable>(_ type: T.Type, event: String) throws -> T {
        guard let entry = sent.last(where: { $0.type == event }) else {
            throw MatrixError.verificationFailed("No \(event) recorded")
        }
        let data = try JSONEncoder().encode(AnyCodableDictionary(entry.content))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Explicit fan-out (mirrors the protocol extension default, which
    /// cannot witness the requirement from outside the defining module).
    public func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String
    ) async throws(MatrixError) {
        for (user, devices) in messages {
            for (device, content) in devices {
                try await send(
                    eventType: eventType, content: content,
                    to: UserId(unchecked: user), devices: [device])
            }
        }
    }

    public func send(
        eventType: String, content: [String: AnyCodable],
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        attempts[eventType, default: 0] += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        sent.append((eventType, content, devices))
    }

    public func send<T: Encodable & Sendable>(
        eventType: String, content: T,
        to userId: UserId, devices: [String]
    ) async throws(MatrixError) {
        attempts[eventType, default: 0] += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError("Flaky cannot encode content: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dictData = try? JSONSerialization.data(withJSONObject: json),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: dictData)
        else {
            throw .encodingError("Flaky cannot encode content")
        }
        sent.append((eventType, dict, devices))
    }
}
