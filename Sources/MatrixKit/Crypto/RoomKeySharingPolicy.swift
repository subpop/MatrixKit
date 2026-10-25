/// Which devices of a user receive Megolm room keys.
public enum RoomKeySharingPolicy: Hashable, Sendable {
    /// Every device with published keys.
    case allDevices
    /// Only devices carrying a valid signature from their owner's
    /// self-signing key. A device an attacker adds to an account (or
    /// that was never cross-signed) receives nothing.
    ///
    /// The owner's self-signing key is taken from the homeserver's key
    /// query as published, so this does not defend against a homeserver
    /// that forges a cross-signing identity.
    case crossSignedOnly
}
