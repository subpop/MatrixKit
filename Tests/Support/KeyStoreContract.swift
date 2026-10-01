import Foundation
import MatrixKitCrypto
import Testing

/// `KeyStore` contract: every backend must save, load, overwrite, and
/// delete, with absent deletes a no-op. Both shipped backends
/// (`InMemoryKeyStore`, `FileKeyStore`) run this instead of carrying
/// their own copy of the round-trip.
/// `KeyStore` decorator counting writes, for coalescing assertions.
/// Delegates to an `InMemoryKeyStore` so reads observe the writes.
public actor CountingKeyStore: KeyStore {
    private let inner = InMemoryKeyStore()
    public private(set) var saves = 0

    public init() {}

    public func save(_ data: Data, for key: KeyStoreKey) async throws {
        saves += 1
        try await inner.save(data, for: key)
    }

    public func load(_ key: KeyStoreKey) async throws -> Data? {
        try await inner.load(key)
    }

    public func delete(_ key: KeyStoreKey) async throws {
        try await inner.delete(key)
    }
}

public func checkKeyStoreRoundTrip(
    _ store: any KeyStore,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let key = KeyStoreKey(service: "test-service", account: "device-key")
    #expect(try await store.load(key) == nil, sourceLocation: sourceLocation)
    try await store.save(Data("secret-1".utf8), for: key)
    #expect(
        try await store.load(key) == Data("secret-1".utf8),
        sourceLocation: sourceLocation)
    try await store.save(Data("secret-2".utf8), for: key)
    #expect(
        try await store.load(key) == Data("secret-2".utf8),
        sourceLocation: sourceLocation)
    try await store.delete(key)
    #expect(try await store.load(key) == nil, sourceLocation: sourceLocation)
    // Deleting an absent key is not an error.
    try await store.delete(key)
}
