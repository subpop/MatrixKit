import Foundation
import Testing

import MatrixKitCrypto
@testable import MatrixKit

@Suite("ClientInstanceDirectory")
struct ClientInstanceDirectoryTests {
    @Test("Sub-stores of distinct instances share nothing")
    func isolatedStores() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let one = ClientInstanceDirectory(
            root: base.appendingPathComponent("one", isDirectory: true))
        let two = ClientInstanceDirectory(
            root: base.appendingPathComponent("two", isDirectory: true))
        #expect(one.root != two.root)
        let key = KeyStoreKey(service: "s", account: "a")
        try await one.olmKeyStore().save(Data([1]), for: key)
        try await one.identityKeyStore().save(Data([2]), for: key)
        #expect(try await two.olmKeyStore().load(key) == nil)
        #expect(try await two.identityKeyStore().load(key) == nil)
        #expect(try await one.olmKeyStore().load(key) == Data([1]))
    }

    @Test("Instance names sanitize to filesystem-safe segments")
    func sanitizes() {
        #expect(ClientInstanceDirectory.safe("@alice:x") == "_alice_x")
        #expect(ClientInstanceDirectory.safe("work laptop") == "work_laptop")
        #expect(ClientInstanceDirectory.safe("ephemeral-abc") == "ephemeral_abc")
    }

    @Test("Sub-stores root under the instance")
    func subpaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dir = ClientInstanceDirectory(root: root)
        #expect(dir.accountStore.fileURL ==
            root.appendingPathComponent("oidc_account.json"))
        let user = UserId(unchecked: "@alice:x")
        #expect(dir.cacheDirectory(for: user) ==
            root.appendingPathComponent("_alice_x", isDirectory: true))
    }

    @Test("Delete removes the whole tree, absent tree is fine")
    func delete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dir = ClientInstanceDirectory(root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("olm"), withIntermediateDirectories: true)
        try "x".write(
            to: root.appendingPathComponent("olm/f.key"),
            atomically: true, encoding: .utf8)
        try dir.delete()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try dir.delete()
    }

    @Test("Debug builds root under MatrixKit-Debug, never release data")
    func debugBoundary() throws {
        let base = try #require(OIDCAccountStore.defaultDirectory())
        #if DEBUG
        #expect(base.lastPathComponent == "Debug")
        #expect(base.deletingLastPathComponent().lastPathComponent == "MatrixKit")
        #else
        #expect(base.lastPathComponent == "MatrixKit")
        #endif
    }
}
