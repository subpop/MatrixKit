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

/// Keychain-backed `SecretItemStore`: generic-password items readable
/// after first unlock. No access group is set, so items live in the
/// host app's own keychain partition.
public struct KeychainSecretStore: SecretItemStore, Sendable {
    public init() {}

    public func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        } else if status == errSecSuccess {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw SecretItemStoreError.keychain(status)
        }
    }

    public func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        else { return nil }
        return item as? Data
    }

    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
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
