import Foundation
import Testing

@testable import MatrixKit

@Suite("Session")
struct SessionTests {
    @Test("credentials reflect the latest rotation as one snapshot")
    func credentialsSnapshot() async {
        let session = Session(
            homeserver: URL(string: "https://matrix.org")!,
            userId: UserId(unchecked: "@a:matrix.org"),
            deviceId: DeviceId("ABCD"),
            accessToken: "a1",
            refreshToken: "r1")
        await session.updateOIDC(clientId: "cid", tokenEndpoint: "https://x/token")
        await session.update(accessToken: "a2", refreshToken: "r2")
        let credentials = await session.credentials
        #expect(credentials.accessToken == "a2")
        #expect(credentials.refreshToken == "r2")
        #expect(credentials.oidcClientId == "cid")
        #expect(credentials.oidcTokenEndpoint == "https://x/token")
    }

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
