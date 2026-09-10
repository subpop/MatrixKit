import Foundation

/// Ephemeral dictionary-backed `KeyStore` for tests and transient sessions.
///
/// Holds secrets in memory only and never throws. Anything that must
/// survive process restart belongs in a caller-provided persistent store.
public actor InMemoryKeyStore: KeyStore {
    private var storage: [KeyStoreKey: Data] = [:]

    public init() {}

    /// Snapshot of every stored key (debugging/tests).
    public var keys: [KeyStoreKey] { Array(storage.keys) }

    public func save(_ data: Data, for key: KeyStoreKey) async throws {
        storage[key] = data
    }

    public func load(_ key: KeyStoreKey) async throws -> Data? {
        storage[key]
    }

    public func delete(_ key: KeyStoreKey) async throws {
        storage.removeValue(forKey: key)
    }
}
