import Foundation
import Testing

@testable import MatrixKit

@Suite("Event type coverage")
struct EventTypeTests {
    // MARK: - Tables

    struct EventTypeCase: Sendable {
        var wire: String
        var expected: EventType
        var canonical: String
    }

    static let eventCases: [EventTypeCase] = [
        EventTypeCase(
            wire: "m.room.encrypted", expected: .roomEncrypted,
            canonical: "m.room.encrypted"),
        EventTypeCase(
            wire: "m.poll.response", expected: .pollResponse,
            canonical: "m.poll.response"),
        EventTypeCase(
            wire: "org.matrix.msc3381.poll.response", expected: .pollResponse,
            canonical: "m.poll.response"),
        EventTypeCase(
            wire: "m.poll.end", expected: .pollEnd,
            canonical: "m.poll.end"),
        EventTypeCase(
            wire: "org.matrix.msc3381.poll.end", expected: .pollEnd,
            canonical: "m.poll.end"),
        EventTypeCase(
            wire: "m.call.invite", expected: .callInvite,
            canonical: "m.call.invite"),
        EventTypeCase(
            wire: "m.call.answer", expected: .callAnswer,
            canonical: "m.call.answer"),
        EventTypeCase(
            wire: "m.call.hangup", expected: .callHangup,
            canonical: "m.call.hangup"),
        EventTypeCase(
            wire: "m.call.reject", expected: .callReject,
            canonical: "m.call.reject"),
        EventTypeCase(
            wire: "m.call.candidates", expected: .callCandidates,
            canonical: "m.call.candidates"),
        EventTypeCase(
            wire: "m.call.negotiate", expected: .callNegotiate,
            canonical: "m.call.negotiate"),
        EventTypeCase(
            wire: "m.call.select_answer", expected: .callSelectAnswer,
            canonical: "m.call.select_answer"),
        EventTypeCase(
            wire: "m.call.sdp_stream_metadata_changed",
            expected: .callSDPStreamMetadataChanged,
            canonical: "m.call.sdp_stream_metadata_changed"),
        // Pre-existing behavior spot-checks.
        EventTypeCase(
            wire: "m.room.message", expected: .roomMessage,
            canonical: "m.room.message"),
        EventTypeCase(
            wire: "org.matrix.msc3381.poll.start", expected: .pollStart,
            canonical: "m.poll.start"),
        EventTypeCase(
            wire: "m.call.member", expected: .callMember,
            canonical: "org.matrix.msc3401.call.member"),
        EventTypeCase(
            wire: "com.example.custom", expected: .unknown("com.example.custom"),
            canonical: "com.example.custom"),
    ]

    struct MessageTypeCase: Sendable {
        var wire: String
        var expected: MessageType
    }

    static let messageCases: [MessageTypeCase] = [
        MessageTypeCase(wire: "m.text", expected: .text),
        MessageTypeCase(wire: "m.emote", expected: .emote),
        MessageTypeCase(wire: "m.notice", expected: .notice),
        MessageTypeCase(wire: "m.image", expected: .image),
        MessageTypeCase(wire: "m.file", expected: .file),
        MessageTypeCase(wire: "m.audio", expected: .audio),
        MessageTypeCase(wire: "m.video", expected: .video),
        MessageTypeCase(wire: "m.location", expected: .location),
        MessageTypeCase(
            wire: "m.key.verification.request",
            expected: .keyVerificationRequest),
        MessageTypeCase(wire: "m.bad.encrypted", expected: .badEncrypted),
        MessageTypeCase(wire: "m.server_notice", expected: .serverNotice),
        MessageTypeCase(
            wire: "com.example.custom",
            expected: .unknown("com.example.custom")),
    ]

    // MARK: - Tests

    @Test("Event types round-trip, unstable prefixes canonicalize", arguments: eventCases)
    func eventTypeRoundTrip(row: EventTypeCase) {
        let decoded = EventType(rawValue: row.wire)
        #expect(decoded == row.expected)
        #expect(decoded.rawValue == row.canonical)
    }

    @Test("Event types survive Codable", arguments: eventCases)
    func eventTypeCodable(row: EventTypeCase) throws {
        let data = try JSONEncoder().encode(EventType(rawValue: row.wire))
        let decoded = try JSONDecoder().decode(EventType.self, from: data)
        #expect(decoded == row.expected)
    }

    @Test("Message types round-trip, unknowns fall back", arguments: messageCases)
    func messageTypeRoundTrip(row: MessageTypeCase) {
        let decoded = MessageType(rawValue: row.wire)
        #expect(decoded == row.expected)
        #expect(decoded.rawValue == row.wire)
    }

    @Test("MessageContent decodes despite an unknown msgtype")
    func unknownMsgtypeDecodes() throws {
        let data = """
            {"msgtype":"com.example.custom","body":"hello"}
            """.data(using: .utf8)!
        let content = try JSONDecoder().decode(MessageContent.self, from: data)
        #expect(content.msgtype == .unknown("com.example.custom"))
        #expect(content.body == "hello")
    }

    @Test("Encrypted content decodes the Megolm wire shape")
    func encryptedContent() throws {
        let data = """
            {"algorithm":"m.megolm.v1.aes-sha2","sender_key":"opaque",
             "session_id":"session","ciphertext":"cipher"}
            """.data(using: .utf8)!
        let content = try JSONDecoder().decode(
            EncryptedEventContent.self, from: data)
        #expect(content.algorithm == "m.megolm.v1.aes-sha2")
        #expect(content.senderKey == "opaque")
        #expect(content.sessionId == "session")
        #expect(content.ciphertext?.stringValue == "cipher")
    }

    @Test("Poll response decodes stable and unstable formats and encodes unstable")
    func pollResponseContent() throws {
        let stable = """
            {"m.relates_to":{"rel_type":"m.reference","event_id":"$poll:x"},
             "m.selections":["a1","a2"]}
            """.data(using: .utf8)!
        let content = try JSONDecoder().decode(PollResponseContent.self, from: stable)
        #expect(content.relatesTo.eventId == EventId(unchecked: "$poll:x"))
        #expect(content.relatesTo.relType == .reference)
        #expect(content.answers == ["a1", "a2"])

        let encoded = try JSONEncoder().encode(content)
        let roundTripped = try JSONDecoder().decode(
            PollResponseContent.self, from: encoded)
        #expect(roundTripped == content)
        let wire = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let response = try #require(
            wire["org.matrix.msc3381.poll.response"] as? [String: Any])
        #expect(response["answers"] as? [String] == ["a1", "a2"])
        #expect(wire["m.selections"] == nil)

        let unstable = """
            {"m.relates_to":{"rel_type":"m.reference","event_id":"$poll:x"},
             "org.matrix.msc3381.poll.response":{"answers":["a1"]}}
            """.data(using: .utf8)!
        let unstableContent = try JSONDecoder().decode(
            PollResponseContent.self, from: unstable)
        #expect(unstableContent.answers == ["a1"])
    }

    @Test("Poll start encodes unstable and decodes stable and unstable shapes")
    func pollStartContent() throws {
        let content = PollStartContent(
            question: "Lunch?", kind: .disclosed, maxSelections: 1,
            answers: [
                PollStartContent.Answer(id: "a1", text: "Pizza"),
                PollStartContent.Answer(id: "a2", text: "Tacos"),
            ])
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PollStartContent.self, from: encoded)
        #expect(decoded == content)

        let wire = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["org.matrix.msc1767.text"] as? String == "Lunch?\n1. Pizza\n2. Tacos")
        let block = try #require(
            wire["org.matrix.msc3381.poll.start"] as? [String: Any])
        #expect(block["kind"] as? String == "org.matrix.msc3381.poll.disclosed")
        #expect(block["max_selections"] as? Int == 1)
        let question = try #require(block["question"] as? [String: Any])
        #expect(question["org.matrix.msc1767.text"] as? String == "Lunch?")
        let answers = try #require(block["answers"] as? [[String: Any]])
        #expect(answers.map { $0["id"] as? String } == ["a1", "a2"])
        #expect(answers[0]["org.matrix.msc1767.text"] as? String == "Pizza")

        let stable = """
            {"m.text":[{"body":"Dinner?\\n1. Soup"}],
             "m.poll":{"max_selections":2,
                "question":{"m.text":[{"body":"Dinner?"}]},
                "answers":[{"m.id":"b1","m.text":[{"body":"Soup"}]}],
                "kind":"m.disclosed"}}
            """.data(using: .utf8)!
        let stableContent = try JSONDecoder().decode(PollStartContent.self, from: stable)
        #expect(stableContent.question == "Dinner?")
        #expect(stableContent.answers == [.init(id: "b1", text: "Soup")])
        #expect(stableContent.kind == .disclosed)
        #expect(stableContent.maxSelections == 2)

        // Missing or unknown kinds assume undisclosed; max_selections
        // defaults to 1.
        let defaulted = """
            {"org.matrix.msc1767.text":"Dinner?\\n1. Soup",
             "org.matrix.msc3381.poll.start":{
                "question":{"org.matrix.msc1767.text":"Dinner?"},
                "answers":[{"id":"b1","org.matrix.msc1767.text":"Soup"}]}}
            """.data(using: .utf8)!
        let defaultedContent = try JSONDecoder().decode(
            PollStartContent.self, from: defaulted)
        #expect(defaultedContent.kind == .undisclosed)
        #expect(defaultedContent.maxSelections == 1)

        let legacy = """
            {"m.text":"Open poll test",
             "m.poll.start":{"kind":"m.poll.disclosed",
                "question":{"org.matrix.msc1767.text":"Open poll test"},
                "answers":[{"id":"c1","org.matrix.msc1767.text":"Option 1"}]}}
            """.data(using: .utf8)!
        #expect((try? JSONDecoder().decode(PollStartContent.self, from: legacy)) == nil)
    }

    @Test("Poll end decodes stable and unstable formats and encodes unstable")
    func pollEndContent() throws {
        let stable = """
            {"m.relates_to":{"rel_type":"m.reference","event_id":"$poll:x"},
             "m.text":[{"mimetype":"text/plain","body":"Poll ended"}]}
            """.data(using: .utf8)!
        let stableContent = try JSONDecoder().decode(PollEndContent.self, from: stable)
        #expect(stableContent.relatesTo.eventId == EventId(unchecked: "$poll:x"))
        #expect(stableContent.fallbackText == "Poll ended")

        let encoded = try JSONEncoder().encode(
            PollEndContent(
                relatesTo: RelatesTo(
                    eventId: EventId(unchecked: "$poll:x"), relType: .reference)))
        let roundTripped = try JSONDecoder().decode(PollEndContent.self, from: encoded)
        #expect(roundTripped.fallbackText == "Poll ended")
        let wire = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(wire["org.matrix.msc1767.text"] as? String == "Poll ended")
        let endBlock = try #require(
            wire["org.matrix.msc3381.poll.end"] as? [String: Any])
        #expect(endBlock.isEmpty)
        #expect(wire["m.text"] == nil)

        let unstable = """
            {"m.relates_to":{"rel_type":"m.reference","event_id":"$poll:x"},
             "org.matrix.msc1767.text":"Poll ended",
             "org.matrix.msc3381.poll.end":{}}
            """.data(using: .utf8)!
        let unstableContent = try JSONDecoder().decode(PollEndContent.self, from: unstable)
        #expect(unstableContent == stableContent)
    }

    @Test("Server notice decodes the full wire shape")
    func serverNoticeContent() throws {
        let data = """
            {"body":"Limit reached","server_notice_type":"m.server_notice.usage_limit_reached",
             "admin_contact":"mailto:admin@example.com","limit_type":"monthly_active_user"}
            """.data(using: .utf8)!
        let content = try JSONDecoder().decode(
            ServerNoticeContent.self, from: data)
        #expect(content.body == "Limit reached")
        #expect(content.serverNoticeType == "m.server_notice.usage_limit_reached")
        #expect(content.adminContact == "mailto:admin@example.com")
        #expect(content.limitType == "monthly_active_user")
    }

    @Test("Server notice decodes a body-only payload")
    func serverNoticeMinimal() throws {
        let data = """
            {"body":"Hello"}
            """.data(using: .utf8)!
        let content = try JSONDecoder().decode(
            ServerNoticeContent.self, from: data)
        #expect(content.body == "Hello")
        #expect(content.serverNoticeType == nil)
        #expect(content.limitType == nil)
    }
}
