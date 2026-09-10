import Testing

@testable import MatrixKit

@Suite("MatrixError")
struct MatrixErrorTests {
    @Test("Rate limits and 5xx-style errors are retryable")
    func retryable() {
        #expect(MatrixError.rateLimited(retryAfter: nil).isRetryable)
        #expect(MatrixError.networkError("boom").isRetryable)
        #expect(
            MatrixError.serverError(code: "M_UNKNOWN", message: "x", retryAfter: nil).isRetryable)
        #expect(!MatrixError.unknownToken.isRetryable)
        #expect(!MatrixError.notAuthenticated.isRetryable)
        #expect(
            !MatrixError.serverError(code: "M_FORBIDDEN", message: "x", retryAfter: nil)
                .isRetryable)
    }

    @Test("retryAfter surfaces the server hint")
    func retryAfter() {
        #expect(
            MatrixError.rateLimited(retryAfter: .milliseconds(500)).retryAfter
                == .milliseconds(500))
        #expect(MatrixError.unknownToken.retryAfter == nil)
    }

    @Test("Descriptions are non-empty")
    func descriptions() {
        let errors: [MatrixError] = [
            .invalidIdentifier("x"), .invalidURL("x"), .notAuthenticated, .transportClosed,
            .networkError("x"), .encodingError("x"), .decodingError("x"),
            .serverError(code: "M_X", message: "y", retryAfter: nil),
            .rateLimited(retryAfter: nil), .unknownToken,
            .unexpectedStatus(418, body: nil), .syncFailed("x"),
            .noReachableDevices("x"),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
}
