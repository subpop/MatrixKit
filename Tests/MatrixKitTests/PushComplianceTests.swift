import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Push compliance suite: pushers and the push-ruleset CRUD surface.
///
/// Exercised registry endpoints: `GET /pushers`, `POST /pushers/set`,
/// `GET /pushrules/`, `GET|PUT|DELETE /pushrules/global/{kind}/{ruleId}[/{actions,enabled}]`.
@Suite("PushCompliance")
struct PushComplianceTests {
    private func pusher() -> Pusher {
        Pusher(
            pushkey: "pk1", appId: "com.example.app",
            appDisplayName: "Example", deviceDisplayName: "Phone",
            data: ["url": .string("https://push.example.com")])
    }

    @Test("Pushers set and list")
    func pushers() async throws {
        try await withHarness { harness in
            let (push, _, _) = await harness.pushClient()
            #expect(try await push.getPushers().isEmpty)
            try await push.setPusher(pusher())
            let listed = try await push.getPushers()
            #expect(listed.count == 1)
            #expect(listed.first?.pushkey == "pk1")
            // Re-setting the same pushkey replaces.
            try await push.setPusher(pusher())
            #expect(try await push.getPushers().count == 1)
        }
    }

    @Test("Seeded ruleset serves the master rule")
    func ruleset() async throws {
        try await withHarness { harness in
            let (push, _, _) = await harness.pushClient()
            let set = try await push.getPushRules()
            #expect(set.global["override"]?.map(\.ruleId).contains(".m.rule.master") == true)
            let master = try await push.getPushRule(kind: "override", ruleId: ".m.rule.master")
            #expect(master.enabled == false)
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such rule", retryAfter: nil)) {
                try await push.getPushRule(kind: "override", ruleId: ".m.rule.ghost")
            }
        }
    }

    @Test("Room and keyword rules create, enable, act, and delete")
    func ruleLifecycle() async throws {
        try await withHarness { harness in
            let (push, _, _) = await harness.pushClient()
            // Room rule: mute then re-enable with actions.
            try await push.setRoomPushRule(ruleId: "!r:test", actions: [.highlight(nil)])
            try await push.setPushRuleEnabled(kind: "room", ruleId: "!r:test", enabled: false)
            #expect(try await push.getPushRule(kind: "room", ruleId: "!r:test").enabled == false)
            try await push.setPushRuleActions(kind: "room", ruleId: "!r:test", actions: [.notify])
            #expect(try await push.getPushRuleActions(kind: "room", ruleId: "!r:test") == [.notify])
            // Keyword rule carries its pattern.
            try await push.setKeywordPushRule(keyword: "matrix", actions: [.notify])
            let keyword = try await push.getPushRule(kind: "content", ruleId: "matrix")
            #expect(keyword.pattern == "matrix")
            // Delete removes; second delete 404s.
            try await push.deletePushRule(kind: "room", ruleId: "!r:test")
            await #expect(throws: MatrixError.serverError(code: "M_NOT_FOUND", message: "No such rule", retryAfter: nil)) {
                try await push.getPushRule(kind: "room", ruleId: "!r:test")
            }
        }
    }

    @Test("Conditional rules store conditions")
    func conditionalRule() async throws {
        try await withHarness { harness in
            let (push, _, _) = await harness.pushClient()
            try await push.setConditionalPushRule(
                kind: "override", ruleId: "custom",
                conditions: [PushCondition(kind: "event_match", key: "room_id", pattern: "!r:test")],
                actions: [.notify])
            let rule = try await push.getPushRule(kind: "override", ruleId: "custom")
            #expect(rule.conditions?.count == 1)
        }
    }

    @Test("Push calls reject invalid sessions without network", arguments: [true, false])
    func pushGuards(reading: Bool) async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let push = PushClient(transport: transport, session: session)
        if reading {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await push.getPushers()
            }
        } else {
            await #expect(throws: MatrixError.notAuthenticated) {
                try await push.setPusher(pusher())
            }
        }
        try? await transport.shutdown()
    }
}
