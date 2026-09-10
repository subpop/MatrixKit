/// E2EE key models: device keys, one-time keys, cross-signing, key query.
///
/// Wire maps keyed by user ID use raw `String` keys (JSON objects), since
/// `JSONEncoder` cannot key objects by custom `Codable` structs.

/// A device's identity keys (`POST /keys/upload`, `POST /keys/query`).
public struct DeviceKeys: Hashable, Sendable, Codable {
    /// The owning user (`@alice:example.com`).
    public var userId: String
    /// This device (`ABCDEF`).
    public var deviceId: String
    /// Supported algorithms (e.g. `["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"]`).
    public var algorithms: [String]
    /// `"<algorithm>:<device_id>"` → unpadded-base64 key.
    public var keys: [String: String]
    /// `"<signing user>"` → `"<algorithm>:<key id>"` → unpadded-base64 signature.
    public var signatures: [String: [String: String]]

    public init(
        userId: String,
        deviceId: String,
        algorithms: [String] = ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
        keys: [String: String] = [:],
        signatures: [String: [String: String]] = [:]
    ) {
        self.userId = userId
        self.deviceId = deviceId
        self.algorithms = algorithms
        self.keys = keys
        self.signatures = signatures
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case algorithms
        case keys
        case signatures
    }
}

/// `POST /keys/upload` request: our device keys plus one-time/fallback keys.
public struct UploadDeviceKeysRequest: Hashable, Sendable, Codable {
    public var deviceKeys: DeviceKeys?
    public var oneTimeKeys: [String: AnyCodable]?
    public var fallbackKeys: [String: AnyCodable]?

    public init(
        deviceKeys: DeviceKeys? = nil,
        oneTimeKeys: [String: AnyCodable]? = nil,
        fallbackKeys: [String: AnyCodable]? = nil
    ) {
        self.deviceKeys = deviceKeys
        self.oneTimeKeys = oneTimeKeys
        self.fallbackKeys = fallbackKeys
    }

    private enum CodingKeys: String, CodingKey {
        case deviceKeys = "device_keys"
        case oneTimeKeys = "one_time_keys"
        case fallbackKeys = "fallback_keys"
    }
}

/// `POST /keys/upload` response: remaining one-time-key counts by algorithm.
public struct UploadDeviceKeysResponse: Hashable, Sendable, Codable {
    /// e.g. `{"signed_curve25519": 42}`.
    public var oneTimeKeyCounts: [String: Int]

    public init(oneTimeKeyCounts: [String: Int] = [:]) {
        self.oneTimeKeyCounts = oneTimeKeyCounts
    }

    private enum CodingKeys: String, CodingKey {
        case oneTimeKeyCounts = "one_time_key_counts"
    }
}

/// A cross-signing key: master, self-signing, or user-signing.
public struct CrossSigningKey: Hashable, Sendable, Codable {
    /// The owning user.
    public var userId: String
    /// e.g. `["master"]`, `["self_signing"]`, `["user_signing"]`.
    public var usage: [String]
    /// `"<algorithm>:<unpadded-base64-public-key>"` → the public key itself.
    public var keys: [String: String]
    /// Other cross-signing keys' signatures over this key.
    public var signatures: [String: [String: String]]?

    public init(
        userId: String,
        usage: [String],
        keys: [String: String],
        signatures: [String: [String: String]]? = nil
    ) {
        self.userId = userId
        self.usage = usage
        self.keys = keys
        self.signatures = signatures
    }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case usage
        case keys
        case signatures
    }
}

/// `POST /keys/device_signing/upload`: publish our cross-signing keys.
public struct UploadSigningKeysRequest: Hashable, Sendable, Codable {
    public var masterKey: CrossSigningKey?
    public var selfSigningKey: CrossSigningKey?
    public var userSigningKey: CrossSigningKey?
    /// UIAA continuation for the retry after a 401 challenge (e.g. the
    /// `org.matrix.cross_signing_reset` stage when replacing an identity).
    public var auth: UIAAuth?

    public init(
        masterKey: CrossSigningKey? = nil,
        selfSigningKey: CrossSigningKey? = nil,
        userSigningKey: CrossSigningKey? = nil,
        auth: UIAAuth? = nil
    ) {
        self.masterKey = masterKey
        self.selfSigningKey = selfSigningKey
        self.userSigningKey = userSigningKey
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey {
        case masterKey = "master_key"
        case selfSigningKey = "self_signing_key"
        case userSigningKey = "user_signing_key"
        case auth
    }
}

/// `POST /keys/signatures/upload`: publish signatures over keys
/// (e.g. our self-signing signature over a verified device key).
///
/// Spec shape: `{userId: {keyId: signedObject}}` at the top level —
/// notably WITHOUT a `"signatures"` wrapper (servers parse top-level
/// keys as user IDs) — where each value is the FULL signed object with
/// the new signature merged in, not a bare signature map.
public struct UploadSignaturesRequest: Hashable, Sendable, Codable {
    /// Signed user → signed key/device ID → full signed object.
    public var signed: [String: [String: DeviceKeys]]

    public init(signed: [String: [String: DeviceKeys]] = [:]) {
        self.signed = signed
    }

    public init(from decoder: Decoder) throws {
        signed = try decoder.singleValueContainer()
            .decode([String: [String: DeviceKeys]].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(signed)
    }
}

/// `POST /keys/signatures/upload` response. The endpoint returns 200
/// even when individual signatures are rejected, so callers must
/// inspect `failures` — a quiet accept is NOT success.
public struct UploadSignaturesResponse: Hashable, Sendable, Codable {
    /// Rejected signatures: signed user → signed key/device ID → error.
    public var failures: [String: [String: MatrixErrorBody]]?

    public init(failures: [String: [String: MatrixErrorBody]]? = nil) {
        self.failures = failures
    }
}

/// A claimed one-time key: the Curve25519 public key plus the device's
/// signature over it (`signed_curve25519`).
public struct ClaimedOneTimeKey: Hashable, Sendable, Codable {
    /// Unpadded-base64 Curve25519 public key.
    public var key: String
    /// `"<signing user>"` → `"<algorithm>:<key id>"` → signature.
    public var signatures: [String: [String: String]]

    public init(key: String, signatures: [String: [String: String]] = [:]) {
        self.key = key
        self.signatures = signatures
    }
}

/// `POST /keys/claim` request: claim one-time keys to start Olm sessions.
public struct ClaimKeysRequest: Hashable, Sendable, Codable {
    /// User ID → device ID (or `"*"`) → `"signed_curve25519"`.
    public var oneTimeKeys: [String: [String: String]]

    public init(oneTimeKeys: [String: [String: String]]) {
        self.oneTimeKeys = oneTimeKeys
    }

    private enum CodingKeys: String, CodingKey {
        case oneTimeKeys = "one_time_keys"
    }
}

/// `POST /keys/claim` response: unclaimed one-time keys by user/device.
public struct ClaimKeysResponse: Hashable, Sendable, Codable {
    /// User ID → device ID → `"<algorithm>:<key id>"` → claimed key.
    public var oneTimeKeys: [String: [String: [String: ClaimedOneTimeKey]]]
    /// Server names that failed → error bodies.
    public var failures: [String: AnyCodable]?

    public init(
        oneTimeKeys: [String: [String: [String: ClaimedOneTimeKey]]] = [:],
        failures: [String: AnyCodable]? = nil
    ) {
        self.oneTimeKeys = oneTimeKeys
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case oneTimeKeys = "one_time_keys"
        case failures
    }
}

/// `POST /keys/query` request: fetch device + cross-signing keys.
public struct KeyQueryRequest: Hashable, Sendable, Codable {
    /// User ID → device IDs to fetch (empty list = all devices).
    public var deviceKeys: [String: [String]]

    public init(deviceKeys: [String: [String]]) {
        self.deviceKeys = deviceKeys
    }

    private enum CodingKeys: String, CodingKey {
        case deviceKeys = "device_keys"
    }
}

/// `POST /keys/query` response.
public struct KeyQueryResponse: Hashable, Sendable, Codable {
    /// User ID → device ID → device keys.
    public var deviceKeys: [String: [String: DeviceKeys]]
    /// User ID → master cross-signing key.
    public var masterKeys: [String: CrossSigningKey]?
    /// User ID → self-signing cross-signing key.
    public var selfSigningKeys: [String: CrossSigningKey]?
    /// User ID → user-signing cross-signing key.
    public var userSigningKeys: [String: CrossSigningKey]?
    /// Server names that failed → error bodies.
    public var failures: [String: AnyCodable]?

    public init(
        deviceKeys: [String: [String: DeviceKeys]] = [:],
        masterKeys: [String: CrossSigningKey]? = nil,
        selfSigningKeys: [String: CrossSigningKey]? = nil,
        userSigningKeys: [String: CrossSigningKey]? = nil,
        failures: [String: AnyCodable]? = nil
    ) {
        self.deviceKeys = deviceKeys
        self.masterKeys = masterKeys
        self.selfSigningKeys = selfSigningKeys
        self.userSigningKeys = userSigningKeys
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case deviceKeys = "device_keys"
        case masterKeys = "master_keys"
        case selfSigningKeys = "self_signing_keys"
        case userSigningKeys = "user_signing_keys"
        case failures
    }
}
