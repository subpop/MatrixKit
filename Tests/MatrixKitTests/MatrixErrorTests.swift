import Testing

@testable import MatrixKit

@Suite("MatrixError")
struct MatrixErrorTests {
    struct BoolCase: Sendable {
        var id: String
        var error: MatrixError
        var expected: Bool
    }

    static let retryableCases: [BoolCase] = [
        BoolCase(id: "rate limited", error: .rateLimited(retryAfter: nil), expected: true),
        BoolCase(id: "network error", error: .networkError("boom"), expected: true),
        BoolCase(id: "M_UNKNOWN", error: .serverError(code: "M_UNKNOWN", message: "x", retryAfter: nil), expected: true),
        BoolCase(id: "M_5xx prefix", error: .serverError(code: "M_500", message: "x", retryAfter: nil), expected: true),
        BoolCase(id: "unknown token", error: .unknownToken(softLogout: nil), expected: false),
        BoolCase(id: "not authenticated", error: .notAuthenticated, expected: false),
        BoolCase(id: "M_FORBIDDEN", error: .serverError(code: "M_FORBIDDEN", message: "x", retryAfter: nil), expected: false),
        BoolCase(id: "cancelled", error: .cancelled, expected: false),
    ]

    @Test("Retryable errors", arguments: retryableCases)
    func retryable(_ c: BoolCase) {
        #expect(c.error.isRetryable == c.expected)
    }

    @Test("retryAfter surfaces the server hint", arguments: [
        BoolCase(id: "hint", error: .rateLimited(retryAfter: .milliseconds(500)), expected: true),
        BoolCase(id: "no hint", error: .unknownToken(softLogout: nil), expected: false),
    ])
    func retryAfter(_ c: BoolCase) {
        switch c.error {
        case .rateLimited(let after):
            #expect(after == .milliseconds(500))
        default:
            #expect(c.error.retryAfter == nil)
        }
    }

    static let allErrors: [MatrixError] = [
        .invalidIdentifier("x"), .invalidURL("x"), .notAuthenticated, .transportClosed,
        .networkError("x"), .encodingError("x"), .decodingError("x"),
        .serverError(code: "M_X", message: "y", retryAfter: nil),
        .rateLimited(retryAfter: nil), .unknownToken(softLogout: nil),
        .unexpectedStatus(418, body: nil), .syncFailed("x"),
        .noReachableDevices("x"), .cancelled,
    ]

    @Test("Descriptions are non-empty", arguments: allErrors)
    func descriptions(_ error: MatrixError) {
        #expect(!error.description.isEmpty)
    }

    static let cancellationCases: [BoolCase] = [
        BoolCase(id: "cancelled", error: .cancelled, expected: true),
        BoolCase(id: "wrapped CancellationError", error: .networkError("cancelled: \(CancellationError())"), expected: true),
        BoolCase(id: "plain network error", error: .networkError("boom"), expected: false),
        BoolCase(id: "unknown token", error: .unknownToken(softLogout: nil), expected: false),
    ]

    @Test("Cancellation reads as cancellation, never failure", arguments: cancellationCases)
    func cancelled(_ c: BoolCase) {
        #expect(c.error.isCancellation == c.expected)
    }

    struct AccessorCase: Sendable {
        var id: String
        var value: AnyCodable
        var string: String?
        var int: Int?
        var bool: Bool?
        var object: [String: AnyCodable]?
        var array: [AnyCodable]?
    }

    static let accessorCases: [AccessorCase] = [
        AccessorCase(
            id: "string", value: .string("hi"),
            string: "hi", int: nil, bool: nil, object: nil, array: nil),
        AccessorCase(
            id: "int", value: .int(7),
            string: nil, int: 7, bool: nil, object: nil, array: nil),
        AccessorCase(
            id: "bool", value: .bool(true),
            string: nil, int: nil, bool: true, object: nil, array: nil),
        AccessorCase(
            id: "object", value: .object(["k": .string("v")]),
            string: nil, int: nil, bool: nil, object: ["k": .string("v")], array: nil),
        AccessorCase(
            id: "array", value: .array([.int(1)]),
            string: nil, int: nil, bool: nil, object: nil, array: [.int(1)]),
        AccessorCase(
            id: "null", value: .null,
            string: nil, int: nil, bool: nil, object: nil, array: nil),
    ]

    @Test("Typed accessors return values only for their own case", arguments: accessorCases)
    func accessors(_ c: AccessorCase) {
        #expect(c.value.stringValue == c.string)
        #expect(c.value.intValue == c.int)
        #expect(c.value.boolValue == c.bool)
        #expect(c.value.objectValue == c.object)
        #expect(c.value.arrayValue == c.array)
    }
}
