import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

@Suite("TransportReset")
struct TransportResetTests {
    @Test("Requests succeed on the fresh pool after a reset")
    func requestsSucceedAfterReset() async throws {
        try await withHarness { harness in
            let (auth, _, transport) = await harness.authClient()
            _ = try await auth.whoAmI()
            await transport.resetConnections()
            _ = try await auth.whoAmI()
        }
    }
}
