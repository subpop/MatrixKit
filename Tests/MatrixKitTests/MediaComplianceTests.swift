import Foundation
import Testing

import MatrixKitTesting
@testable import MatrixKit

/// Media compliance suite: upload/download round-trips, the v1→v3
/// fallback, thumbnails, and encrypted attachments.
///
/// Exercised registry endpoints: `POST /_matrix/media/v3/upload`,
/// `GET /_matrix/client/v1/media/{download,thumbnail}/{serverName}/{mediaId}`,
/// plus the legacy v3 fallbacks (registry overrides, documented).
@Suite("MediaCompliance")
struct MediaComplianceTests {
    @Test("Upload then download round-trips bytes")
    func uploadDownload() async throws {
        try await withHarness { harness in
            let (media, _, _) = await harness.mediaClient()
            let bytes = Data("pixels".utf8)
            let uri = try await media.upload(bytes, mimeType: "image/png", filename: "pic.png")
            #expect(uri.value.hasPrefix("mxc://test/m"))
            #expect(try await media.download(uri) == bytes)
            let uploads = await harness.requests.filter { $0.path == "/_matrix/media/v3/upload" }
            #expect(uploads.count == 1)
            #expect(uploads.first?.query["filename"] == "pic.png")
            #expect(uploads.first?.hadBearer == true)
        }
    }

    @Test("v1 404 falls back to legacy v3 download")
    func legacyFallback() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.seedMedia(id: "legacy", bytes: Data("old-bytes".utf8))
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/media/download/test/legacy",
                response: .matrixError(code: "M_NOT_FOUND", message: "gone", status: 404))
            let (media, _, _) = await harness.mediaClient()
            let downloaded = try await media.download(try MXCURI("mxc://test/legacy"))
            #expect(downloaded == Data("old-bytes".utf8))
        }
    }

    @Test("Thumbnails download bytes")
    func thumbnail() async throws {
        try await withHarness { harness in
            let world = await harness.world
            await world.seedMedia(id: "thumb", bytes: Data("thumb-bytes".utf8))
            let (media, _, _) = await harness.mediaClient()
            let thumb = try await media.thumbnail(try MXCURI("mxc://test/thumb"), width: 100, height: 100)
            #expect(thumb == Data("thumb-bytes".utf8))
        }
    }

    @Test("Missing media surfaces unexpected status")
    func missingMedia() async throws {
        try await withHarness { harness in
            // Both v1 and legacy v3 miss: the byte path returns raw
            // status with no parsed body.
            await harness.setOverride(
                method: "GET", path: "/_matrix/client/v1/media/download/test/ghost",
                response: .raw("gone", status: 404))
            await harness.setOverride(
                method: "GET", path: "/_matrix/media/v3/download/test/ghost",
                response: .raw("gone", status: 404))
            let (media, _, _) = await harness.mediaClient()
            await #expect(throws: MatrixError.unexpectedStatus(404, body: nil)) {
                try await media.download(try MXCURI("mxc://test/ghost"))
            }
        }
    }

    @Test("Encrypted upload then decrypted download round-trips")
    func encryptedRoundTrip() async throws {
        try await withHarness { harness in
            let (media, _, _) = await harness.mediaClient()
            let plaintext = Data("secret pixels".utf8)
            let file = try await media.uploadEncrypted(plaintext, mimeType: "image/png")
            #expect(file.url.hasPrefix("mxc://test/m"))
            #expect(try await media.downloadDecrypted(file) == plaintext)
        }
    }

    @Test("httpURL builds the v3 download URL without network")
    func httpURL() async throws {
        try await withHarness { harness in
            let (media, _, _) = await harness.mediaClient()
            let baseURL = await harness.baseURL
            let url = await media.httpURL(for: try MXCURI("mxc://test/m1"))
            #expect(url?.absoluteString == "\(baseURL.absoluteString)/_matrix/media/v3/download/test/m1")
        }
    }

    @Test("Media calls reject invalid sessions without network")
    func mediaGuards() async {
        let transport = MatrixTransport(homeserver: URL(string: "https://example.com")!)
        let session = Session(
            homeserver: URL(string: "https://example.com")!,
            userId: UserId(unchecked: "@a:b"),
            deviceId: DeviceId("D"),
            accessToken: "")
        let media = MediaClient(transport: transport, session: session)
        await #expect(throws: MatrixError.notAuthenticated) {
            try await media.upload(Data("x".utf8), mimeType: "image/png")
        }
        try? await transport.shutdown()
    }
}
