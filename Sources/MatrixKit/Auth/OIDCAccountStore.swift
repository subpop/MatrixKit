import Foundation

/// File-based OIDC session persistence: single `oidc_account.json` with
/// 0600 permissions. A CLI helper for zero-interaction restore — apps
/// should prefer the Keychain and `MatrixClient.restore` directly.
public struct OIDCAccountStore: Sendable {
    /// File written by `save`.
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("oidc_account.json")
    }

    /// `<caches>/MatrixKit/`, shared by all users (the account itself
    /// records which user it belongs to). Nil when unavailable.
    public static func defaultDirectory() -> URL? {
        guard
            let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return caches.appendingPathComponent("MatrixKit", isDirectory: true)
    }

    /// Atomically write the account with owner-only permissions.
    public func save(_ account: OIDCAccount) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(account)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    /// Read the account, or nil when absent or unreadable.
    public func load() -> OIDCAccount? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(OIDCAccount.self, from: data)
    }

    /// Delete the saved account (e.g. on explicit logout-all).
    public func clear() throws {
        try FileManager.default.removeItem(at: fileURL)
    }
}
