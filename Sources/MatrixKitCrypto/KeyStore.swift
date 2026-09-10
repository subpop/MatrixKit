import Foundation

/// Composite key for a stored secret, mirroring the keychain's
/// (`service`, `account`) identity so a caller-backed `KeyStore` can map
/// straight onto `kSecAttrService` / `kSecAttrAccount`.
public struct KeyStoreKey: Hashable, Sendable, Codable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

/// Caller-implemented secret storage (device keys, one-time keys, session
/// blobs). Methods are `async` because real backends (Keychain Services'
/// `SecItem*` IPC) block; errors are untyped so each implementation defines
/// its own error type.
///
/// The calling app provides the concrete store (e.g. a Keychain-backed
/// store with proper entitlements); `MatrixKitCrypto` ships the ephemeral
/// `InMemoryKeyStore` for tests and transient use plus the file-backed
/// `FileKeyStore` for simple on-disk persistence.
public protocol KeyStore: Sendable {
    /// Insert or replace the secret stored under `key`.
    func save(_ data: Data, for key: KeyStoreKey) async throws
    /// The secret stored under `key`, or nil when absent.
    func load(_ key: KeyStoreKey) async throws -> Data?
    /// Remove any secret stored under `key`. Absent keys are not an error.
    func delete(_ key: KeyStoreKey) async throws
}
