import Foundation

/// A `ToDeviceSender` that encrypts every event through Olm.
///
/// Spec-correct transport for verification handshakes and secrets:
/// each event's type+content becomes the Olm payload of an
/// `m.room.encrypted` message to every target device. `devices` may
/// contain `"*"` (expanded via the connector's cached device list).
/// Construction is cheap — share one per `OlmConnector`.
public struct EncryptedToDeviceSender: ToDeviceSender, Sendable {
    private let olm: OlmConnector

    /// - Parameter olm: configured connector (encrypts + tracks
    ///   sessions; also serves cached `"*"` device expansion).
    public init(olm: OlmConnector) {
        self.olm = olm
    }

    /// Expand `"*"` via the connector's cached device list, then send
    /// one encrypted `m.room.encrypted` per device (per-device payloads
    /// differ, so this bypasses the plaintext fan-out).
    ///
    /// `"*"` expansion excludes our own device: recipients are peers,
    /// and the server would otherwise echo our request back at us.
    /// Throws `.verificationFailed` when no other device remains.
    public func send(
        eventType: String,
        content: [String: AnyCodable],
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError) {
        let resolved: [DeviceId]
        if devices == ["*"] {
            let ids = try await olm.deviceIds(for: userId)
            let others: [String]
            if let own = await olm.ownDeviceId {
                others = ids.filter { $0 != own }
            } else {
                others = ids
            }
            guard !others.isEmpty else {
                throw .verificationFailed(
                    "No other devices available for verification")
            }
            resolved = others.map { DeviceId($0) }
        } else {
            resolved = devices.map { DeviceId($0) }
        }
        try await olm.sendEncrypted(
            eventType: eventType, content: content,
            to: userId, devices: resolved)
    }

    /// Per-device fan-out through the encrypted `send` (each device
    /// gets its own ciphertext; the transaction ID is unused — every
    /// `m.room.encrypted` carries its own).
    public func sendRaw(
        eventType: String,
        messages: [String: [String: [String: AnyCodable]]],
        transactionId: String = UUID().uuidString
    ) async throws(MatrixError) {
        _ = transactionId
        for (user, devices) in messages {
            for (device, content) in devices {
                try await send(
                    eventType: eventType, content: content,
                    to: UserId(unchecked: user), devices: [device])
            }
        }
    }
    /// Encode then send encrypted (same JSON round-trip as
    /// `ToDeviceClient`, landing in `send(eventType:content:to:userId:devices:)`).
    public func send<T: Encodable & Sendable>(
        eventType: String,
        content: T,
        to userId: UserId,
        devices: [String]
    ) async throws(MatrixError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(content)
        } catch {
            throw .encodingError(
                "Encrypted to-device content encoding failed: \(error.localizedDescription)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let object = try? JSONSerialization.data(withJSONObject: json),
            let dict = try? JSONDecoder().decode(
                [String: AnyCodable].self, from: object)
        else {
            throw .encodingError(
                "Encrypted to-device content is not a JSON object")
        }
        try await send(
            eventType: eventType, content: dict,
            to: userId, devices: devices)
    }
}
