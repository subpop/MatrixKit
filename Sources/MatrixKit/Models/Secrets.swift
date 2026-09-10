/// Cross-signing secret sharing (`m.secret.request` / `m.secret.send`).
///
/// After two devices verify each other, the new device can ask a verified
/// peer for the cross-signing private halves instead of generating (and
/// UIAA-resetting) a fresh identity. This is how Rust SDK clients "just
/// verify and stay verified": the SDK fires these requests automatically
/// post-verify and persists what comes back.
///
/// Note: peers normally Olm-encrypt `m.secret.send`; `OlmConnector`
/// decrypts those before they reach `SecretShare.receive(_:)`, and our
/// own answers go out encrypted the same way. A plaintext body arrives
/// only when the peer chose not to encrypt.
public enum SecretName {
    /// `m.cross_signing.master` — the master private key.
    public static let master = "m.cross_signing.master"
    /// `m.cross_signing.self_signing` — the self-signing private key.
    public static let selfSigning = "m.cross_signing.self_signing"
    /// `m.cross_signing.user_signing` — the user-signing private key.
    public static let userSigning = "m.cross_signing.user_signing"

    /// `m.megolm_backup.v1` — the server-side key-backup private key.
    /// Requested separately from the halves (see
    /// `SecretShare/requestBackupKey`): only devices that unlocked 4S
    /// this session hold it to share.
    public static let backup = "m.megolm_backup.v1"

    /// All three cross-signing secret names, in upload order.
    public static let all = [master, selfSigning, userSigning]
}

/// `m.secret.request`: ask a peer device for a named secret.
///
/// Sent to-device UNENCRYPTED to the device holding the secret (the
/// spec mandates plaintext for `m.secret.request`; only the
/// `m.secret.send` answer is encrypted). The peer answers with
/// `m.secret.send` carrying the same `request_id`.
public struct SecretRequest: Hashable, Sendable, Codable {
    /// Secret name (see `SecretName`).
    public var name: String
    /// Our device ID, so the peer knows where the secret should go.
    public var requestingDeviceId: String
    /// Opaque ID matching request to `m.secret.send`.
    public var requestId: String
    /// `"request"` for a live request, `"request_cancellation"` to
    /// withdraw one. Required by the spec — peers with strict parsers
    /// drop requests that omit it.
    public var action: String

    public init(name: String, requestingDeviceId: String, requestId: String, action: String = "request") {
        self.name = name
        self.requestingDeviceId = requestingDeviceId
        self.requestId = requestId
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case requestingDeviceId = "requesting_device_id"
        case requestId = "request_id"
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.requestingDeviceId = try container.decode(
            String.self, forKey: .requestingDeviceId)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        // Tolerate pre-`action` payloads (and our own old ones).
        self.action = try container.decodeIfPresent(
            String.self, forKey: .action) ?? "request"
    }
}

/// `m.secret.send`: a peer's answer carrying the secret.
///
/// `secret` is the unpadded-base64 private key for cross-signing
/// secrets. Senders normally Olm-encrypt this event; a plaintext body
/// arrives only when the peer chose not to.
public struct SecretSend: Hashable, Sendable, Codable {
    /// Matches `SecretRequest.requestId`.
    public var requestId: String
    /// The secret itself (base64 private key for cross-signing names).
    public var secret: String

    public init(requestId: String, secret: String) {
        self.requestId = requestId
        self.secret = secret
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case secret
    }
}
