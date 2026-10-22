import Foundation
import MatrixKitCrypto

/// Key-backup private-key persistence over the app-provided `KeyStore`:
/// one entry per user, since the backup key belongs to the account and
/// is shared by all of its devices.
///
/// The service name is intentionally relative: apps namespace their
/// items (e.g. with an app-ID service prefix and access group) in
/// their own `KeyStore`, so two MatrixKit apps can never step on each
/// other's keys. With no injected store, `KeychainSecretStore` backs
/// reads and writes.
public struct BackupKeyStore: Sendable {
    /// Relative service for the per-user entry. Apps isolate their
    /// items via their own `KeyStore` naming.
    public static let service = "backup_key"

    private let keystore: any KeyStore

    public init(keystore: (any KeyStore)? = nil) {
        self.keystore = keystore ?? KeychainBackedKeyStore()
    }

    private func key(for userId: UserId) -> KeyStoreKey {
        KeyStoreKey(service: Self.service, account: userId.value)
    }

    /// Write the 32-byte backup private key (insert or replace).
    public func save(_ privateKey: Data, userId: UserId) async throws {
        try await keystore.save(privateKey, for: key(for: userId))
    }

    /// Read the backup private key, or nil when absent or unreadable.
    public func load(userId: UserId) async -> Data? {
        try? await keystore.load(key(for: userId))
    }

    /// Delete the backup key (e.g. on logout). Absent entries are not
    /// an error.
    public func delete(userId: UserId) async throws {
        try await keystore.delete(key(for: userId))
    }
}
