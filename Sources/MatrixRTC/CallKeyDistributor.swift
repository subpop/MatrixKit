import Crypto
import Foundation
import MatrixKit

/// A call encryption key for one participant identity.
public struct RTCKey: Hashable, Sendable {
    /// LiveKit participant identity this key decrypts.
    public var identity: String
    /// Key index (rotation counter).
    public var index: Int
    /// Raw 16-byte key material.
    public var key: Data

    public init(identity: String, index: Int, key: Data) {
        self.identity = identity
        self.index = index
        self.key = key
    }
}

/// `io.element.call.encryption_keys` distribution over Olm-encrypted
/// to-device messages (Element Call interop).
///
/// Outbound content:
/// `{keys: {index, key(b64)}, member: {id, claimed_device_id}, room_id,
///  session: {application: m.call, call_id: "", scope: m.room}, sent_ts}`.
/// Inbound accepts both the object form and the legacy single-element
/// array form, and registers keys under the sender's legacy
/// `<mxid>:<device>` identity plus the v2 hashed identities.
public actor CallKeyDistributor {
    private let client: MatrixClient
    /// Keys by LiveKit identity, newest first.
    private var keys: [String: [RTCKey]] = [:]
    private var keyContinuations: [AsyncStream<RTCKeyUpdate>.Continuation] = []

    public init(client: MatrixClient) {
        self.client = client
    }

    // MARK: - Identity

    /// LiveKit identity for a call participant: unpadded base64 of the
    /// SHA-256 of compact JSON `[matrixID, claimedDeviceID, memberID]`.
    public static func liveKitIdentity(
        matrixID: String, claimedDeviceID: String, memberID: String
    ) -> String {
        let payload = #"["\#(matrixID)","\#(claimedDeviceID)","\#(memberID)"]"#
        let digest = SHA256.hash(data: Data(payload.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// Legacy identity for a sender (`<mxid>:<device>`).
    public static func legacyIdentity(matrixID: String, deviceID: String) -> String {
        "\(matrixID):\(deviceID)"
    }

    // MARK: - Outbound

    /// 16 random bytes for a fresh call key.
    public static func generateKey() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Olm-encrypt our key to every other live member's devices.
    public func distribute(
        roomId: RoomId, memberships: [CallMembership],
        membershipID: String, index: Int, key: Data
    ) async throws {
        let userId = await client.session.userId
        let deviceId = await client.session.deviceId
        let others = memberships.filter {
            !($0.userId == userId && $0.deviceId == deviceId.value)
        }
        let content: [String: AnyCodable] = [
            "keys": .object([
                "index": .int(index),
                "key": .string(key.base64EncodedString()),
            ]),
            "member": .object([
                "id": .string(membershipID),
                "claimed_device_id": .string(deviceId.value),
            ]),
            "room_id": .string(roomId.value),
            "session": .object([
                "application": .string(rtcApplicationID),
                "call_id": .string(""),
                "scope": .string("m.room"),
            ]),
            "sent_ts": .int(Int(Date.now.timeIntervalSince1970 * 1000)),
        ]
        for member in others {
            let ids = (try? await client.olm.deviceIds(for: member.userId)) ?? []
            guard !ids.isEmpty else { continue }
            try await client.olm.sendEncrypted(
                eventType: rtcEncryptionKeysEventType, content: content,
                to: member.userId, devices: ids.map(DeviceId.init(_:)))
        }
        // Register our own key locally under both identity forms.
        let ownLegacy = Self.legacyIdentity(
            matrixID: userId.value, deviceID: deviceId.value)
        let ownHashed = Self.liveKitIdentity(
            matrixID: userId.value, claimedDeviceID: deviceId.value,
            memberID: membershipID)
        store(roomId: roomId, identity: ownLegacy, index: index, key: key)
        store(roomId: roomId, identity: ownHashed, index: index, key: key)
    }

    // MARK: - Inbound

    /// Stream of newly received keys. Follows the `deltas()` pattern:
    /// open across sync restarts, ends on cancellation.
    public func keyUpdates() -> AsyncStream<RTCKeyUpdate> {
        let (stream, continuation) = AsyncStream<RTCKeyUpdate>.makeStream()
        keyContinuations.append(continuation)
        return stream
    }

    /// Pump decrypted to-device batches into the key store. Run once per
    /// session; returns when the stream ends.
    public func pumpToDevice() async {
        for await batch in await client.decryptedToDevice() {
            for event in batch where event.type == rtcEncryptionKeysEventType {
                ingest(event)
            }
        }
    }

    private func ingest(_ event: BasicEvent) {
        guard let sender = event.sender,
            let roomId = event.content["room_id"]?.stringValue.map(RoomId.init(unchecked:)),
            let member = event.content["member"]?.objectValue,
            let memberID = member["id"]?.stringValue,
            let claimedDevice = member["claimed_device_id"]?.stringValue,
            let keysValue = event.content["keys"],
            let keyObj: [String: AnyCodable] = {
                if let obj = keysValue.objectValue { return obj }
                // Legacy single-element array form.
                if let arr = keysValue.arrayValue, arr.count == 1 {
                    return arr[0].objectValue
                }
                return nil
            }(),
            let index = keyObj["index"]?.intValue,
            let keyB64 = keyObj["key"]?.stringValue,
            let key = Data(base64Encoded: keyB64)
        else { return }
        let hashed = Self.liveKitIdentity(
            matrixID: sender.value, claimedDeviceID: claimedDevice,
            memberID: memberID)
        let legacy = Self.legacyIdentity(
            matrixID: sender.value, deviceID: claimedDevice)
        store(roomId: roomId, identity: hashed, index: index, key: key)
        store(roomId: roomId, identity: legacy, index: index, key: key)
    }

    private func store(roomId: RoomId, identity: String, index: Int, key: Data) {
        var list = keys[identity] ?? []
        guard !list.contains(where: { $0.index == index }) else { return }
        list.append(RTCKey(identity: identity, index: index, key: key))
        list.sort(by: { $0.index > $1.index })
        keys[identity] = list
        let update = RTCKeyUpdate(roomId: roomId, key: RTCKey(identity: identity, index: index, key: key))
        for continuation in keyContinuations {
            continuation.yield(update)
        }
    }

    /// Newest known key for an identity, if any.
    public func newestKey(for identity: String) -> RTCKey? {
        keys[identity]?.first
    }
}

/// A newly received call encryption key.
public struct RTCKeyUpdate: Hashable, Sendable {
    public var roomId: RoomId
    public var key: RTCKey

    public init(roomId: RoomId, key: RTCKey) {
        self.roomId = roomId
        self.key = key
    }
}
