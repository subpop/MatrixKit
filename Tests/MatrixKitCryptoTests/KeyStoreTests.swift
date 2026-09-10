import Foundation
import Testing

@testable import MatrixKitCrypto

@Suite("KeyStore")
struct KeyStoreTests {
    private func key(
        _ account: String, service: String = "test-service"
    ) -> KeyStoreKey {
        KeyStoreKey(service: service, account: account)
    }

    @Test("Save, load, overwrite, delete round-trip")
    func roundTrip() async throws {
        let store = InMemoryKeyStore()
        let k = key("device-key")
        #expect(try await store.load(k) == nil)
        try await store.save(Data("secret-1".utf8), for: k)
        #expect(try await store.load(k) == Data("secret-1".utf8))
        try await store.save(Data("secret-2".utf8), for: k)
        #expect(try await store.load(k) == Data("secret-2".utf8))
        try await store.delete(k)
        #expect(try await store.load(k) == nil)
        // Deleting an absent key is not an error.
        try await store.delete(k)
    }

    @Test("Keys are isolated by service and account")
    func isolation() async throws {
        let store = InMemoryKeyStore()
        try await store.save(Data("a".utf8), for: key("k"))
        try await store.save(
            Data("b".utf8), for: key("k", service: "other-service"))
        try await store.save(Data("c".utf8), for: key("other"))
        #expect(try await store.load(key("k")) == Data("a".utf8))
        #expect(
            try await store.load(key("k", service: "other-service"))
                == Data("b".utf8))
        #expect(try await store.load(key("other")) == Data("c".utf8))
        #expect(try await store.keys.count == 3)
        try await store.delete(key("k"))
        #expect(try await store.keys.count == 2)
    }

    @Test("Binary key material survives intact")
    func binaryData() async throws {
        let store = InMemoryKeyStore()
        let bytes = Data((0..<256).map { UInt8($0) })
        try await store.save(bytes, for: key("raw"))
        #expect(try await store.load(key("raw")) == bytes)
    }
}

@Suite("FileKeyStore")
struct FileKeyStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func key(
        _ account: String, service: String = "test-service"
    ) -> KeyStoreKey {
        KeyStoreKey(service: service, account: account)
    }

    @Test("Save, load, overwrite, delete round-trip")
    func roundTrip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyStore(directory: dir)
        let k = key("@user:x")
        #expect(try await store.load(k) == nil)
        try await store.save(Data("secret-1".utf8), for: k)
        #expect(try await store.load(k) == Data("secret-1".utf8))
        try await store.save(Data("secret-2".utf8), for: k)
        #expect(try await store.load(k) == Data("secret-2".utf8))
        try await store.delete(k)
        #expect(try await store.load(k) == nil)
        // Deleting an absent key is not an error.
        try await store.delete(k)
    }

    @Test("Secrets persist across store instances")
    func persistsAcrossInstances() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileKeyStore(directory: dir)
        let k = key("device-key")
        try await writer.save(Data("opaque-bytes".utf8), for: k)
        let reader = FileKeyStore(directory: dir)
        #expect(try await reader.load(k) == Data("opaque-bytes".utf8))
    }

    @Test("Files are owner-only and raw bytes survive intact")
    func permissionsAndBinary() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileKeyStore(directory: dir)
        let bytes = Data((0..<256).map { UInt8($0) })
        try await store.save(bytes, for: key("raw"))
        #expect(try await store.load(key("raw")) == bytes)
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let mode = try FileManager.default.attributesOfItem(
            atPath: files[0].path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
