import Foundation
import MatrixKit

/// In-memory homeserver for Olm flows: stashes `/keys/upload` blobs per
/// device and serves `/keys/query` + `/keys/claim` (popping OTKs).
///
/// Shared fake (moved from `OlmConnectorTests`): every suite that drives
/// `OlmConnector` uses this instead of a per-file copy. Request logs
/// (`queriedUsers`, `claimedDevices`, `uploads`) make table-driven
/// assertions possible without reaching into server state.
public actor FakeKeys: OlmKeyService {
    private var devices: [String: [String: DeviceKeys]] = [:]
    private var otks: [String: [String: [String: ClaimedOneTimeKey]]] = [:]
    private var fallbacks: [String: [String: Set<String>]] = [:]

    public var queryCalls = 0
    /// Users argument of each `queryKeys` call, in order.
    public var queriedUsers: [[UserId]] = []
    /// `(user, device)` of each `claimKeys` call, in order.
    public var claimedDevices: [(user: String, device: String)] = []
    /// Every `uploadDeviceKeys` request, in order.
    public var uploads: [UploadDeviceKeysRequest] = []

    public init() {}

    /// Clear logs and counters without dropping seeded/uploaded state.
    public func resetLogs() {
        queryCalls = 0
        queriedUsers = []
        claimedDevices = []
        uploads = []
    }

    public func queryKeys(
        users: [UserId]
    ) async throws(MatrixError) -> KeyQueryResponse {
        queryCalls += 1
        queriedUsers.append(users)
        var out: [String: [String: DeviceKeys]] = [:]
        for user in users {
            out[user.value] = devices[user.value] ?? [:]
        }
        return KeyQueryResponse(deviceKeys: out)
    }

    public func claimKeys(
        user: UserId, device: String
    ) async throws(MatrixError) -> ClaimKeysResponse {
        claimedDevices.append((user.value, device))
        let deviceId: String
        if device == "*" {
            guard let first = otks[user.value]?.first(where: { !$0.value.isEmpty }) else {
                return ClaimKeysResponse()
            }
            deviceId = first.key
        } else {
            deviceId = device
        }
        guard var pool = otks[user.value]?[deviceId], !pool.isEmpty else {
            return ClaimKeysResponse()
        }
        let keyId = pool.keys.sorted().first!
        let claimed = pool.removeValue(forKey: keyId)!
        otks[user.value]?[deviceId] = pool
        return ClaimKeysResponse(
            oneTimeKeys: [user.value: [deviceId: [keyId: claimed]]])
    }

    public func uploadDeviceKeys(
        _ request: UploadDeviceKeysRequest
    ) async throws(MatrixError) -> UploadDeviceKeysResponse {
        uploads.append(request)
        if let deviceKeys = request.deviceKeys {
            devices[deviceKeys.userId, default: [:]][deviceKeys.deviceId] = deviceKeys
        }
        var total = 0
        // Attribute OTKs to the uploading device via its device_keys.
        if let deviceKeys = request.deviceKeys {
            let user = deviceKeys.userId
            let device = deviceKeys.deviceId
            if let oneTime = request.oneTimeKeys {
                for (keyId, value) in oneTime {
                    guard
                        let obj = value.objectValue,
                        let key = obj["key"]?.stringValue,
                        let sigs = obj["signatures"]?.objectValue
                    else { continue }
                    var sigMap: [String: [String: String]] = [:]
                    for (u, inner) in sigs {
                        var m: [String: String] = [:]
                        for (k, v) in inner.objectValue ?? [:] {
                            if let s = v.stringValue { m[k] = s }
                        }
                        sigMap[u] = m
                    }
                    otks[user, default: [:]][device, default: [:]][keyId] =
                        ClaimedOneTimeKey(key: key, signatures: sigMap)
                    total += 1
                }
            }
            if let fallback = request.fallbackKeys {
                for keyId in fallback.keys {
                    fallbacks[user, default: [:]][device, default: []].insert(keyId)
                }
            }
        }
        return UploadDeviceKeysResponse(
            oneTimeKeyCounts: ["signed_curve25519": total])
    }

    public func otkCount(user: String, device: String) -> Int {
        otks[user]?[device]?.count ?? 0
    }

    /// Seed a device's published keys (fixes `/keys/query` results).
    public func seedDevice(user: String, device: String) {
        devices[user, default: [:]][device] = DeviceKeys(
            userId: user, deviceId: device)
    }

    /// Seed full published device keys: the record exists but no
    /// one-time keys were ever uploaded (stale-device shape).
    public func seedKeys(user: String, device: String, keys: DeviceKeys) {
        devices[user, default: [:]][device] = keys
    }

    public func fallbackCount(user: String, device: String) -> Int {
        fallbacks[user]?[device]?.count ?? 0
    }
}
