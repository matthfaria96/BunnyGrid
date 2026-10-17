import Citadel
import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

public enum SSHTunnelError: LocalizedError, Equatable, Sendable {
    case missingHost
    case missingUser
    case missingPrivateKey
    case unreadablePrivateKey(path: String, reason: String)
    case unsupportedKey(String)
    case passphraseRequired
    case wrongPassphrase
    case hostKeyChanged(host: String, expected: String, actual: String)
    case authenticationFailed(user: String, host: String, method: SSHAuthMethod)
    /// RSA keys are signed with SHA-1 (`ssh-rsa`), which OpenSSH 8.8 and later refuse by default.
    case rsaKeyRejected(user: String, host: String)
    case passwordNotAccepted(host: String)
    case publicKeyNotAccepted(host: String)
    case unreachable(host: String, port: Int, reason: String)
    case forwardRefused(target: String, reason: String)
    case socketNotSupported

    public var errorDescription: String? {
        switch self {
        case .missingHost: "SSH: enter the SSH host in the SSH tab."
        case .missingUser: "SSH: enter the SSH user name."
        case .missingPrivateKey: "SSH: choose a private key file in the SSH tab."
        case .unreadablePrivateKey(let path, let reason): "SSH: could not read the private key at \(path): \(reason)"
        case .unsupportedKey(let detail): "SSH: \(detail)"
        case .passphraseRequired: "SSH: the private key is encrypted. Enter its passphrase in the SSH tab."
        case .wrongPassphrase: "SSH: wrong passphrase for the private key."
        case .hostKeyChanged(let host, let expected, let actual):
            "SSH: the host key of \(host) changed (expected \(expected), got \(actual)). If the server was reinstalled, click Forget Host Key in the SSH tab; otherwise someone may be intercepting the connection."
        case .authenticationFailed(let user, let host, let method):
            method == .password
                ? "SSH: \(host) rejected the password for “\(user)”."
                : "SSH: \(host) rejected the private key for “\(user)”."
        case .rsaKeyRejected(let user, let host):
            "SSH: \(host) rejected the RSA key for “\(user)”. BunnyGrid signs RSA keys with SHA-1 (ssh-rsa), which OpenSSH 8.8 and later refuse by default. Use an ed25519 or ECDSA key (ssh-keygen -t ed25519), or allow ssh-rsa on the server."
        case .passwordNotAccepted(let host): "SSH: \(host) doesn't accept password logins. Use a public key."
        case .publicKeyNotAccepted(let host): "SSH: \(host) doesn't accept public key logins. Use a password."
        case .unreachable(let host, let port, let reason): "SSH: could not reach \(host):\(port) (\(reason))."
        case .forwardRefused(let target, let reason): "SSH: the SSH server could not open \(target) (\(reason)). Check the database host and port as seen from the SSH server."
        case .socketNotSupported: "SSH: a socket file can't be used through an SSH tunnel. Clear “Use socket file” in the Advanced tab, or turn the tunnel off."
        }
    }
}

/// A local port forward over SSH: listens on 127.0.0.1 at a random port and opens a `direct-tcpip`
/// channel to the target (the database host and port, as seen from the SSH server) for every connection.
public actor SSHTunnel {
    public struct Target: Hashable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public nonisolated let ssh: SSHTunnelConfig
    public nonisolated let target: Target
    /// The local end drivers connect to.
    public nonisolated let localPort: Int
    /// The key the server presented, and whether this was the first time it was seen.
    public nonisolated let hostKey: SSHHostKey
    public nonisolated let hostKeyWasNew: Bool

    private let client: SSHConnection
    private let listener: any Channel
    private let closed = NIOLockedValueBox(false)

    private init(ssh: SSHTunnelConfig, target: Target, client: SSHConnection, listener: any Channel, localPort: Int, hostKey: SSHHostKey, hostKeyWasNew: Bool) {
        self.ssh = ssh
        self.target = target
        self.client = client
        self.listener = listener
        self.localPort = localPort
        self.hostKey = hostKey
        self.hostKeyWasNew = hostKeyWasNew
    }

    /// Logs in to the SSH server, checks that the target is reachable from there, and starts listening locally.
    public static func open(
        ssh: SSHTunnelConfig,
        secret: String?,
        target: Target,
        knownHosts: KnownHostsStore = KnownHostsStore(),
        connectTimeout: TimeAmount = .seconds(15)
    ) async throws -> SSHTunnel {
        let host = ssh.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw SSHTunnelError.missingHost }
        guard !ssh.username.isEmpty else { throw SSHTunnelError.missingUser }
        let authentication = try SSHCredentials.authenticationMethod(for: ssh, secret: secret)
        let checker = HostKeyChecker(hostID: SSHHostKey.hostID(host: host, port: ssh.port), store: knownHosts)

        let client: SSHConnection
        do {
            client = SSHConnection(try await SSHClient.connect(
                host: host,
                port: ssh.port,
                authenticationMethod: authentication,
                hostKeyValidator: .custom(checker),
                reconnect: .never,
                algorithms: .all,
                connectTimeout: connectTimeout
            ))
        } catch {
            if let mismatch = checker.mismatch { throw mismatch }
            throw Self.describe(error, ssh: ssh, host: host, reachedServer: checker.presented != nil)
        }
        guard let hostKey = checker.presented else {
            await client.close()
            throw SSHTunnelError.unreachable(host: host, port: ssh.port, reason: "no host key")
        }

        // Probe the target once so a wrong database host shows up here, not as a dropped connection later.
        do {
            let probe = try await client.openChannel(
                to: SSHChannelType.DirectTCPIP(
                    targetHost: target.host,
                    targetPort: target.port,
                    originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                )
            ) { channel in channel.eventLoop.makeSucceededVoidFuture() }
            try? await probe.close()
        } catch {
            await client.close()
            throw SSHTunnelError.forwardRefused(target: "\(target.host):\(target.port)", reason: Self.reason(error))
        }

        // The tunnel is created after the listener, so accepted connections reach it through a box.
        let tunnelBox = NIOLockedValueBox<SSHTunnel?>(nil)
        let listener: any Channel
        do {
            listener = try await ServerBootstrap(group: client.eventLoop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelInitializer { inbound in
                    let promise = inbound.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        guard let tunnel = tunnelBox.withLockedValue({ $0 }) else { throw ChannelError.ioOnClosedChannel }
                        try await tunnel.forward(inbound)
                    }
                    return promise.futureResult
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
        } catch {
            await client.close()
            throw SSHTunnelError.unreachable(host: "127.0.0.1", port: 0, reason: "could not open a local port: \(Self.reason(error))")
        }
        let tunnel = SSHTunnel(
            ssh: ssh,
            target: target,
            client: client,
            listener: listener,
            localPort: listener.localAddress?.port ?? 0,
            hostKey: hostKey,
            hostKeyWasNew: checker.wasNew
        )
        tunnelBox.withLockedValue { $0 = tunnel }
        return tunnel
    }

    /// Whether the SSH session is still up.
    public var isAlive: Bool {
        !closed.withLockedValue { $0 } && client.isConnected
    }

    public func close() async {
        guard !closed.withLockedValue({ let was = $0; $0 = true; return was }) else { return }
        try? await listener.close()
        await client.close()
    }

    /// Joins an accepted local connection to a new `direct-tcpip` channel.
    private func forward(_ inbound: any Channel) async throws {
        let originator = try inbound.remoteAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let remote = try await client.openChannel(
            to: SSHChannelType.DirectTCPIP(targetHost: target.host, targetPort: target.port, originatorAddress: originator)
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(PipeHandler(partner: inbound))
            }
        }
        try await inbound.eventLoop.submit {
            try inbound.pipeline.syncOperations.addHandler(PipeHandler(partner: remote))
        }.get()
        try await inbound.setOption(ChannelOptions.autoRead, value: true).get()
    }

    private static func reason(_ error: any Error) -> String {
        if let error = error as? ChannelError, case .connectTimeout = error { return "timed out" }
        if let error = error as? IOError { return error.description }
        if let error = error as? NIOSSHError { return String(describing: error.type) }
        if let error = error as? SSHClientError, error == .channelCreationFailed { return "channel refused" }
        let text = String(describing: error)
        return text.isEmpty ? error.localizedDescription : text
    }

    private static func describe(_ error: any Error, ssh: SSHTunnelConfig, host: String, reachedServer: Bool) -> any Error {
        if let error = error as? SSHTunnelError { return error }
        let rejected: SSHTunnelError = SSHCredentials.usesRSAKey(ssh)
            ? .rsaKeyRejected(user: ssh.username, host: host)
            : .authenticationFailed(user: ssh.username, host: host, method: ssh.authMethod)
        if let error = error as? SSHClientError {
            switch error {
            case .unsupportedPasswordAuthentication: return SSHTunnelError.passwordNotAccepted(host: host)
            case .unsupportedPrivateKeyAuthentication: return SSHTunnelError.publicKeyNotAccepted(host: host)
            case .allAuthenticationOptionsFailed: return rejected
            default: break
            }
        }
        if reachedServer, error is ChannelError || String(describing: error).contains("Disconnected") {
            // Got the host key, then nothing: the server closed the connection during login.
            return rejected
        }
        return SSHTunnelError.unreachable(host: host, port: ssh.port, reason: reason(error))
    }
}

/// Citadel's client isn't Sendable, but its channel work hops onto its event loop, so the tunnel shares it through this box.
private final class SSHConnection: @unchecked Sendable {
    private let client: SSHClient

    init(_ client: SSHClient) {
        self.client = client
    }

    var isConnected: Bool { client.isConnected }
    var eventLoop: any EventLoop { client.eventLoop }

    func close() async {
        try? await client.close()
    }

    func openChannel(to target: SSHChannelType.DirectTCPIP, initialize: @escaping (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        try await client.createDirectTCPIPChannel(using: target, initialize: initialize)
    }
}

/// Trust on first use against `KnownHostsStore`, remembering what the server presented.
private final class HostKeyChecker: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let hostID: String
    let store: KnownHostsStore
    private let state = NIOLockedValueBox<(presented: SSHHostKey?, wasNew: Bool, mismatch: SSHTunnelError?)>((nil, false, nil))

    init(hostID: String, store: KnownHostsStore) {
        self.hostID = hostID
        self.store = store
    }

    var presented: SSHHostKey? { state.withLockedValue { $0.presented } }
    var wasNew: Bool { state.withLockedValue { $0.wasNew } }
    var mismatch: SSHTunnelError? { state.withLockedValue { $0.mismatch } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let key = SSHHostKey(host: hostID, openSSHLine: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(SSHTunnelError.unsupportedKey("the server's host key could not be read."))
            return
        }
        switch store.verify(key) {
        case .trusted:
            state.withLockedValue { $0.presented = key }
            validationCompletePromise.succeed(())
        case .new:
            state.withLockedValue { $0 = (key, true, nil) }
            validationCompletePromise.succeed(())
        case .mismatch(let expected):
            let error = SSHTunnelError.hostKeyChanged(host: hostID, expected: expected.fingerprint, actual: key.fingerprint)
            state.withLockedValue { $0 = (key, false, error) }
            validationCompletePromise.fail(error)
        }
    }
}

/// Copies bytes read on one channel to its partner, closing the partner when this side closes.
/// Reading pauses while the partner can't keep up.
private final class PipeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let partner: any Channel

    init(partner: any Channel) {
        self.partner = partner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner.write(unwrapInboundIn(data), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner.flush()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        partner.setOption(ChannelOptions.autoRead, value: writable).whenSuccess { [partner] in
            if writable { partner.read() }
        }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner.close(promise: nil)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Turns the SSH tab's settings into a Citadel authentication method.
enum SSHCredentials {
    static func authenticationMethod(for ssh: SSHTunnelConfig, secret: String?) throws -> SSHAuthenticationMethod {
        switch ssh.authMethod {
        case .password:
            return .passwordBased(username: ssh.username, password: secret ?? "")
        case .publicKey:
            let path = (ssh.privateKeyPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !path.isEmpty else { throw SSHTunnelError.missingPrivateKey }
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw SSHTunnelError.unreadablePrivateKey(path: path, reason: (error as NSError).localizedFailureReason ?? error.localizedDescription)
            }
            return try authenticationMethod(username: ssh.username, privateKey: text, passphrase: secret)
        }
    }

    /// Supports OpenSSH-format ed25519 and RSA keys (encrypted or not) and unencrypted PEM ECDSA keys.
    static func authenticationMethod(username: String, privateKey text: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let passphrase = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            let encrypted = isEncryptedOpenSSHKey(text)
            if encrypted && passphrase == nil { throw SSHTunnelError.passphraseRequired }
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: text)
            } catch {
                throw SSHTunnelError.unsupportedKey("the private key could not be read (\(error.localizedDescription)).")
            }
            do {
                switch type {
                case .ed25519:
                    return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: encrypted ? passphrase : nil))
                case .rsa:
                    return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: encrypted ? passphrase : nil))
                default:
                    if encrypted {
                        throw SSHTunnelError.unsupportedKey("encrypted \(type) keys aren't supported yet. Use an ed25519 key, or remove the passphrase (ssh-keygen -p -N \"\" -f key).")
                    }
                    guard let scalar = openSSHECDSAScalar(text), let method = ecdsa(username: username, scalar: scalar) else {
                        throw SSHTunnelError.unsupportedKey("\(type) keys aren't supported. Use an ed25519 or ECDSA key.")
                    }
                    return method
                }
            } catch let error as SSHTunnelError {
                throw error
            } catch {
                if encrypted { throw SSHTunnelError.wrongPassphrase }
                throw SSHTunnelError.unsupportedKey("the private key could not be read (\(String(describing: error))).")
            }
        }
        if text.contains("BEGIN EC PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") {
            if text.contains("Proc-Type: 4,ENCRYPTED") {
                throw SSHTunnelError.unsupportedKey("encrypted PEM keys aren't supported. Convert the key to OpenSSH format with ssh-keygen -p -f key.")
            }
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .p256(username: username, privateKey: key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .p384(username: username, privateKey: key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .p521(username: username, privateKey: key) }
            // `ssh-keygen -m PEM` writes the curve as explicit parameters, which CryptoKit rejects; take the scalar.
            if let scalar = sec1Scalar(text), let method = ecdsa(username: username, scalar: scalar) { return method }
            throw SSHTunnelError.unsupportedKey("only ECDSA keys are read from PEM files. Convert other keys to OpenSSH format with ssh-keygen -p -f key.")
        }
        if text.contains("BEGIN RSA PRIVATE KEY") || text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw SSHTunnelError.unsupportedKey("PEM RSA keys aren't supported. Convert the key to OpenSSH format with ssh-keygen -p -f key.")
        }
        if text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") {
            throw SSHTunnelError.unsupportedKey("that is a public key. Choose the private key file (usually the one without .pub).")
        }
        throw SSHTunnelError.unsupportedKey("the file is not a private key.")
    }

    /// An ECDSA login from the private scalar; its length picks the curve.
    static func ecdsa(username: String, scalar: [UInt8]) -> SSHAuthenticationMethod? {
        switch scalar.count {
        case 32: (try? P256.Signing.PrivateKey(rawRepresentation: scalar)).map { .p256(username: username, privateKey: $0) }
        case 48: (try? P384.Signing.PrivateKey(rawRepresentation: scalar)).map { .p384(username: username, privateKey: $0) }
        case 66: (try? P521.Signing.PrivateKey(rawRepresentation: scalar)).map { .p521(username: username, privateKey: $0) }
        default: nil
        }
    }

    /// The private scalar of an unencrypted `openssh-key-v1` ECDSA key:
    /// private section = check1, check2, key type, curve name, public point, mpint d, comment.
    static func openSSHECDSAScalar(_ text: String) -> [UInt8]? {
        guard let data = base64Body(text) else { return nil }
        var reader = SSHWireReader(bytes: [UInt8](data))
        guard reader.skip(Array("openssh-key-v1\0".utf8).count),
              reader.string() == Array("none".utf8),  // cipher
              reader.string() != nil,                 // kdf
              reader.string() != nil,                 // kdf options
              reader.uint32() == 1,
              reader.string() != nil,                 // public key
              let section = reader.string() else { return nil }
        var privateReader = SSHWireReader(bytes: section)
        guard let check1 = privateReader.uint32(), privateReader.uint32() == check1,
              let type = privateReader.string(), String(decoding: type, as: UTF8.self).hasPrefix("ecdsa-sha2-"),
              let curve = privateReader.string(),
              privateReader.string() != nil,  // public point
              var scalar = privateReader.string() else { return nil }
        // The mpint drops leading zeros and may add a sign byte; bring it back to the curve's size.
        let size = switch String(decoding: curve, as: UTF8.self) {
        case "nistp256": 32
        case "nistp384": 48
        case "nistp521": 66
        default: scalar.count
        }
        while scalar.count > size, scalar.first == 0 { scalar.removeFirst() }
        if scalar.count < size { scalar = [UInt8](repeating: 0, count: size - scalar.count) + scalar }
        return scalar
    }

    /// The private key OCTET STRING of a SEC1 `EC PRIVATE KEY`: SEQUENCE { INTEGER 1, OCTET STRING d, … }.
    static func sec1Scalar(_ text: String) -> [UInt8]? {
        guard text.contains("BEGIN EC PRIVATE KEY"), let data = base64Body(text) else { return nil }
        var der = DERReader(bytes: [UInt8](data))
        guard der.header(tag: 0x30) != nil,
              let versionLength = der.header(tag: 0x02), der.skip(versionLength),
              let length = der.header(tag: 0x04) else { return nil }
        return der.take(length)
    }

    private static func base64Body(_ text: String) -> Data? {
        let body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.contains(":") }
            .joined()
        return Data(base64Encoded: body)
    }

    /// Whether the tunnel logs in with an RSA key (for the SHA-1 hint when the server refuses it).
    static func usesRSAKey(_ ssh: SSHTunnelConfig) -> Bool {
        guard ssh.authMethod == .publicKey,
              let text = try? String(contentsOfFile: (ssh.privateKeyPath as NSString).expandingTildeInPath, encoding: .utf8) else { return false }
        return (try? SSHKeyDetection.detectPrivateKeyType(from: text)) == .rsa
    }

    /// Reads the cipher name of an `openssh-key-v1` blob; anything but `none` means a passphrase is needed.
    static func isEncryptedOpenSSHKey(_ text: String) -> Bool {
        guard let data = base64Body(text) else { return false }
        let magic = Array("openssh-key-v1\0".utf8)
        var reader = SSHWireReader(bytes: [UInt8](data))
        guard Array(reader.bytes.prefix(magic.count)) == magic, reader.skip(magic.count), let cipher = reader.string() else { return false }
        return cipher != Array("none".utf8)
    }
}

/// Reads SSH wire format: big-endian uint32s and length-prefixed strings.
private struct SSHWireReader {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skip(_ count: Int) -> Bool {
        guard offset + count <= bytes.count else { return false }
        offset += count
        return true
    }

    mutating func uint32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() -> [UInt8]? {
        guard let length = uint32().map(Int.init), offset + length <= bytes.count else { return nil }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }
}

/// Just enough DER to walk a SEC1 private key.
private struct DERReader {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Reads a tag and its length; returns the length, leaving the reader at the contents.
    mutating func header(tag: UInt8) -> Int? {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
        let first = bytes[offset + 1]
        offset += 2
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count <= 4, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func skip(_ count: Int) -> Bool {
        guard offset + count <= bytes.count else { return false }
        offset += count
        return true
    }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
