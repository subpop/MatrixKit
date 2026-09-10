import Foundation
import Testing

@testable import MatrixKit

/// The 401 body matrix.org returns when an identity already exists.
private let resetChallengeJSON = """
    {
      "flows": [{"stages": ["m.oauth"]}, {"stages": ["org.matrix.cross_signing_reset"]}],
      "msg": "To reset your end-to-end encryption cross-signing identity, approve it first.",
      "params": {
        "m.oauth": {"url": "https://account.matrix.org/account/?action=org.matrix.cross_signing_reset"},
        "org.matrix.cross_signing_reset": {"url": "https://account.matrix.org/account/?action=org.matrix.cross_signing_reset"}
      },
      "session": "sess_123"
    }
    """

@Suite("UIAA")
struct UIAATests {
    private func challenge() throws -> UIAAChallenge {
        try JSONDecoder().decode(
            UIAAChallenge.self, from: Data(resetChallengeJSON.utf8))
    }

    @Test("Decodes a reset challenge")
    func decode() throws {
        let challenge = try challenge()
        #expect(challenge.flows.count == 2)
        #expect(challenge.session == "sess_123")
        #expect(challenge.message?.hasPrefix("To reset") == true)
    }

    @Test("Detects offered stages")
    func stages() throws {
        let challenge = try challenge()
        #expect(challenge.offersStage(UIAAChallenge.resetStage))
        #expect(challenge.offersStage(UIAAChallenge.oauthStage))
        #expect(!challenge.offersStage("m.login.password"))
    }

    @Test("Extracts per-stage approval URLs")
    func approvalURL() throws {
        let challenge = try challenge()
        #expect(
            challenge.approvalURL(for: UIAAChallenge.oauthStage)
                == "https://account.matrix.org/account/?action=org.matrix.cross_signing_reset")
        #expect(challenge.approvalURL(for: "m.login.password") == nil)
    }

    @Test("Bodies without flows are not challenges")
    func notAChallenge() {
        let body = Data(#"{"errcode":"M_FORBIDDEN","error":"nope"}"#.utf8)
        #expect((try? JSONDecoder().decode(UIAAChallenge.self, from: body)) == nil)
    }

    @Test("Upload request carries UIAA auth when present")
    func authEncoding() throws {
        let request = UploadSigningKeysRequest(
            auth: UIAAuth(type: UIAAChallenge.resetStage, session: "sess_123"))
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let auth = try #require(json?["auth"] as? [String: Any])
        #expect(auth["type"] as? String == "org.matrix.cross_signing_reset")
        #expect(auth["session"] as? String == "sess_123")
    }

    @Test("Upload request omits auth by default")
    func authOmitted() throws {
        let data = try JSONEncoder().encode(UploadSigningKeysRequest())
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["auth"] == nil)
    }

    @Test("Error description names the stages")
    func description() throws {
        let text = MatrixError.uiaa(try challenge()).description
        #expect(text.contains("m.oauth"))
        #expect(text.contains("org.matrix.cross_signing_reset"))
        #expect(!MatrixError.uiaa(try challenge()).isRetryable)
    }
}
