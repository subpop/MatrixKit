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
            transport: transport, session: session)
        return (client, transport)
    }

    struct ExtensionCase: Sendable {
        var withHooks: Bool
        var check: @Sendable (SlidingSyncRequest) -> Bool
    }

    static let extensionCases: [ExtensionCase] = [
        ExtensionCase(
            withHooks: false,
            check: {
                $0.extensions?.typing?.enabled == true
                    && $0.extensions?.e2ee == nil && $0.extensions?.toDevice == nil
            }),
        ExtensionCase(
            withHooks: true,
            check: {
                $0.extensions?.e2ee?.enabled == true
                    && $0.extensions?.toDevice?.enabled == true
                    && $0.extensions?.toDevice?.limit == 100
                    && $0.extensions?.toDevice?.since == nil
            }),
    ]

    @Test("Requests carry typing, plus E2EE extensions with hooks", arguments: extensionCases)
    func extensions(_ c: ExtensionCase) async {
        let (client, transport) = makeClient()
        if c.withHooks {
            await client.setCryptoHooks(SyncCryptoHooks())
        }
        #expect(c.check(await client.makeRequest(timeoutMs: 1000)))
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
