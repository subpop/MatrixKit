import Foundation

/// File-backed `KeyStore`: one 0600 file per (`service`, `account`)
/// pair, so secrets survive process restart (device keys, one-time
/// keys, Olm session blobs).
///
/// The caller picks the directory (mx uses
/// `<caches>/mx/`, shared with `DeviceIdentityStore`).
/// Filenames sanitize like `DeviceIdentityStore` (non-alphanumerics
/// become `_`); distinct pairs mapping to one filename would collide,
/// so keep `service` values short constants.
public actor FileKeyStore: KeyStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(_ key: KeyStoreKey) -> URL {
        func safe(_ value: String) -> String {
            value.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
            }.joined()
        }
        return directory.appendingPathComponent(
            "\(safe(key.service))_\(safe(key.account)).key")
    }

    /// Atomically write the secret with owner-only permissions,
    /// creating the directory on first use.
    public func save(_ data: Data, for key: KeyStoreKey) async throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = fileURL(key)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }

    /// Read the secret, or nil when absent or unreadable.
    public func load(_ key: KeyStoreKey) async throws -> Data? {
        guard let data = try? Data(contentsOf: fileURL(key)) else {
            return nil
        }
        return data
    }

    /// Remove the secret. Absent keys are not an error.
    public func delete(_ key: KeyStoreKey) async throws {
        try? FileManager.default.removeItem(at: fileURL(key))
    }
}
