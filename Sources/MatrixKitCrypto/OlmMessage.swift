import Foundation

/// Olm message type as carried in the `m.olm.v1.curve25519-aes-sha2`
/// `ciphertext` map: `0` for the initial pre-key message, `1` once a
/// message has been received on the session.
public enum OlmWireType: Int, Sendable {
    case preKey = 0
    case normal = 1
}

/// A decoded normal-format Olm message (the unit that is encrypted).
public struct OlmNormalMessage: Sendable, Hashable {
    /// Sender's current ratchet public key (32 bytes).
    public let ratchetKey: Data
    /// Index within the sending chain.
    public let chainIndex: UInt64
    /// AES-256-CBC ciphertext.
    public let ciphertext: Data

    public init(ratchetKey: Data, chainIndex: UInt64, ciphertext: Data) {
        self.ratchetKey = ratchetKey
        self.chainIndex = chainIndex
        self.ciphertext = ciphertext
    }
}

/// A decoded pre-key Olm message: session-setup fields plus one embedded
/// normal message.
///
/// Wire shape (matches libolm/vodozemac): the inner message is the FULL
/// normal wire bytes — version + payload + its 8-byte MAC, authenticated
/// with the same message keys — and the outer message carries NO MAC of
/// its own.
public struct OlmPreKeyMessage: Sendable, Hashable {
    /// Recipient's one-time public key the session was started with (EB).
    public let oneTimeKey: Data
    /// Sender's ephemeral public key (EA).
    public let baseKey: Data
    /// Sender's Curve25519 identity public key (IA).
    public let identityKey: Data
    /// The embedded normal message, full wire bytes (version + payload
    /// + MAC).
    public let inner: Data

    public init(
        oneTimeKey: Data, baseKey: Data, identityKey: Data,
        inner: Data
    ) {
        self.oneTimeKey = oneTimeKey
        self.baseKey = baseKey
        self.identityKey = identityKey
        self.inner = inner
    }
}

/// A fully decoded Olm message body. Normal messages are payload plus
/// MAC; pre-key messages are version + fields with no outer MAC (the
/// embedded inner message carries its own).
public enum OlmMessage: Sendable, Hashable {
    case preKey(OlmPreKeyMessage)
    case normal(OlmNormalMessage)
}

/// Encode/decode for the Olm binary message format (version `0x03`).
///
/// Normal message: version + protobuf payload + 8-byte MAC.
/// Pre-key message: version + protobuf payload, NO outer MAC; the
/// embedded field-4 message is a full normal wire message.
///
/// Normal payload: ratchet-key `0x0A` (string), chain-index `0x10` (int),
/// cipher-text `0x22` (string). Pre-key payload: one-time-key `0x0A`
/// (string), base-key `0x12` (string), identity-key `0x1A` (string),
/// message `0x22` (string, embedded full normal wire bytes).
public enum OlmMessageCoder {
    public static let version: UInt8 = 0x03

    /// Encode a normal payload (version byte included, no MAC).
    public static func encodeNormal(_ message: OlmNormalMessage) -> Data {
        var out = Data([version])
        out += ProtoCoding.bytesField(number: 1, value: message.ratchetKey)
        out += ProtoCoding.intField(number: 2, value: message.chainIndex)
        out += ProtoCoding.bytesField(number: 4, value: message.ciphertext)
        return out
    }

    /// Encode a pre-key message wrapping a full normal wire message
    /// (version + payload + MAC, no outer MAC appended).
    public static func encodePreKey(
        oneTimeKey: Data, baseKey: Data, identityKey: Data,
        innerWire: Data
    ) -> Data {
        var out = Data([version])
        out += ProtoCoding.bytesField(number: 1, value: oneTimeKey)
        out += ProtoCoding.bytesField(number: 2, value: baseKey)
        out += ProtoCoding.bytesField(number: 3, value: identityKey)
        out += ProtoCoding.bytesField(number: 4, value: innerWire)
        return out
    }

    /// Decode a full pre-key wire message (version + fields, no MAC to
    /// split — the outer message carries none).
    public static func decodePreKeyBody(
        message: Data
    ) throws(CryptoError) -> OlmPreKeyMessage {
        guard
            message.count >= 1, message[message.startIndex] == version
        else {
            throw .malformedMessage("Pre-key message missing version byte")
        }
        let fields = try ProtoCoding.decodeFields(Data(message.dropFirst()))
        var strings: [UInt8: Data] = [:]
        for (number, field) in fields {
            if case .bytes(let data) = field {
                strings[number] = data
            }
        }
        guard
            let oneTimeKey = strings[1],
            let baseKey = strings[2],
            let identityKey = strings[3],
            let inner = strings[4]
        else {
            throw .malformedMessage("Pre-key message missing fields")
        }
        return OlmPreKeyMessage(
            oneTimeKey: Data(oneTimeKey),
            baseKey: Data(baseKey),
            identityKey: Data(identityKey),
            inner: Data(inner))
    }

    /// Split wire bytes into payload (version + fields) and trailing MAC.
    public static func split(message: Data) throws(CryptoError) -> (
        payload: Data, mac: Data
    ) {
        guard message.count >= 1 + 8 else {
            throw .malformedMessage("Olm message shorter than version + MAC")
        }
        guard message[message.startIndex] == version else {
            throw .unsupportedVersion(message[message.startIndex])
        }
        return (
            payload: message.prefix(message.count - 8),
            mac: message.suffix(8))
    }

    /// Decode a payload (version byte + fields, MAC already split off).
    public static func decode(payload: Data) throws(CryptoError) -> OlmMessage {
        guard
            payload.count >= 1, payload[payload.startIndex] == version
        else {
            throw .malformedMessage("Olm payload missing version byte")
        }
        let fields = try ProtoCoding.decodeFields(payload.dropFirst())
        var strings: [UInt8: Data] = [:]
        var ints: [UInt8: UInt64] = [:]
        for (number, field) in fields {
            switch field {
            case .bytes(let data): strings[number] = data
            case .int(let value): ints[number] = value
            }
        }
        if strings[3] != nil {
            // Pre-key shape: use decodePreKeyBody (no MAC strip — the
            // outer message carries none and the inner keeps its own).
            throw .malformedMessage(
                "Pre-key payload needs decodePreKeyBody, not decode")
        }
        return try .normal(decodeNormalFields(strings: strings, ints: ints))
    }

    private static func decodeNormalFields(
        strings: [UInt8: Data], ints: [UInt8: UInt64]
    ) throws(CryptoError) -> OlmNormalMessage {
        guard
            let ratchetKey = strings[1],
            let chainIndex = ints[2],
            let ciphertext = strings[4]
        else {
            throw .malformedMessage("Normal message missing fields")
        }
        guard ratchetKey.count == 32 else {
            throw .malformedMessage("Ratchet key is not 32 bytes")
        }
        return OlmNormalMessage(
            ratchetKey: Data(ratchetKey),
            chainIndex: chainIndex,
            ciphertext: Data(ciphertext))
    }
}
