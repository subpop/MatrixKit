import Foundation
import MatrixKitCrypto

/// Media upload/download/thumbnail. Downloads prefer the authenticated
/// media API (`/_matrix/client/v1/media/...`), falling back to the legacy
/// unauthenticated endpoints (`/_matrix/media/v3/...`).
public actor MediaClient {
    private let transport: MatrixTransport
    private let session: Session

    public init(transport: MatrixTransport, session: Session) {
        self.transport = transport
        self.session = session
    }

    private func token() async throws(MatrixError) -> String {
        let token = await session.accessToken
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    // MARK: - Upload

    /// Upload bytes (`POST /upload?filename=`). Returns the `mxc://` URI.
    public func upload(
        _ data: Data, mimeType: String, filename: String? = nil
    ) async throws(MatrixError) -> MXCURI {
        var query: [String: String]? = nil
        if let filename { query = ["filename": filename] }
        let (_, body) = try await transport.sendBytes(
            .post, path: "/_matrix/media/v3/upload",
            query: query, bytes: data, contentType: mimeType,
            accessToken: try await token()
        )
        let response: UploadResponse
        do {
            response = try JSONDecoder().decode(UploadResponse.self, from: body)
        } catch {
            throw .decodingError("upload: \(error.localizedDescription)")
        }
        return try MXCURI(response.contentUri)
    }

    // MARK: - Download

    /// Download media bytes, preferring the authenticated media API
    /// (`GET /_matrix/client/v1/media/download/...`) and falling back to
    /// the legacy endpoint on 404 (older homeservers).
    public func download(_ uri: MXCURI, timeoutSeconds: Int = 60) async throws(MatrixError) -> Data {
        guard let (server, mediaId) = uri.components else {
            throw .invalidIdentifier("Malformed MXC URI: \(uri)")
        }
        let encoded = "\(server.pathSegmentEncoded)/\(mediaId.pathSegmentEncoded)"
        let accessToken = try await token()
        var (status, data) = try await transport.sendBytes(
            .get,
            path: "/_matrix/client/v1/media/download/\(encoded)",
            bytes: Data(), contentType: "application/octet-stream",
            accessToken: accessToken,
            timeoutSeconds: timeoutSeconds
        )
        if status == 404 {
            (status, data) = try await transport.sendBytes(
                .get,
                path: "/_matrix/media/v3/download/\(encoded)",
                bytes: Data(), contentType: "application/octet-stream",
                accessToken: accessToken,
                timeoutSeconds: timeoutSeconds
            )
        }
        guard (200..<300).contains(status) else {
            throw MatrixError.unexpectedStatus(status, body: nil)
        }
        return data
    }

    /// Fetch a thumbnail, preferring the authenticated media API
    /// (`GET /_matrix/client/v1/media/thumbnail/...`) and falling back to
    /// the legacy endpoint on 404 (older homeservers).
    public func thumbnail(
        _ uri: MXCURI, width: Int, height: Int, method: ThumbnailMethod = .scale
    ) async throws(MatrixError) -> Data {
        guard let (server, mediaId) = uri.components else {
            throw .invalidIdentifier("Malformed MXC URI: \(uri)")
        }
        let encoded = "\(server.pathSegmentEncoded)/\(mediaId.pathSegmentEncoded)"
        let query = [
            "width": "\(width)",
            "height": "\(height)",
            "method": method.rawValue,
        ]
        let accessToken = try await token()
        var (status, data) = try await transport.sendBytes(
            .get,
            path: "/_matrix/client/v1/media/thumbnail/\(encoded)",
            query: query,
            bytes: Data(), contentType: "application/octet-stream",
            accessToken: accessToken
        )
        if status == 404 {
            (status, data) = try await transport.sendBytes(
                .get,
                path: "/_matrix/media/v3/thumbnail/\(encoded)",
                query: query,
                bytes: Data(), contentType: "application/octet-stream",
                accessToken: accessToken
            )
        }
        guard (200..<300).contains(status) else {
            throw MatrixError.unexpectedStatus(status, body: nil)
        }
        return data
    }

    /// Resolve an `mxc://` URI to an authenticated HTTP download URL.
    /// (Useful for `AsyncImage` and friends; caller attaches the token.)
    public func httpURL(for uri: MXCURI) async -> URL? {
        guard let (server, mediaId) = uri.components else { return nil }
        let homeserver = session.homeserver
        // String concatenation (not `appendingPathComponent`, which would
        // re-encode the pre-encoded segments — see `pathSegmentEncoded`).
        var root = homeserver.absoluteString
        if root.hasSuffix("/") { root.removeLast() }
        return URL(
            string:
                root + "/_matrix/media/v3/download/\(server.pathSegmentEncoded)/\(mediaId.pathSegmentEncoded)"
        )
    }

    // MARK: - Encrypted files

    /// Download an encrypted file and decrypt it: verifies the SHA-256
    /// hash, then AES-CTR-decrypts with the file key.
    public func downloadDecrypted(
        _ file: EncryptedFile, timeoutSeconds: Int = 60
    ) async throws(MatrixError) -> Data {
        guard let uri = try? MXCURI(file.url) else {
            throw .invalidIdentifier("Malformed encrypted file URL: \(file.url)")
        }
        return try Self.decryptFile(
            try await download(uri, timeoutSeconds: timeoutSeconds), file: file)
    }

    /// Verify the hash and decrypt file bytes (pure).
    public static func decryptFile(
        _ data: Data, file: EncryptedFile
    ) throws(MatrixError) -> Data {
        guard
            let key = Primitives.base64URLDecode(file.key.key), key.count == 32,
            let iv = Primitives.base64URLDecode(file.iv), iv.count == 16
        else {
            throw .encodingError("Encrypted file has a malformed key or IV")
        }
        if let expectedHash = file.hashes["sha256"],
            let expected = Primitives.base64URLDecode(expectedHash),
            !Primitives.constantTimeEqual(Primitives.sha256(data), expected)
        {
            throw .encodingError("Encrypted file hash mismatch")
        }
        do {
            return try AESCTR.decrypt(key: key, iv: iv, ciphertext: data)
        } catch {
            throw .encodingError("Cannot decrypt file: \(error)")
        }
    }

    /// Encrypt bytes for upload: returns the ciphertext plus a file dict
    /// without URL (the caller uploads the ciphertext, then sets `url`).
    public static func encryptFile(_ data: Data) throws(MatrixError) -> (
        ciphertext: Data, key: AttachmentKey, iv: String, hash: String
    ) {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        var ivBytes = [UInt8](repeating: 0, count: 16)
        for index in keyBytes.indices { keyBytes[index] = UInt8.random(in: 0...255) }
        for index in ivBytes.indices { ivBytes[index] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes)
        let iv = Data(ivBytes)
        let ciphertext: Data
        do {
            ciphertext = try AESCTR.encrypt(key: key, iv: iv, plaintext: data)
        } catch {
            throw .encodingError("Cannot encrypt file: \(error)")
        }
        return (
            ciphertext,
            AttachmentKey(key: Primitives.base64URLEncode(key)),
            Primitives.base64URLEncode(iv),
            Primitives.base64URLEncode(Primitives.sha256(ciphertext)))
    }

    /// Encrypt and upload bytes, returning the completed file dict.
    public func uploadEncrypted(
        _ data: Data, mimeType: String, filename: String? = nil
    ) async throws(MatrixError) -> EncryptedFile {
        let encrypted = try Self.encryptFile(data)
        let mxc = try await upload(
            encrypted.ciphertext, mimeType: "application/octet-stream",
            filename: filename)
        return EncryptedFile(
            url: mxc.value,
            key: encrypted.key,
            iv: encrypted.iv,
            hashes: ["sha256": encrypted.hash])
    }
}

/// Thumbnail scaling method.
public enum ThumbnailMethod: String, Hashable, Sendable {
    case crop
    case scale
}

/// `POST /upload` response body.
public struct UploadResponse: Hashable, Sendable, Codable {
    /// The uploaded content's `mxc://` URI.
    public var contentUri: String

    public init(contentUri: String) {
        self.contentUri = contentUri
    }

    private enum CodingKeys: String, CodingKey {
        case contentUri = "content_uri"
    }
}
