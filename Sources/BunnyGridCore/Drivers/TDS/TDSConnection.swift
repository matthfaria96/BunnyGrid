import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// One result set of a reply.
struct TDSResultSet: Sendable {
    var columns: [TDSColumn]
    var rows: [[CellValue]] = []
    var isTruncated = false
}

/// Everything a request returned.
struct TDSResponse: Sendable {
    var resultSets: [TDSResultSet] = []
    var affectedRows: Int?
    var messages: [TDSServerMessage] = []
    var sspi: [UInt8]?
}

/// A TDS 7.4 session over SwiftNIO: PRELOGIN, TLS (wrapped in PRELOGIN packets during the handshake, as
/// TDS 7.x requires), LOGIN7 with SQL Server authentication, then SQL batches and RPC calls, one at a time.
actor TDSConnection {
    struct Options: Sendable {
        var host: String
        var port: Int
        /// Name sent as SNI and checked against the certificate.
        var tlsServerName: String?
        var mode: TLSMode
        var tls: TLSConfiguration?
        var username: String
        var password: String
        var database: String
        var serverName: String
        var appName = "BunnyGrid"
        /// Windows Authentication with NTLMv2: `username` is `DOMAIN\user`.
        var windowsAuthentication = false
    }

    private let channel: any Channel
    private let inbox: TDSInbox
    private var raw = ByteBuffer()
    private(set) var packetSize = 4096
    private(set) var database = ""
    private(set) var transaction: UInt64 = 0
    private(set) var collation = TDSCollation.latin1General
    private(set) var serverProgram = ""
    private(set) var serverVersion = ""

    // Requests run one at a time.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requestRunning = false
    private var attentionSent = false

    private init(channel: any Channel, inbox: TDSInbox) {
        self.channel = channel
        self.inbox = inbox
    }

    static func connect(_ options: Options) async throws -> TDSConnection {
        let inbox = TDSInbox()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TDSInboxHandler(inbox: inbox))
                }
            }
            .connect(host: options.host, port: options.port).get()
        let connection = TDSConnection(channel: channel, inbox: inbox)
        // A server that stops answering during PRELOGIN, TLS or LOGIN7 closes the socket, failing the reads.
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(20)) {
            inbox.fail(TDSError.protocolViolation("timed out waiting for the server to log in"))
            channel.close(promise: nil)
        }
        do {
            try await connection.handshake(options)
            timeout.cancel()
        } catch {
            timeout.cancel()
            await connection.close()
            throw error
        }
        return connection
    }

    func close() async {
        try? await channel.close().get()
    }

    var isActive: Bool { channel.isActive }

    // MARK: - Login

    private func handshake(_ options: Options) async throws {
        let wanted: TDSEncryption = options.tls == nil ? .notSupported : .on
        try await send(.prelogin, TDSPrelogin.encode(encryption: wanted))
        let prelogin = try TDSPrelogin.decode(try await readMessage())
        switch (wanted, prelogin.encryption) {
        case (.notSupported, .required), (.notSupported, .on):
            throw TDSError.encryptionRequired
        case (.on, .notSupported):
            if options.mode.isEnforced { throw TDSError.encryptionUnsupported(options.mode) }
        case (.on, _):
            try await startTLS(options)
        default:
            break
        }
        var login = TDSLogin7(hostName: Host.current().localizedName ?? "localhost", userName: options.username,
                              password: options.password, appName: options.appName, serverName: options.serverName,
                              database: options.database)
        login.packetSize = 8192
        let ntlm = NTLMClient(account: options.username, password: options.password, workstation: Host.current().localizedName ?? "")
        if options.windowsAuthentication { login.sspi = ntlm.negotiate() }
        try await send(.login7, login.encode())
        var response = try await readResponse(maxRows: nil, isLogin: true)
        if options.windowsAuthentication, serverProgram.isEmpty, let token = response.sspi {
            let challenge = try NTLMClient.parseChallenge(token)
            var message = ByteBuffer()
            message.writeBytes(ntlm.authenticate(challenge))
            try await send(.sspi, message)
            response = try await readResponse(maxRows: nil, isLogin: true)
        }
        if serverProgram.isEmpty {
            throw TDSError.server(response.messages.first { $0.severity > 10 }?.text ?? "Login failed.", number: 18456)
        }
    }

    private func startTLS(_ options: Options) async throws {
        var configuration = options.tls ?? TLSConfiguration.makeClientConfiguration()
        // TDS 7.x carries TLS 1.2 at most; 1.3 needs TDS 8 (strict).
        configuration.maximumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: configuration)
        let done = channel.eventLoop.makePromise(of: Void.self)
        let channel = channel
        let serverName = options.tlsServerName
        try await channel.eventLoop.submit {
            let framer = TDSTLSFramer()
            let ssl = try NIOSSLClientHandler(context: context, serverHostname: serverName)
            // Socket → framer → TLS → watcher → inbox.
            let watcher = TDSHandshakeWatcher(framer: framer, promise: done)
            let operations = channel.pipeline.syncOperations
            try operations.addHandler(framer, position: .first)
            try operations.addHandler(watcher, position: .after(framer))
            try operations.addHandler(ssl, position: .after(framer))
        }.get()
        try await done.futureResult.get()
    }

    // MARK: - Requests

    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func execute(_ sql: String, maxRows: Int? = nil) async throws -> TDSResponse {
        await lock()
        defer { unlock() }
        try await send(.sqlBatch, TDSRequest.sqlBatch(sql, transaction: transaction))
        return try await readResponse(maxRows: maxRows)
    }

    func executeSQL(_ sql: String, parameters: [TDSRequest.Value], maxRows: Int? = nil) async throws -> TDSResponse {
        await lock()
        defer { unlock() }
        try await send(.rpc, TDSRequest.executeSQL(sql, parameters: parameters, collation: collation, transaction: transaction))
        return try await readResponse(maxRows: maxRows)
    }

    /// Sends ATTENTION when a request is running; the request then ends with "cancelled".
    func cancel() async {
        guard requestRunning, !attentionSent else { return }
        attentionSent = true
        try? await channel.writeAndFlush(TDSPacket.attention).get()
    }

    private func send(_ type: TDSPacketType, _ payload: ByteBuffer) async throws {
        guard channel.isActive else { throw TDSError.connectionClosed }
        try await channel.writeAndFlush(TDSPacket.encode(type: type.rawValue, payload: payload, packetSize: packetSize)).get()
    }

    // MARK: - Reading

    private func readPacket() async throws -> (TDSPacketHeader, ByteBuffer) {
        while true {
            if let header = TDSPacketHeader.peek(raw), header.length >= TDSPacketHeader.size, raw.readableBytes >= header.length {
                raw.moveReaderIndex(forwardBy: TDSPacketHeader.size)
                let payload = raw.readSlice(length: header.length - TDSPacketHeader.size)!
                if raw.readableBytes == 0 { raw.clear() } else if raw.readerIndex > 65536 { raw.discardReadBytes() }
                return (header, payload)
            }
            var chunk = try await inbox.read()
            raw.writeBuffer(&chunk)
        }
    }

    /// A whole message (PRELOGIN response).
    private func readMessage() async throws -> ByteBuffer {
        var message = ByteBuffer()
        while true {
            var (header, payload) = try await readPacket()
            message.writeBuffer(&payload)
            if header.isEndOfMessage { return message }
        }
    }

    /// Reads tokens until the reply is over: the message ended and, after an ATTENTION, its acknowledgement came.
    private func readResponse(maxRows: Int?, isLogin: Bool = false) async throws -> TDSResponse {
        requestRunning = true
        attentionSent = false
        defer { requestRunning = false; attentionSent = false }
        var response = TDSResponse()
        var pending = ByteBuffer()
        var messageEnded = false
        var columns: [TDSColumn] = []
        var current: TDSResultSet?
        var cappedAttention = false
        var acknowledged = false
        var doneCount: Int?, inProcCount: Int?
        var firstError: TDSServerMessage?

        func finishSet() {
            if let set = current { response.resultSets.append(set) }
            current = nil
        }

        while true {
            if pending.readableBytes == 0 && messageEnded {
                if attentionSent && !acknowledged {
                    messageEnded = false
                    continue
                }
                break
            }
            var copy = pending
            let token: TDSToken
            do {
                token = try TDSTokenParser.next(&copy, columns: columns)
            } catch TDSError.incomplete {
                if messageEnded { throw TDSError.protocolViolation("truncated reply") }
                // Read until the buffer doubles, so a huge value isn't re-parsed for every packet.
                let target = max(pending.readableBytes * 2, 1)
                repeat {
                    var (header, payload) = try await readPacket()
                    pending.writeBuffer(&payload)
                    if header.isEndOfMessage { messageEnded = true }
                } while !messageEnded && pending.readableBytes < target
                continue
            }
            pending = copy
            if pending.readableBytes == 0 { pending.clear() }

            switch token {
            case .columnMetadata(let meta):
                finishSet()
                columns = meta
                if !meta.isEmpty { current = TDSResultSet(columns: meta) }
            case .row(let values):
                if let maxRows, let count = current?.rows.count, count >= max(maxRows, 0) {
                    current?.isTruncated = true
                    if !attentionSent {
                        // Stop the server instead of reading rows that are dropped.
                        attentionSent = true
                        cappedAttention = true
                        try? await channel.writeAndFlush(TDSPacket.attention).get()
                    }
                } else {
                    current?.rows.append(values)
                }
            case .done(let done):
                if done.isAttentionAck { acknowledged = true }
                if current != nil && done.kind != .proc { finishSet() }
                if done.hasCount && !done.isAttentionAck {
                    if done.kind == .done { doneCount = Int(done.rowCount) } else if done.kind == .inProc { inProcCount = Int(done.rowCount) }
                }
            case .error(let message):
                response.messages.append(message)
                if firstError == nil { firstError = message }
            case .info(let message):
                response.messages.append(message)
            case .envChange(let change):
                switch change {
                case .database(let name): database = name
                case .packetSize(let size): packetSize = size
                case .collation(let bytes) where bytes.count == 5: collation = bytes
                case .beginTransaction(let descriptor): transaction = descriptor
                case .endTransaction: transaction = 0
                default: break
                }
            case .loginAck(let program, let version):
                serverProgram = program
                serverVersion = version
            case .sspi(let bytes):
                response.sspi = bytes
            case .returnStatus, .ignored:
                break
            }
        }
        finishSet()
        if attentionSent && !cappedAttention { throw TDSError.cancelled }
        if let firstError, !isLogin {
            throw TDSError.server(firstError.text, number: firstError.number)
        }
        response.affectedRows = doneCount ?? inProcCount
        return response
    }
}

// MARK: - Channel handlers

/// Bytes read from the channel, handed to the connection's reader.
final class TDSInbox: Sendable {
    private struct State {
        var chunks: [ByteBuffer] = []
        var waiter: CheckedContinuation<ByteBuffer, any Error>?
        var error: (any Error)?
    }

    private let state = NIOLockedValueBox(State())

    func push(_ buffer: ByteBuffer) {
        let waiter = state.withLockedValue { state -> CheckedContinuation<ByteBuffer, any Error>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.chunks.append(buffer)
            return nil
        }
        waiter?.resume(returning: buffer)
    }

    func fail(_ error: any Error) {
        let waiter = state.withLockedValue { state -> CheckedContinuation<ByteBuffer, any Error>? in
            if state.error == nil { state.error = error }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: error)
    }

    func read() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLockedValue { state -> Result<ByteBuffer, any Error>? in
                if !state.chunks.isEmpty { return .success(state.chunks.removeFirst()) }
                if let error = state.error { return .failure(error) }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

final class TDSInboxHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let inbox: TDSInbox

    init(inbox: TDSInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        inbox.push(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.fail(TDSError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        inbox.fail(error)
        context.close(promise: nil)
    }
}

/// During the TLS handshake, wraps what NIOSSL writes in PRELOGIN packets and unwraps the server's;
/// afterwards TLS records go on the wire as they are.
final class TDSTLSFramer: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    var passthrough = false
    private var inbound = ByteBuffer()
    private var outbound = ByteBuffer()
    private var promises: [EventLoopPromise<Void>] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard !passthrough else { context.fireChannelRead(data); return }
        inbound.writeBuffer(&bytes)
        while let header = TDSPacketHeader.peek(inbound), header.length >= TDSPacketHeader.size, inbound.readableBytes >= header.length {
            inbound.moveReaderIndex(forwardBy: TDSPacketHeader.size)
            let payload = inbound.readSlice(length: header.length - TDSPacketHeader.size)!
            context.fireChannelRead(wrapInboundOut(payload))
            if passthrough { break }
        }
        if passthrough, inbound.readableBytes > 0 {
            let rest = inbound
            inbound = ByteBuffer()
            context.fireChannelRead(wrapInboundOut(rest))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !passthrough else { context.write(data, promise: promise); return }
        var bytes = unwrapOutboundIn(data)
        outbound.writeBuffer(&bytes)
        if let promise { promises.append(promise) }
    }

    func flush(context: ChannelHandlerContext) {
        if outbound.readableBytes > 0 {
            let packet = TDSPacket.encode(type: TDSPacketType.prelogin.rawValue, payload: outbound, packetSize: 4096)
            outbound = ByteBuffer()
            let pending = promises
            promises = []
            let future = context.write(wrapOutboundOut(packet))
            for promise in pending { future.cascade(to: promise) }
        }
        context.flush()
    }
}

/// Switches the framer to pass-through when the handshake completes, and reports the outcome.
final class TDSHandshakeWatcher: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let framer: TDSTLSFramer
    let promise: EventLoopPromise<Void>
    private var finished = false

    init(framer: TDSTLSFramer, promise: EventLoopPromise<Void>) {
        self.framer = framer
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event, !finished {
            finished = true
            framer.passthrough = true
            promise.succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !finished { finished = true; promise.fail(error) }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finished = true; promise.fail(TDSError.connectionClosed) }
        context.fireChannelInactive()
    }
}
