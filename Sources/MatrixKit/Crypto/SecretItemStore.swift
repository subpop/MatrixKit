import Foundation
import MatrixKitCrypto
import Security

/// Synchronous small-secret storage (service + account addressed, like
/// the keychain's `kSecAttrService` / `kSecAttrAccount` identity).
/// Backs `CrossSigningStore` and `DeviceIdentityStore` so private key
/// material rests in the Keychain instead of plaintext JSON on disk.
///
/// Methods are synchronous: callers hold only a few small items and the
/// `SecItem*` calls below return inline. Test fakes (e.g. an in-memory
/// dictionary) keep file and keychain I/O out of unit tests.
public protocol SecretItemStore: Sendable {
    /// Insert or replace the item stored under (`service`, `account`).
    func save(_ data: Data, service: String, account: String) throws
    /// The item stored under (`service`, `account`), or nil when absent.
    func load(service: String, account: String) -> Data?
    /// Remove any item stored under (`service`, `account`).
    /// Absent items are not an error.
    func delete(service: String, account: String) throws
}

/// Keychain-backed `SecretItemStore`: generic-password items in the
/// data-protection keychain, readable after first unlock and never
/// migrated to another device or backup. No access group is set, so
/// items live in the host app's own keychain partition.
public struct KeychainSecretStore: SecretItemStore, Sendable {
    public init() {}

    private static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Identity of the item, without keychain-selection attributes, so
    /// it matches items written by earlier versions.
    private func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func query(service: String, account: String) -> [String: Any] {
        var query = identity(service: service, account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private func read(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    /// Adds or updates the item and reports whether a new item was added.
    @discardableResult
    private func store(_ data: Data, service: String, account: String) throws -> Bool {
        let query = query(service: service, account: account)
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        var added = false
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = Self.accessible
            status = SecItemAdd(add as CFDictionary, nil)
            added = status == errSecSuccess
        } else if status == errSecSuccess {
            status = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: Self.accessible,
                ] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw SecretItemStoreError.keychain(status)
        }
        return added
    }

    public func save(_ data: Data, service: String, account: String) throws {
        try store(data, service: service, account: account)
    }

    /// Loads the item, moving one written by an earlier version (outside
    /// the data-protection keychain, or with a syncable accessibility
    /// class) into the current form.
    public func load(service: String, account: String) -> Data? {
        if let data = read(query(service: service, account: account)) {
            return data
        }
        guard let legacy = read(identity(service: service, account: account))
        else { return nil }
        // Only a newly added item proves the legacy one lives elsewhere;
        // otherwise the store updated it in place and deleting the
        // legacy query would remove the migrated item.
        if (try? store(legacy, service: service, account: account)) == true {
            SecItemDelete(identity(service: service, account: account) as CFDictionary)
            if read(query(service: service, account: account)) == nil {
                try? store(legacy, service: service, account: account)
            }
        }
        return legacy
    }

    public func delete(service: String, account: String) throws {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        let status = SecItemDelete(identity(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretItemStoreError.keychain(status)
        }
    }
}

/// Keychain failures from `KeychainSecretStore`.
public enum SecretItemStoreError: Error, Sendable {
    /// A `SecItem*` call returned a non-success `OSStatus`.
    case keychain(OSStatus)
}

/// `KeyStore` adapter over `KeychainSecretStore`: the default backend
/// for `CrossSigningStore` and `DeviceIdentityStore` when the app
/// injects no `KeyStore` of its own. Lets the stores speak a single
/// protocol while standalone (non-app) use keeps working.
struct KeychainBackedKeyStore: KeyStore, Sendable {
    private let items = KeychainSecretStore()

    func save(_ data: Data, for key: KeyStoreKey) async throws {
        try items.save(data, service: key.service, account: key.account)
    }

    func load(_ key: KeyStoreKey) async throws -> Data? {
        items.load(service: key.service, account: key.account)
    }

    func delete(_ key: KeyStoreKey) async throws {
        try items.delete(service: key.service, account: key.account)
    }
}
