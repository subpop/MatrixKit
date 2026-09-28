import Foundation
import MatrixKit

/// Captured sync crypto-hook deliveries, in order. Shared by the sync,
/// sliding-sync, and (later) E2EE suites; moved from `SyncComplianceTests`.
public actor HookLog {
    public var toDeviceBatches: [[BasicEvent]] = []
    public var deviceLists: [([UserId], [UserId])] = []
    public var keyCounts: [Int?] = []

    public init() {}

    public func recordToDevice(_ events: [BasicEvent]) {
        toDeviceBatches.append(events)
    }

    public func recordDeviceLists(changed: [UserId], left: [UserId]) {
        deviceLists.append((changed, left))
    }

    public func recordKeyCount(_ count: Int?) {
        keyCounts.append(count)
    }

    public func hooks() -> SyncCryptoHooks {
        SyncCryptoHooks(
            handleToDevice: { events in
                await self.recordToDevice(events)
            },
            handleDeviceLists: { changed, left in
                await self.recordDeviceLists(changed: changed, left: left)
            },
            handleKeyCounts: { count in
                await self.recordKeyCount(count)
            })
    }
}
