import Foundation

/// Sending side of to-device messaging. `VerificationSession` depends on
/// this protocol (not the concrete client) so flows are testable with a
/// recording fake.
public protocol ToDeviceSender: Sendable {
    /// Send a pre-encoded content dict to a user's devices (`"*"` = all).
    func send(
        eventType: String,
        content: [String: AnyCodable],
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError)

    /// Send any `Encodable` content dict to a user's devices.
    func send<T: Encodable & Sendable>(
        eventType: String,
        content: T,
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError)

    /// Send distinct per-device content in one request
    /// (`userId → deviceId → content`). Needed for Olm-encrypted
    /// messages, where each device gets its own ciphertext.
    func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String
    ) async throws(MatrixError)
}

extension ToDeviceSender {
    /// Default fan-out: one `send` per device (separate transaction IDs).
    /// `ToDeviceClient` overrides this with a single `PUT`.
    func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String = UUID().uuidString
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

/// Send-to-device messaging (`PUT /sendToDevice/{type}/{txnId}`).
///
/// Used by verification flows (and later, encrypted Olm pre-key messages).
/// Incoming to-device events arrive via the sync `to_device` stream.
public actor ToDeviceClient: ToDeviceSender {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Send

    /// Send with a fresh transaction ID (`ToDeviceSender` conformance).
    public func send(
        eventType: String,
        content: [String: AnyCodable],
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError) {
        try await send(
            eventType: eventType, content: content, to: userId,
            devices: devices, transactionId: UUID().uuidString
        )
    }

    /// Send with a fresh transaction ID (`ToDeviceSender` conformance).
    public func send<T: Encodable & Sendable>(
        eventType: String,
        content: T,
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError) {
        try await send(
            eventType: eventType, content: content, to: userId,
            devices: devices, transactionId: UUID().uuidString
        )
    }

    /// Send a pre-encoded content dict to a user's devices.
    /// Pass `devices: ["*"]` to reach all of the user's devices.
    public func send(
        eventType: String,
        content: [String: AnyCodable],
        to userId: UserId,
        devices: [String],
        transactionId: String = UUID().uuidString
    ) async throws(MatrixError) {
        var recipients: [String: AnyCodable] = [:]
        for device in devices {
            recipients[device] = .object(content)
        }
        let body = AnyCodableDictionary([
            "messages": .object([userId.value: .object(recipients)])
        ])
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/sendToDevice/\(eventType.pathSegmentEncoded)/\(transactionId.pathSegmentEncoded)",
            body: body,
            accessToken: try await token()
        )
    }

    /// Send any `Encodable` content dict to a user's devices.
    public func send<T: Encodable & Sendable>(
        eventType: String,
        content: T,
        to userId: UserId,
        devices: [String],
        transactionId: String = UUID().uuidString
    ) async throws(MatrixError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError("To-device content encoding failed: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dict = Self.anyCodableDict(json)
        else {
            throw .encodingError("To-device content is not a JSON object")
        }
        try await send(
            eventType: eventType, content: dict, to: userId,
            devices: devices, transactionId: transactionId
        )
    }

    private static func anyCodableDict(_ json: [String: Any]) -> [String: AnyCodable]? {
        let data = try? JSONSerialization.data(withJSONObject: json)
        return data.flatMap { try? JSONDecoder().decode([String: AnyCodable].self, from: $0) }
    }

    /// Send distinct per-device content in a single `PUT`
    /// (`ToDeviceSender` conformance; Olm-encrypted messages need this).
    public func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String = UUID().uuidString
    ) async throws(MatrixError) {
        var users: [String: AnyCodable] = [:]
        for (user, devices) in messages {
            var perDevice: [String: AnyCodable] = [:]
            for (device, content) in devices {
                perDevice[device] = .object(content)
            }
            users[user] = .object(perDevice)
        }
        let body = AnyCodableDictionary(["messages": .object(users)])
        let _: EmptyResponse = try await transport.send(
            .put,
            path: "/_matrix/client/v3/sendToDevice/\(eventType.pathSegmentEncoded)/\(transactionId.pathSegmentEncoded)",
            body: body,
            accessToken: try await token()
        )
    }
}
