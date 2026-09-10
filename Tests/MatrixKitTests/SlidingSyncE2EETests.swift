import Foundation
import Testing

@testable import MatrixKit

@Suite("Sliding sync E2EE extensions")
struct SlidingSyncE2EETests {
    private func makeClient() -> (client: SlidingSyncClient, transport: MatrixTransport) {
        let transport = MatrixTransport(
            homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "t")
        let client = SlidingSyncClient(
            transport: transport, session: session, store: StateStore())
        return (client, transport)
    }

    @Test("Requests carry only the typing extension without crypto hooks")
    func noHooks() async {
        let (client, transport) = makeClient()
        let request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.extensions?.typing?.enabled == true)
        #expect(request.extensions?.e2ee == nil)
        #expect(request.extensions?.toDevice == nil)
        try? await transport.shutdown()
    }

    @Test("Requests include E2EE extensions with hooks")
    func withHooks() async {
        let (client, transport) = makeClient()
        await client.setCryptoHooks(SyncCryptoHooks())
        let request = await client.makeRequest(timeoutMs: 1000)
        #expect(request.extensions?.e2ee?.enabled == true)
        #expect(request.extensions?.toDevice?.enabled == true)
        #expect(request.extensions?.toDevice?.limit == 100)
        #expect(request.extensions?.toDevice?.since == nil)
        try? await transport.shutdown()
    }

    @Test("Extension block encodes wire keys")
    func requestEncoding() throws {
        let request = SlidingSyncRequest(
            lists: [:],
            extensions: SlidingSyncExtensions(
                e2ee: E2EEExtension(),
                toDevice: ToDeviceExtension(limit: 100, since: "td1")))
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(json["extensions"]?["e2ee"]?["enabled"]?.boolValue == true)
        #expect(json["extensions"]?["to_device"]?["limit"]?.intValue == 100)
        #expect(json["extensions"]?["to_device"]?["since"]?.stringValue == "td1")
    }

    @Test("Parser routes extension events and device lists")
    func parseExtensions() throws {
        let json = """
        {
            "pos": "5",
            "extensions": {
                "to_device": {
                    "next_batch": "td9",
                    "events": [
                        {"type": "m.room_key", "sender": "@bob:x",
                         "content": {"algorithm": "m.megolm.v1.aes-sha2"}}
                    ]
                },
                "e2ee": {
                    "device_lists": {"changed": ["@bob:x"], "left": ["@carol:x"]}
                }
            }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SlidingSyncResponse.self, from: json)
        let delta = SlidingSyncResponseParser.parse(response)
        #expect(delta.toDevice.map(\.type) == ["m.room_key"])
        #expect(delta.deviceChanged == [UserId(unchecked: "@bob:x")])
        #expect(delta.deviceLeft == [UserId(unchecked: "@carol:x")])
        #expect(SlidingSyncResponseParser.toDeviceBatch(in: response.extensions) == "td9")
    }

    @Test("Missing extensions parse to empty deltas")
    func parseEmptyExtensions() throws {
        let json = #"{"pos": "5"}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(SlidingSyncResponse.self, from: json)
        let delta = SlidingSyncResponseParser.parse(response)
        #expect(delta.toDevice.isEmpty)
        #expect(delta.deviceChanged.isEmpty)
        #expect(delta.deviceLeft.isEmpty)
        #expect(SlidingSyncResponseParser.toDeviceBatch(in: response.extensions) == nil)
    }
}
