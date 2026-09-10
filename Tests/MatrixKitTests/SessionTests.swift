import Foundation
import Testing

@testable import MatrixKit

@Suite("Session")
struct SessionTests {
    @Test("updateIDs adopts server-assigned IDs (reauth recovery)")
    func updateIDs() async {
        let session = Session(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: ""),
            deviceId: DeviceId(""),
            accessToken: "token")
        #expect(await session.userId.value == "")
        await session.updateIDs(
            userId: UserId(unchecked: "@subpop:matrix.org"),
            deviceId: DeviceId("ABCD"))
        #expect(await session.userId.value == "@subpop:matrix.org")
        #expect(await session.deviceId.value == "ABCD")
        // Nil device keeps the existing one (whoami may omit it).
        await session.updateIDs(
            userId: UserId(unchecked: "@subpop:matrix.org"),
            deviceId: nil)
        #expect(await session.deviceId.value == "ABCD")
    }
}
