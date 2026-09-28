import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Minimal HTTP/1.1 server for the spec harness, over the NIO bits
/// already in the package graph (via async-http-client).
///
/// Deliberately small: `Content-Length` bodies only, `Connection: close`
/// on every response. The SDK client always sends `Content-Length` for
/// its JSON bodies, so chunked inbound never occurs in practice; a
/// chunked request fails loudly instead of being silently misparsed.
final class HarnessServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private let router: @Sendable (HarnessRequest) async -> HarnessResponse

    init(router: @escaping @Sendable (HarnessRequest) async -> HarnessResponse) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.router = router
    }

    /// Bind 127.0.0.1 on an ephemeral port. Returns the bound port.
    /// Must be called once; `stop()` tears everything down.
    func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [router] channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HarnessHTTPHandler(router: router))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        guard let port = channel.localAddress?.port else {
            throw HarnessServerError.noPort
        }
        return port
    }

    func stop() async {
        do {
            try await channel?.close().get()
        } catch {}
        channel = nil
        do {
            try await group.shutdownGracefully()
        } catch {}
    }
}

enum HarnessServerError: Error {
    case noPort
}

/// Accumulates one request's head + body parts, dispatches to the
/// router on `.end`, and writes the response back on the channel.
/// EventLoop-confined by NIO (all callbacks run on the channel's loop).
private final class HarnessHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private let router: @Sendable (HarnessRequest) async -> HarnessResponse

    init(router: @escaping @Sendable (HarnessRequest) async -> HarnessResponse) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            body?.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let request = HarnessRequest(
                method: head.method.rawValue,
                path: HarnessHTTPHandler.path(of: head.uri),
                query: HarnessHTTPHandler.query(of: head.uri),
                headers: HarnessHTTPHandler.headers(of: head.headers),
                body: Data(body?.readableBytesView ?? .init())
            )
            self.head = nil
            self.body = nil
            let router = router
            let channel = context.channel
            Task {
                let response = await router(request)
                await HarnessHTTPHandler.write(response, on: channel)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Parsing

    private static func path(of uri: String) -> String {
        if let index = uri.firstIndex(of: "?") {
            return String(uri[..<index])
        }
        return uri
    }

    private static func query(of uri: String) -> [String: String] {
        guard let index = uri.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in uri[uri.index(after: index)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            out[key] = value
        }
        return out
    }

    private static func headers(of headers: HTTPHeaders) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(headers.count)
        for (name, value) in headers {
            out[name.lowercased()] = value
        }
        return out
    }

    // MARK: - Writing

    private static func write(_ response: HarnessResponse, on channel: any Channel) async {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.headers["Content-Type"] ?? "application/json")
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers)
        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        do {
            _ = try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            if response.body.count > 0 {
                _ = try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
            }
            _ = try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        } catch {}
        do {
            _ = try await channel.close().get()
        } catch {}
    }
}
