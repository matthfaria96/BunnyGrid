import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// One command sent down the pipeline with the promise its reply fulfills.
struct RedisRequest: Sendable {
    let bytes: [UInt8]
    let promise: EventLoopPromise<RESPValue>
}

/// Encodes requests and matches each reply to the oldest waiting promise (Redis answers in order).
/// RESP3 push messages are not replies and are dropped.
final class RedisChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = RedisRequest
    typealias OutboundOut = ByteBuffer

    private var decoder = RESPStreamDecoder()
    private var waiting: CircularBuffer<EventLoopPromise<RESPValue>> = []
    /// Streaming connections (Pub/Sub, MONITOR): every value goes here once `streaming` is on.
    let listener: (@Sendable (RESPValue) -> Void)?
    var streaming = false

    init(listener: (@Sendable (RESPValue) -> Void)? = nil) {
        self.listener = listener
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        waiting.append(request.promise)
        var buffer = context.channel.allocator.buffer(capacity: request.bytes.count)
        buffer.writeBytes(request.bytes)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { decoder.append(bytes) }
        do {
            while let value = try decoder.next() {
                if streaming, let listener {
                    listener(value)
                    waiting.popFirst()?.succeed(value)
                    continue
                }
                if case .push = value { continue }
                guard let promise = waiting.popFirst() else { continue }
                promise.succeed(value)
            }
        } catch {
            failAll(error)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(DatabaseError.connectionFailed("The Redis server closed the connection."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    private func failAll(_ error: any Error) {
        while let promise = waiting.popFirst() { promise.fail(error) }
    }
}

/// A raw RESP connection. Commands written in one `send` call go out back to back, so a SELECT and the
/// command after it can't be split by another caller.
final class RedisConnection: Sendable {
    let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
    }

    static func open(address: ConnectionEndpoint.Address, tls: TLSConfiguration?, serverName: String?,
                     listener: (@Sendable (RESPValue) -> Void)? = nil) async throws -> RedisConnection {
        let socketAddress: SocketAddress
        switch address {
        case .tcp(let host, let port): socketAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        case .unixSocket(let path): socketAddress = try SocketAddress(unixDomainSocketPath: path)
        }
        let sslContext = try tls.map { try NIOSSLContext(configuration: $0) }
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverName)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                    try channel.pipeline.syncOperations.addHandler(RedisChannelHandler(listener: listener))
                }
            }
        let channel = try await bootstrap.connect(to: socketAddress).get()
        return RedisConnection(channel: channel)
    }

    /// Queues every command on the channel without suspending, so callers on an actor keep their order
    /// (an async function here would hop off the actor first and let other calls write in between).
    func enqueue(_ commands: [[Data]]) -> [EventLoopFuture<RESPValue>] {
        var futures: [EventLoopFuture<RESPValue>] = []
        for command in commands {
            let promise = channel.eventLoop.makePromise(of: RESPValue.self)
            channel.write(RedisRequest(bytes: RESPCodec.encode(command: command), promise: promise), promise: nil)
            futures.append(promise.futureResult)
        }
        channel.flush()
        return futures
    }

    /// Writes every command, then waits for all replies in order.
    func send(_ commands: [[Data]]) async throws -> [RESPValue] {
        let futures = enqueue(commands)
        var replies: [RESPValue] = []
        for future in futures { replies.append(try await future.get()) }
        return replies
    }

    /// From now on every value read goes to the listener given to `open` (replies included).
    func startStreaming() async throws {
        try await channel.eventLoop.submit { [channel] in
            try channel.pipeline.syncOperations.handler(type: RedisChannelHandler.self).streaming = true
        }.get()
    }

    func close() async {
        try? await channel.close().get()
    }

    var isActive: Bool { channel.isActive }
}
