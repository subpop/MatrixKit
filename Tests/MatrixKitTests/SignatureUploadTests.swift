import Foundation
import Testing

@testable import MatrixKit

/// The `/keys/signatures/upload` wire shape, pinned against the spec:
/// `{userId: {keyId: fullSignedObject}}` at top level with no
/// `"signatures"` wrapper (servers parse top-level keys as user IDs),
/// and a 200 carrying `failures` counts as rejection.
@Suite("Signature upload shape")
struct SignatureUploadTests {
    @Test("request encodes user IDs at top level with full device objects")
    func requestShape() throws {
        var device = DeviceKeys(
            userId: "@alice:example.com", deviceId: "HIJKLMN",
            keys: ["ed25519:HIJKLMN": "abc"])
        device.signatures = ["@alice:example.com": ["ed25519:sss": "sig"]]
        let request = UploadSignaturesRequest(signed: [
            "@alice:example.com": ["HIJKLMN": device]
        ])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        // No wrapper: the only top-level key is the user ID.
        #expect(json?.keys.sorted() == ["@alice:example.com"])
        let user = json?["@alice:example.com"] as? [String: Any]
        let uploaded = user?["HIJKLMN"] as? [String: Any]
        #expect(uploaded?["user_id"] as? String == "@alice:example.com")
        #expect(uploaded?["device_id"] as? String == "HIJKLMN")
        let sigs = (uploaded?["signatures"] as? [String: Any])?[
            "@alice:example.com"] as? [String: Any]
        #expect(sigs?["ed25519:sss"] as? String == "sig")
    }

    @Test("response surfaces per-signature failures")
    func responseFailures() throws {
        let accepted = try JSONDecoder().decode(
            UploadSignaturesResponse.self, from: Data("{}".utf8))
        #expect(accepted.failures == nil)
        let raw =
            #"{"failures": {"@subpop:matrix.org": {"vLJAYVbFIBMI": {"errcode": "M_INVALID_PARAM", "error": "400: Expected UserID string to start with '@'"}}}}"#
        let rejected = try JSONDecoder().decode(
            UploadSignaturesResponse.self, from: Data(raw.utf8))
        #expect(
            rejected.failures?["@subpop:matrix.org"]?["vLJAYVbFIBMI"]?
                .errcode == "M_INVALID_PARAM")
    }
}
