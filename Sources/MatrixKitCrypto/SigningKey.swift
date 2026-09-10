import Crypto
import Foundation

/// An Ed25519 signing keypair (Megolm session keys, device keys,
/// cross-signing keys).
///
/// Also used by `MatrixKit` for device and cross-signing keys, replacing
/// the former duplicate `Ed25519KeyPair` there.
///
/// The private half is held in memory only; callers persist
/// `privateKeyBytes` (e.g. via a `KeyStore`) themselves.
public struct SigningKey: Sendable {
    public let publicKeyBytes: Data
    private let privateKeyBytes: Data

    public init(publicKeyBytes: Data, privateKeyBytes: Data) {
        self.publicKeyBytes = publicKeyBytes
        self.privateKeyBytes = privateKeyBytes
    }

    /// Generate a fresh random keypair.
    public static func generate() -> SigningKey {
        let key = Curve25519.Signing.PrivateKey()
        return SigningKey(
            publicKeyBytes: Data(key.publicKey.rawRepresentation),
            privateKeyBytes: Data(key.rawRepresentation)
        )
    }

    /// Restore from stored private key bytes (32 bytes).
    public static func restore(
        privateKeyBytes: Data
    ) throws(CryptoError) -> SigningKey {
        do {
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyBytes)
            return SigningKey(
                publicKeyBytes: Data(key.publicKey.rawRepresentation),
                privateKeyBytes: privateKeyBytes
            )
        } catch {
            throw .invalidKey(
                "Invalid Ed25519 private key: \(error.localizedDescription)")
        }
    }

    /// Sign a message. Returns the raw 64-byte signature.
    public func sign(_ message: Data) throws(CryptoError) -> Data {
        do {
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyBytes)
            return Data(try key.signature(for: message))
        } catch let error as CryptoError {
            throw error
        } catch {
            throw .encryptionFailed(
                "Ed25519 signing failed: \(error.localizedDescription)")
        }
    }

    /// Verify a raw 64-byte signature against a raw 32-byte public key.
    public static func verify(
        signature: Data, for message: Data, publicKey: Data
    ) -> Bool {
        do {
            let key = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: message)
        } catch {
            return false
        }
    }

    /// Unpadded-base64 public key (Megolm session identifier).
    public var publicKeyBase64: String {
        Primitives.base64UnpaddedEncode(publicKeyBytes)
    }

    /// Unpadded-base64 private key for backup. Handle as a secret.
    public var privateKeyBase64: String {
        Primitives.base64UnpaddedEncode(privateKeyBytes)
    }
}
