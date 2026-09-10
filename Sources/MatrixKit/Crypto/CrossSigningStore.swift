import Foundation
import MatrixKitCrypto

/// Persisted cross-signing identity: unpadded-base64 private halves. Secret.
///
/// Written when secrets arrive (via `m.secret.send` or manual import) so a
/// verified device stays verified across restarts without re-running the
/// UIAA cross-signing reset dance.
public struct CrossSigningBackup: Hashable, Sendable, Codable {
    public var masterPrivateKey: String
    public var selfSigningPrivateKey: String
    public var userSigningPrivateKey: String

    public init(
        masterPrivateKey: String,
        selfSigningPrivateKey: String,
        userSigningPrivateKey: String
    ) {
        self.masterPrivateKey = masterPrivateKey
        self.selfSigningPrivateKey = selfSigningPrivateKey
        self.userSigningPrivateKey = userSigningPrivateKey
    }
}

/// Cross-signing persistence over the app-provided `KeyStore`: one
/// entry per user. Keyed by user, not device — the cross-signing
/// identity is shared across all of a user's devices.
///
/// The service name is intentionally relative: apps namespace their
/// items (e.g. with an app-ID service prefix and access group) in
/// their own `KeyStore`, so two MatrixKit apps can never step on each
/// other's keys. With no injected store, `KeychainSecretStore` backs
/// reads and writes.
public struct CrossSigningStore: Sendable {
    /// Relative service for the per-user backup entry. Apps isolate
    /// their items via their own `KeyStore` naming.
    public static let service = "cross_signing"

    private let keystore: any KeyStore

    public init(keystore: (any KeyStore)? = nil) {
        self.keystore = keystore ?? KeychainBackedKeyStore()
    }

    private func key(for userId: UserId) -> KeyStoreKey {
        KeyStoreKey(service: Self.service, account: userId.value)
    }

    /// Write the backup (insert or replace).
    public func save(_ backup: CrossSigningBackup, userId: UserId) async throws {
        let data = try JSONEncoder().encode(backup)
        try await keystore.save(data, for: key(for: userId))
    }

    /// Read the backup, or nil when absent or unreadable.
    public func load(userId: UserId) async -> CrossSigningBackup? {
        guard let data = try? await keystore.load(key(for: userId)),
            let backup = try? JSONDecoder().decode(
                CrossSigningBackup.self, from: data)
        else { return nil }
        return backup
    }

    /// Delete the backup (e.g. on logout). Absent entries are not
    /// an error.
    public func delete(userId: UserId) async throws {
        try await keystore.delete(key(for: userId))
    }
}
