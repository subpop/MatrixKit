import Foundation
import MatrixKit

/// MSC4140 delayed events (unstable): schedule a state event the
/// homeserver sends after a delay even if the client disconnects.
/// MatrixRTC uses it for leave-on-disconnect membership cleanup.
public actor DelayedEvents {
    private let client: MatrixClient

    public init(client: MatrixClient) {
        self.client = client
    }

    /// Schedule a state event after `delayMs`. Returns the server's
    /// `delay_id` for later cancellation.
    @discardableResult
    public func scheduleStateEvent(
        roomId: RoomId, type: String, stateKey: String = "",
        content: [String: AnyCodable], delayMs: Int
    ) async throws -> String {
        struct DelayResponse: Decodable {
            var delayId: String
            private enum CodingKeys: String, CodingKey {
                case delayId = "delay_id"
            }
        }
        let response: DelayResponse = try await client.transport.send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomId.value.pathSegmentEncoded)"
                + "/state/\(type.pathSegmentEncoded)/\(stateKey.pathSegmentEncoded)",
            query: ["org.matrix.msc4140.delay": "\(delayMs)"],
            body: AnyCodableDictionary(content),
            accessToken: await client.session.accessToken)
        return response.delayId
    }

    /// Cancel a scheduled event (`{"action": "cancel"}`).
    public func cancel(delayId: String) async throws {
        struct EmptyResponse: Decodable {}
        struct CancelRequest: Encodable {
            var action = "cancel"
        }
        let _: EmptyResponse = try await client.transport.send(
            .post,
            path: "/_matrix/client/unstable/org.matrix.msc4140/delayed_events/\(delayId.pathSegmentEncoded)",
            body: CancelRequest(),
            accessToken: await client.session.accessToken)
    }
}
