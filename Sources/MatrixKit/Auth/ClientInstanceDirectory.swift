import Foundation
import MatrixKitCrypto

/// On-disk root for one client instance: every persisted artifact of a
/// login session (account, device identity, Olm sessions, one-time-key
/// pool, snapshot cache) lives beneath it, so instances never share
/// state through the filesystem.
///
/// Sandboxed apps get isolation from the OS via their container;
/// unsandboxed CLIs (mx) get it by using a distinct instance directory
/// per process (`ephemeral-<uuid>`) or named session (`--instance`).
/// The debug/release split from `OIDCAccountStore.defaultDirectory()`
/// is the *parent* of every instance root, so debug builds can never
/// touch release data.
public struct ClientInstanceDirectory: Sendable {
    /// Instance tree root. Layout beneath it:
    /// `oidc_account.json`, `olm/` (sessions + OTK pool),
    /// `identities/` (device backups), `<safe-user>/store.sqlite` and
    /// `<safe-user>/store.swiftdata` (snapshot caches).
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<base>/<sanitized instance>/`, or nil when no base directory
    /// is available.
    public static func `default`(instance: String) -> ClientInstanceDirectory? {
        guard let base = OIDCAccountStore.defaultDirectory() else {
            return nil
        }
        return ClientInstanceDirectory(
            root: base.appendingPathComponent(
                safe(instance), isDirectory: true))
    }

    /// Filesystem-safe segment: non-alphanumerics become `_`.
    public static func safe(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
    }

    /// `oidc_account.json` backing store for this instance.
    public var accountStore: OIDCAccountStore {
        OIDCAccountStore(directory: root)
    }

    /// Keystore for this instance's Olm sessions + one-time-key pool
    /// (entries keyed per user+device inside).
    public func olmKeyStore() -> FileKeyStore {
        FileKeyStore(directory: root.appendingPathComponent(
            "olm", isDirectory: true))
    }

    /// Keystore for this instance's device identity backups (entries
    /// keyed per user+device inside).
    public func identityKeyStore() -> FileKeyStore {
        FileKeyStore(directory: root.appendingPathComponent(
            "identities", isDirectory: true))
    }

    /// Snapshot cache directory for a user.
    public func cacheDirectory(for userId: UserId) -> URL {
        root.appendingPathComponent(
            Self.safe(userId.value), isDirectory: true)
    }

    /// Remove the whole instance tree (ephemeral teardown). An absent
    /// tree is not an error.
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        try FileManager.default.removeItem(at: root)
    }
}
