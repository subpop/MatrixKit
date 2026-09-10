import Crypto
import Foundation
import Testing

@testable import MatrixKitCrypto

/// Live two-way interop against the vodozemac harness
/// (`Tools/OlmInteropHarness`). Dev-only: records a known issue (loud
/// skip, suite stays green) when the harness binary has not been built.
///
/// Base64 on this wire is standard padded (`Data.base64EncodedString`);
/// the harness emits padded, and our decoder tolerates both.
@Suite("InteropLive")
struct InteropLiveTests {
    struct HarnessError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    final class Harness {
        private let process = Process()
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private var buffer = Data()

        init?(binary: String) {
            guard FileManager.default.isExecutableFile(atPath: binary)
            else { return nil }
            process.executableURL = URL(fileURLWithPath: binary)
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            do { try process.run() } catch { return nil }
        }

        deinit {
            process.terminate()
        }

        func call(_ request: [String: Any]) throws -> [String: Any] {
            var line = try JSONSerialization.data(
                withJSONObject: request)
            line.append(0x0A)
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            let outLine = try readLine()
            guard
                let json = try JSONSerialization.jsonObject(
                    with: outLine) as? [String: Any]
            else {
                throw HarnessError(message: "harness returned non-object")
            }
            if let error = json["error"] as? String {
                throw HarnessError(message: error)
            }
            guard let ok = json["ok"] as? [String: Any] else {
                throw HarnessError(message: "harness reply missing ok")
            }
            return ok
        }

        private func readLine() throws -> Data {
            // NOTE: blocking FileHandle.read(upToCount:) never returns
            // in this environment (deadlocks even on in-process loopback
            // pipes), so poll availableData (ioctl + non-blocking read)
            // with a deadline instead.
            let deadline = Date().addingTimeInterval(30)
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    return Data(line)
                }
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if !chunk.isEmpty {
                    buffer += chunk
                    continue
                }
                if !process.isRunning {
                    throw HarnessError(message: "harness EOF")
                }
                guard Date() < deadline else {
                    throw HarnessError(message: "harness reply timeout")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func harness() -> Harness? {
        if let env = ProcessInfo.processInfo.environment[
            "OLM_INTEROP_BIN"]
        {
            return Harness(binary: env)
        }
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repo = testsDir.deletingLastPathComponent()
            .deletingLastPathComponent()
        let bin = repo.appendingPathComponent(
            "Tools/OlmInteropHarness/target/debug/olm-interop-harness")
        return Harness(binary: bin.path)
    }

    private func requireHarness() -> Harness? {
        guard let h = harness() else {
            // Loud skip: visible in test output as a known issue rather
            // than a silent pass. Build the harness for live coverage:
            // `make -C Tools/OlmInteropHarness` (or set OLM_INTEROP_BIN).
            withKnownIssue(
                "olm-interop-harness not built — live vodozemac coverage skipped"
            ) {}
            return nil
        }
        return h
    }

    private func b64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    private func unb64(_ string: String) throws -> Data {
        guard let data = Primitives.base64UnpaddedDecode(string) else {
            throw HarnessError(message: "bad base64 from harness")
        }
        return data
    }

    @Test("Olm two-way exchange with vodozemac")
    func olmTwoWay() throws {
        guard let h = requireHarness() else { return }
        // Bob lives in the harness.
        let bob = try h.call(["cmd": "olm-account"])
        let bobID = try unb64(bob["curve25519"] as! String)
        let bobOTK = try unb64(bob["one_time_key"] as! String)
        var bobAccount = bob["account_pickle"]!

        // Alice (Swift) opens to Bob and speaks first.
        let aliceID = Curve25519.KeyAgreement.PrivateKey()
        let alicePub = Data(aliceID.publicKey.rawRepresentation)
        var alice = try OlmSession.createOutbound(
            ourIdentity: aliceID, theirIdentityKey: bobID,
            theirOneTimeKey: bobOTK)
        let (type, preKey) = try alice.encrypt(Data("hello bob".utf8))
        #expect(type == .preKey)

        // Bob (vodozemac) reads the pre-key and replies.
        let bobIn = try h.call([
            "cmd": "olm-inbound", "account_pickle": bobAccount,
            "peer_identity": b64(alicePub), "body": b64(preKey),
        ])
        #expect(
            try unb64(bobIn["plaintext"] as! String)
                == Data("hello bob".utf8))
        var bobSession = bobIn["session_pickle"]!
        bobAccount = bobIn["account_pickle"]!

        let bobReply = try h.call([
            "cmd": "olm-encrypt", "session_pickle": bobSession,
            "plaintext": b64(Data("hello alice".utf8)),
        ])
        #expect((bobReply["type"] as! Int) == 1)
        let replyBody = try unb64(bobReply["body"] as! String)
        #expect(try alice.decrypt(replyBody) == Data("hello alice".utf8))

        // And once more, to prove the ratchet settled both ways.
        let (type2, second) = try alice.encrypt(Data("m2".utf8))
        #expect(type2 == .normal)
        let bobSecond = try h.call([
            "cmd": "olm-decrypt", "session_pickle": bobReply["session_pickle"]!,
            "type": 1, "body": b64(second),
        ])
        #expect(
            try unb64(bobSecond["plaintext"] as! String) == Data("m2".utf8))
        bobSession = bobSecond["session_pickle"]!
        _ = bobSession
    }

    @Test("Megolm both directions with vodozemac")
    func megolmBothWays() throws {
        guard let h = requireHarness() else { return }
        // vodozemac → Swift.
        let created = try h.call(["cmd": "megolm-create"])
        let sessionKey = try unb64(created["session_key"] as! String)
        #expect(sessionKey.count == 229)
        var inbound = try MegolmSession.importSessionKey(sessionKey)
        let enc = try h.call([
            "cmd": "megolm-encrypt",
            "group_pickle": created["group_pickle"]!,
            "plaintext": b64(Data("group hello".utf8)),
        ])
        #expect(
            try inbound.decrypt(unb64(enc["body"] as! String))
                == Data("group hello".utf8))

        // Swift → vodozemac.
        var outbound = MegolmSession.create()
        let ourKey = try outbound.sessionKey()
        let imported = try h.call([
            "cmd": "megolm-import", "session_key": b64(ourKey),
        ])
        let ours = try outbound.encrypt(Data("swift hello".utf8))
        let back = try h.call([
            "cmd": "megolm-decrypt",
            "inbound_pickle": imported["inbound_pickle"]!,
            "body": b64(ours),
        ])
        #expect(
            try unb64(back["plaintext"] as! String)
                == Data("swift hello".utf8))
        #expect((back["message_index"] as! Int) == 0)
    }
}
