import Foundation
import Testing

@testable import MatrixKit

@Suite("Redaction pruning")
struct EventRedactorTests {
    struct PruneCase: Sendable {
        var type: String
        var content: [String: AnyCodable]
        var check: @Sendable ([String: AnyCodable]) -> Bool
    }

    static let pruneCases: [PruneCase] = [
        PruneCase(
            type: "m.room.message",
            content: ["body": .string("hi"), "msgtype": .string("m.text")],
            check: { $0.isEmpty }),
        PruneCase(
            type: "com.example.custom",
            content: ["secret": .string("x")],
            check: { $0.isEmpty }),
        PruneCase(
            type: "m.room.encrypted",
            content: ["ciphertext": .string("abc"), "session_id": .string("s")],
            check: { $0.isEmpty }),
        PruneCase(
            type: "m.room.member",
            content: [
                "membership": .string("invite"),
                "displayname": .string("Alice"),
                "third_party_invite": .object([
                    "display_name": .string("Bob"),
                    "signed": .object(["token": .string("t")]),
                ]),
            ],
            check: {
                $0["membership"]?.stringValue == "invite" && $0["displayname"] == nil
                    && $0["third_party_invite"]?.objectValue?.keys.sorted() == ["signed"]
            }),
        PruneCase(
            type: "m.room.create",
            content: ["creator": .string("@alice:x"), "room_version": .string("12")],
            check: { $0 == ["creator": .string("@alice:x"), "room_version": .string("12")] }),
        PruneCase(
            type: "m.room.power_levels",
            content: ["ban": .int(50), "invite": .int(0), "custom_key": .string("x")],
            check: { $0["ban"]?.intValue == 50 && $0["invite"]?.intValue == 0 && $0["custom_key"] == nil }),
        PruneCase(
            type: "m.room.join_rules",
            content: ["join_rule": .string("invite"), "allow": .array([]), "extra": .string("x")],
            check: { $0.keys.sorted() == ["allow", "join_rule"] }),
        PruneCase(
            type: "m.room.history_visibility",
            content: ["history_visibility": .string("shared"), "extra": .string("x")],
            check: { $0.keys.sorted() == ["history_visibility"] }),
        PruneCase(
            type: "m.room.redaction",
            content: ["redacts": .string("$target"), "reason": .string("spam")],
            check: { $0.keys.sorted() == ["redacts"] }),
    ]

    @Test("Redaction pruning keeps protocol keys per event type", arguments: pruneCases)
    func pruning(_ c: PruneCase) {
        #expect(c.check(EventRedactor.prunedContent(type: c.type, content: c.content)))
    }
}
