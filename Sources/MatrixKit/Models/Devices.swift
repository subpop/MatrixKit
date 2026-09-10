/// Session device models and management.
import Foundation

/// One session (device) on the current user's account.
public struct DeviceInfo: Hashable, Sendable, Identifiable {
    /// The device ID (e.g. `"ABCDEF1234"`).
    public var id: DeviceId { deviceId }
    /// The device ID.
    public var deviceId: DeviceId
    /// Human-readable name, if set.
    public var displayName: String?
    /// Last-seen IP address, if reported.
    public var lastSeenIP: String?
    /// Last-seen time, if reported.
    public var lastSeenTimestamp: Date?
    /// Whether this is the current session.
    public var isCurrentDevice: Bool

    public init(
        deviceId: DeviceId,
        displayName: String? = nil,
        lastSeenIP: String? = nil,
        lastSeenTimestamp: Date? = nil,
        isCurrentDevice: Bool = false
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.lastSeenIP = lastSeenIP
        self.lastSeenTimestamp = lastSeenTimestamp
        self.isCurrentDevice = isCurrentDevice
    }
}

/// `GET /devices` response body.
public struct DevicesResponse: Hashable, Sendable, Codable {
    /// Sessions on this account.
    public var devices: [DeviceEntry]

    public init(devices: [DeviceEntry] = []) {
        self.devices = devices
    }
}

/// One session entry of `GET /devices`.
public struct DeviceEntry: Hashable, Sendable, Codable {
    /// The device ID.
    public var deviceId: DeviceId
    /// Human-readable name, if set.
    public var displayName: String?
    /// Last-seen IP address, if reported.
    public var lastSeenIP: String?
    /// Last-seen time in milliseconds, if reported.
    public var lastSeenTimestampMs: Int?

    public init(
        deviceId: DeviceId,
        displayName: String? = nil,
        lastSeenIP: String? = nil,
        lastSeenTimestampMs: Int? = nil
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.lastSeenIP = lastSeenIP
        self.lastSeenTimestampMs = lastSeenTimestampMs
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case displayName = "display_name"
        case lastSeenIP = "last_seen_ip"
        case lastSeenTimestampMs = "last_seen_ts"
    }
}

/// `PUT /devices/{deviceId}` request body. Renaming may be UIAA-gated:
/// retry with `auth` after a 401 challenge.
public struct RenameDeviceRequest: Hashable, Sendable, Codable {
    /// New human-readable device name.
    public var displayName: String
    /// Completed UIAA stage for retrying after a 401 challenge.
    public var auth: UIAAuth?

    public init(displayName: String, auth: UIAAuth? = nil) {
        self.displayName = displayName
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case auth
    }
}
