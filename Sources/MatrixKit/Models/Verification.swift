/// Key-verification to-device message bodies (`m.key.verification.*`).
///
/// All are sent via `PUT /sendToDevice/{type}/{txnId}` and received in the
/// sync `to_device` stream. Field docs follow the Matrix spec.

// MARK: - Method negotiation

/// `m.key.verification.request`: open a verification with a peer's devices.
public struct VerificationRequest: Hashable, Sendable, Codable {
    /// Our device ID.
    public var fromDevice: String
    /// Verification methods we support (e.g. `["m.sas.v1"]`).
    public var methods: [String]
    /// `Date.now()` millis when sent (peers ignore stale requests).
    public var timestamp: Int
    /// Opaque per-verification ID shared by all messages in the flow.
    public var transactionId: String

    public init(fromDevice: String, methods: [String], timestamp: Int, transactionId: String) {
        self.fromDevice = fromDevice
        self.methods = methods
        self.timestamp = timestamp
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case fromDevice = "from_device"
        case methods
        case timestamp
        case transactionId = "transaction_id"
    }
}

/// `m.key.verification.ready`: accept a verification request.
public struct VerificationReady: Hashable, Sendable, Codable {
    /// Responding device ID.
    public var fromDevice: String
    /// Mutually supported methods (subset of the request's).
    public var methods: [String]

    public init(fromDevice: String, methods: [String]) {
        self.fromDevice = fromDevice
        self.methods = methods
    }

    private enum CodingKeys: String, CodingKey {
        case fromDevice = "from_device"
        case methods
    }
}

// MARK: - Start / accept

/// `m.key.verification.start` (`m.sas.v1`): begin SAS verification.
///
/// NOTE: `method` is a plain string on the wire (`"m.sas.v1"`). An earlier
/// revision modeled it as a `{"name": …}` object; real clients reject that
/// shape, which stalls the flow with no emoji ever shown.
public struct VerificationStart: Hashable, Sendable, Codable {
    /// Starting device ID.
    public var fromDevice: String
    /// Always `"m.sas.v1"` here.
    public var method: String
    /// Key agreement protocols offered (we only speak `curve25519-hkdf-sha256`).
    public var keyAgreementProtocols: [String]
    /// Hashes offered (`["sha256"]`).
    public var hashes: [String]
    /// MAC methods offered (`["hkdf-hmac-sha256.v2"]`).
    public var messageAuthenticationCodes: [String]
    /// SAS methods offered (subset of `["emoji", "decimal"]`).
    public var shortAuthenticationString: [String]
    /// Flow ID (equals the request's transaction ID).
    public var transactionId: String

    public init(
        fromDevice: String,
        shortAuthenticationString: [String] = ["emoji", "decimal"],
        transactionId: String
    ) {
        self.fromDevice = fromDevice
        self.method = "m.sas.v1"
        self.keyAgreementProtocols = ["curve25519-hkdf-sha256"]
        self.hashes = ["sha256"]
        self.messageAuthenticationCodes = ["hkdf-hmac-sha256.v2"]
        self.shortAuthenticationString = shortAuthenticationString
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case fromDevice = "from_device"
        case method
        case keyAgreementProtocols = "key_agreement_protocols"
        case hashes
        case messageAuthenticationCodes = "message_authentication_codes"
        case shortAuthenticationString = "short_authentication_string"
        case transactionId = "transaction_id"
    }
}

// MARK: - Key exchange

/// `m.key.verification.accept`: answer a start message.
///
/// Note: unlike `start`, the spec defines NO `method` field here — real
/// clients (Element) omit it, so requiring it breaks decoding.
public struct VerificationAccept: Hashable, Sendable, Codable {
    /// Agreed protocol (`"curve25519-hkdf-sha256"`).
    public var keyAgreementProtocol: String
    /// Agreed hash (`"sha256"`).
    public var hash: String
    /// Agreed MAC method (`"hkdf-hmac-sha256.v2"`).
    public var messageAuthenticationCode: String
    /// Agreed SAS methods.
    public var shortAuthenticationString: [String]
    /// `base64(sha256(accepter_ephemeral_pubkey || canonical(start_content)))`.
    public var commitment: String

    public init(
        keyAgreementProtocol: String = "curve25519-hkdf-sha256",
        hash: String = "sha256",
        messageAuthenticationCode: String = "hkdf-hmac-sha256.v2",
        shortAuthenticationString: [String],
        commitment: String
    ) {
        self.keyAgreementProtocol = keyAgreementProtocol
        self.hash = hash
        self.messageAuthenticationCode = messageAuthenticationCode
        self.shortAuthenticationString = shortAuthenticationString
        self.commitment = commitment
    }

    private enum CodingKeys: String, CodingKey {
        case keyAgreementProtocol = "key_agreement_protocol"
        case hash
        case messageAuthenticationCode = "message_authentication_code"
        case shortAuthenticationString = "short_authentication_string"
        case commitment
    }
}

/// `m.key.verification.key`: share our ephemeral Curve25519 public key.
public struct VerificationKey: Hashable, Sendable, Codable {
    /// Unpadded-base64 ephemeral public key.
    public var key: String
    /// Flow ID (required on the wire by the spec).
    public var transactionId: String

    public init(key: String, transactionId: String) {
        self.key = key
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case transactionId = "transaction_id"
    }
}

// MARK: - MAC + done/cancel

/// `m.key.verification.mac`: MACs over verified keys + key-ID list.
///
/// Wire shape per spec: `keys` is a SINGLE string (MAC of the
/// comma-separated, sorted key-ID list), `mac` maps each key ID to the MAC
/// of that key. (An earlier revision sent both as maps, which peers
/// silently fail to verify — same self-test-invisible class as the
/// `method`-object bug.)
public struct VerificationMac: Hashable, Sendable, Codable {
    /// MAC of the comma-separated, sorted key-ID list (`KEY_IDS` suffix).
    public var keys: String
    /// `"<algorithm>:<key id>"` → MAC over that key.
    public var mac: [String: String]
    /// Flow ID.
    public var transactionId: String

    public init(keys: String, mac: [String: String], transactionId: String) {
        self.keys = keys
        self.mac = mac
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case keys
        case mac
        case transactionId = "transaction_id"
    }
}

/// `m.key.verification.done`: verification complete.
public struct VerificationDone: Hashable, Sendable, Codable {
    /// Flow ID.
    public var transactionId: String

    public init(transactionId: String) {
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
    }
}

/// `m.key.verification.cancel`: abort the flow at any point.
public struct VerificationCancel: Hashable, Sendable, Codable {
    /// Machine-readable code (e.g. `"m.mismatched_sas"`, `"m.user"`).
    public var code: String
    /// Human-readable reason.
    public var reason: String
    /// Flow ID.
    public var transactionId: String

    public init(code: String, reason: String, transactionId: String) {
        self.code = code
        self.reason = reason
        self.transactionId = transactionId
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case reason
        case transactionId = "transaction_id"
    }
}
