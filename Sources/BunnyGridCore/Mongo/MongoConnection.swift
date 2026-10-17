import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// A server error reply (`ok: 0`), with its code and name (`Unauthorized`, `QueryPlanKilled`…).
public struct MongoServerError: LocalizedError, Sendable, Equatable {
    public var code: Int
    public var codeName: String
    public var message: String

    public var errorDescription: String? {
        codeName.isEmpty ? message : "\(message) (\(codeName))"
    }

    /// `Interrupted`, `MaxTimeMSExpired` or `CursorKilled`: the operation was stopped by killOp.
    public var isInterruption: Bool { [11601, 50, 237].contains(code) }

    /// The server stopped being (or never was) the primary: `NotWritablePrimary`, `NotPrimaryNoSecondaryOk`,
    /// `NotPrimaryOrSecondary`, `PrimarySteppedDown`, `InterruptedDueToReplStateChange`, `ShutdownInProgress`…
    /// The command wasn't applied, so it can run again on the new primary.
    public var isNotPrimary: Bool { [10107, 13435, 13436, 189, 11602, 91, 11600].contains(code) || message.hasPrefix("not master") }
}

/// OP_MSG framing (opcode 2013): header, flag bits, one section of kind 0 holding the command document.
enum MongoWire {
    static let opMsg: Int32 = 2013
    static let opCompressed: Int32 = 2012
    static let maxMessageSize = 48_000_000

    static func encode(requestID: Int32, command: BSONDocument) -> [UInt8] {
        let body = BSONEncoder.encode(command)
        var out: [UInt8] = []
        out.reserveCapacity(body.count + 21)
        BSONEncoder.appendLE(Int32(16 + 4 + 1 + body.count), to: &out)
        BSONEncoder.appendLE(requestID, to: &out)
        BSONEncoder.appendLE(Int32(0), to: &out)
        BSONEncoder.appendLE(opMsg, to: &out)
        BSONEncoder.appendLE(UInt32(0), to: &out)
        out.append(0)
        out.append(contentsOf: body)
        return out
    }

    /// The reply's `responseTo` and its body document (kind 0 section; kind 1 sections are folded in as arrays).
    static func decode(_ bytes: [UInt8]) throws -> (responseTo: Int32, document: BSONDocument) {
        var reader = BSONReader(bytes: bytes)
        _ = try reader.readInteger(Int32.self)
        _ = try reader.readInteger(Int32.self)
        let responseTo = try reader.readInteger(Int32.self)
        let opcode = try reader.readInteger(Int32.self)
        guard opcode == opMsg else { throw DatabaseError.queryFailed("Unexpected MongoDB reply opcode \(opcode).") }
        let flags = try reader.readInteger(UInt32.self)
        let end = bytes.count - (flags & 1 != 0 ? 4 : 0)
        var body = BSONDocument()
        while reader.position < end {
            let kind = try reader.readBytes(1)[0]
            if kind == 0 {
                body = try reader.readDocument()
            } else {
                let start = reader.position
                let size = Int(try reader.readInteger(Int32.self))
                let identifier = try reader.readCString()
                var documents: [BSON] = []
                while reader.position < start + size { documents.append(.document(try reader.readDocument())) }
                body[identifier] = .array(documents)
            }
        }
        return (responseTo, body)
    }
}

/// Splits the byte stream into whole messages using the length prefix.
private struct MongoFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = [UInt8]

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: Int32.self) else { return .needMoreData }
        guard length >= 16, length <= MongoWire.maxMessageSize else { throw DatabaseError.queryFailed("Invalid MongoDB message length \(length).") }
        guard buffer.readableBytes >= Int(length), let bytes = buffer.readBytes(length: Int(length)) else { return .needMoreData }
        context.fireChannelRead(Self.wrapInboundOut(bytes))
        return .continue
    }
}

/// Matches replies to requests by `responseTo`.
private final class MongoReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = [UInt8]
    private let lock = NIOLock()
    private var pending: [Int32: EventLoopPromise<BSONDocument>] = [:]

    func register(_ id: Int32, _ promise: EventLoopPromise<BSONDocument>) {
        lock.withLock { pending[id] = promise }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        do {
            let (responseTo, document) = try MongoWire.decode(bytes)
            let promise = lock.withLock { pending.removeValue(forKey: responseTo) }
            promise?.succeed(document)
        } catch {
            failAll(error)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(DatabaseError.connectionFailed("The MongoDB server closed the connection."))
        context.fireChannelInactive()
    }

    func failAll(_ error: any Error) {
        let all = lock.withLock { () -> [EventLoopPromise<BSONDocument>] in
            defer { pending = [:] }
            return Array(pending.values)
        }
        for promise in all { promise.fail(error) }
    }
}

/// One socket to a mongod / mongos speaking OP_MSG.
public final class MongoConnection: Sendable {
    private let channel: any Channel
    private let handler: MongoReplyHandler
    private let nextID = NIOLockedValueBox<Int32>(0)
    /// The `hello` reply from the handshake.
    public let hello: BSONDocument

    private init(channel: any Channel, handler: MongoReplyHandler, hello: BSONDocument) {
        self.channel = channel
        self.handler = handler
        self.hello = hello
    }

    public var maxWireVersion: Int { hello["maxWireVersion"]?.intValue ?? 0 }
    public var isWritablePrimary: Bool { hello["isWritablePrimary"]?.boolValue ?? hello["ismaster"]?.boolValue ?? false }
    public var isMongos: Bool { hello["msg"]?.stringValue == "isdbgrid" }

    /// Opens the socket (TLS when `tls` is set), sends `hello` and checks the wire version (MongoDB 3.6+ for OP_MSG).
    static func open(address: ConnectionEndpoint.Address, tls: TLSConfiguration?, serverName: String?,
                     helloExtras: BSONDocument = BSONDocument()) async throws -> MongoConnection {
        let handler = MongoReplyHandler()
        let sslContext = try tls.map { try NIOSSLContext(configuration: $0) }
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: sslContext, serverHostname: serverName))
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(MongoFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        let channel: any Channel
        switch address {
        case .tcp(let host, let port): channel = try await bootstrap.connect(host: host, port: port).get()
        case .unixSocket(let path): channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
        }
        var hello: BSONDocument = [
            "hello": .int32(1),
            "client": .document([
                "application": .document(["name": .string("BunnyGrid")]),
                "driver": .document(["name": .string("BunnyGrid"), "version": .string("1.0")]),
                "os": .document(["type": .string("Darwin"), "name": .string("macOS")]),
            ]),
        ]
        for element in helloExtras { hello[element.key] = element.value }
        hello["$db"] = .string("admin")
        let probe = MongoConnection(channel: channel, handler: handler, hello: BSONDocument())
        let reply: BSONDocument
        do {
            reply = try await probe.send(hello)
        } catch {
            try? await channel.close()
            throw error
        }
        let connection = MongoConnection(channel: channel, handler: handler, hello: reply)
        if connection.maxWireVersion < 6 {
            await connection.close()
            throw DatabaseError.connectionFailed("This MongoDB server is too old (wire version \(connection.maxWireVersion)); BunnyGrid needs MongoDB 3.6 or later.")
        }
        return connection
    }

    /// Sends one command (with `$db` set) and returns the raw reply, without checking `ok`.
    func send(_ command: BSONDocument) async throws -> BSONDocument {
        let id = nextID.withLockedValue { value -> Int32 in
            value = value == Int32.max ? 1 : value + 1
            return value
        }
        let promise = channel.eventLoop.makePromise(of: BSONDocument.self)
        handler.register(id, promise)
        let bytes = MongoWire.encode(requestID: id, command: command)
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
        return try await promise.futureResult.get()
    }

    /// Runs `command` in `database` and throws the server's error when `ok` isn't 1.
    public func run(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        var command = command
        command["$db"] = .string(database)
        let reply = try await send(command)
        if !reply.isOK {
            throw MongoServerError(code: reply["code"]?.intValue ?? 0, codeName: reply["codeName"]?.stringValue ?? "",
                                   message: reply["errmsg"]?.stringValue ?? "Command failed")
        }
        // Write errors come back with ok: 1.
        if case .array(let errors)? = reply["writeErrors"], case .document(let first)? = errors.first {
            throw MongoServerError(code: first["code"]?.intValue ?? 0, codeName: first["codeName"]?.stringValue ?? "",
                                   message: first["errmsg"]?.stringValue ?? "Write failed")
        }
        if case .document(let concern)? = reply["writeConcernError"] {
            throw MongoServerError(code: concern["code"]?.intValue ?? 0, codeName: concern["codeName"]?.stringValue ?? "",
                                   message: concern["errmsg"]?.stringValue ?? "Write concern failed")
        }
        return reply
    }

    public var isActive: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }
}
