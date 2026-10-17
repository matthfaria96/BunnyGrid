import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import Security

/// `caching_sha2_password` full authentication on a connection of its own, for the cases MySQLNIO can't do:
/// over a socket file without SSL (the server counts the socket as secure and wants the password in clear text, while
/// MySQLNIO asks for the RSA key) and, over plain TCP, the RSA-OAEP exchange (`0x02` asks for the server's public
/// key; the password, NUL-terminated and XORed with the nonce, goes encrypted with it). A successful full
/// authentication puts the user in the server's cache, so MySQLNIO's next attempt takes the fast path.
enum MySQLCachingSHA2 {
    enum Failure: LocalizedError, Equatable {
        case server(String)
        case protocolError(String)
        case otherPlugin(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            case .protocolError(let what): "MySQL handshake: \(what)"
            case .otherPlugin(let name): "The user authenticates with \(name), not caching_sha2_password."
            }
        }
    }

    /// Authenticates once and disconnects.
    static func authenticate(address: SocketAddress, username: String, password: String, database: String, overSocket: Bool) async throws {
        let inbox = TDSInbox()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(TDSInboxHandler(inbox: inbox)) }
            }
            .connect(to: address).get()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            inbox.fail(Failure.protocolError("timed out"))
            channel.close(promise: nil)
        }
        defer {
            timeout.cancel()
            channel.close(promise: nil)
        }
        var reader = PacketReader(inbox: inbox)
        let (greeting, _) = try await reader.next()
        let handshake = try parseHandshake(greeting)
        var nonce = handshake.nonce
        var sequence: UInt8 = 1
        func send(_ payload: [UInt8]) async throws {
            var buffer = channel.allocator.buffer(capacity: payload.count + 4)
            buffer.writeBytes(packet(payload, sequence: sequence))
            sequence &+= 1
            try await channel.writeAndFlush(buffer).get()
        }
        try await send(handshakeResponse(username: username, scramble: scramble(password: password, nonce: nonce), database: database))
        while true {
            let (reply, seq) = try await reader.next()
            sequence = seq &+ 1
            guard let first = reply.first else { throw Failure.protocolError("empty packet") }
            switch first {
            case 0x00: // OK
                var quit = channel.allocator.buffer(capacity: 5)
                quit.writeBytes(packet([0x01], sequence: 0))
                try? await channel.writeAndFlush(quit).get()
                return
            case 0xFF:
                throw Failure.server(errorMessage(reply))
            case 0xFE: // AuthSwitchRequest
                let rest = Array(reply.dropFirst())
                guard let nul = rest.firstIndex(of: 0) else { throw Failure.protocolError("bad auth switch") }
                let plugin = String(decoding: rest[..<nul], as: UTF8.self)
                guard plugin == "caching_sha2_password" else { throw Failure.otherPlugin(plugin) }
                nonce = Array(rest[(nul + 1)...].prefix(20))
                try await send(scramble(password: password, nonce: nonce))
            case 0x01 where reply.count >= 2 && reply[1] == 0x03: // fast auth worked; OK follows
                continue
            case 0x01 where reply.count >= 2 && reply[1] == 0x04: // full authentication
                let secret = Array(password.utf8) + [0]
                if overSocket {
                    try await send(secret)
                } else {
                    try await send([0x02])
                    let (keyPacket, keySeq) = try await reader.next()
                    sequence = keySeq &+ 1
                    guard keyPacket.first == 0x01 else {
                        if keyPacket.first == 0xFF { throw Failure.server(errorMessage(keyPacket)) }
                        throw Failure.protocolError("no public key")
                    }
                    try await send(try encrypt(secret, nonce: nonce, pem: String(decoding: keyPacket.dropFirst(), as: UTF8.self)))
                }
            default:
                throw Failure.protocolError(String(format: "unexpected packet 0x%02X", first))
            }
        }
    }

    struct Handshake: Equatable {
        var serverVersion: String
        var nonce: [UInt8]
        var plugin: String
    }

    static func parseHandshake(_ bytes: [UInt8]) throws -> Handshake {
        if bytes.first == 0xFF { throw Failure.server(errorMessage(bytes)) }
        guard bytes.first == 10, let versionEnd = bytes.dropFirst().firstIndex(of: 0) else { throw Failure.protocolError("not a v10 handshake") }
        let version = String(decoding: bytes[1..<versionEnd], as: UTF8.self)
        var i = versionEnd + 1 + 4
        guard bytes.count >= i + 8 + 1 + 2 + 1 + 2 + 2 + 1 + 10 else { throw Failure.protocolError("short handshake") }
        var nonce = Array(bytes[i..<(i + 8)])
        i += 8 + 1 + 2 + 1 + 2 + 2
        let authLength = Int(bytes[i])
        i += 1 + 10
        let part2 = max(13, authLength - 8)
        guard bytes.count >= i + part2 else { throw Failure.protocolError("short nonce") }
        nonce += bytes[i..<(i + part2)].prefix(12)
        i += part2
        let plugin = bytes[i...].firstIndex(of: 0).map { String(decoding: bytes[i..<$0], as: UTF8.self) } ?? String(decoding: bytes[i...], as: UTF8.self)
        return Handshake(serverVersion: version, nonce: nonce, plugin: plugin)
    }

    /// `XOR(SHA256(password), SHA256(SHA256(SHA256(password)), nonce))`.
    static func scramble(password: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let p1 = Array(SHA256.hash(data: Array(password.utf8)))
        let p2 = Array(SHA256.hash(data: p1))
        let p3 = Array(SHA256.hash(data: p2 + nonce))
        return zip(p1, p3).map { $0 ^ $1 }
    }

    static func handshakeResponse(username: String, scramble: [UInt8], database: String) -> [UInt8] {
        // LONG_PASSWORD, PROTOCOL_41, TRANSACTIONS, SECURE_CONNECTION, PLUGIN_AUTH, PLUGIN_AUTH_LENENC (+ CONNECT_WITH_DB).
        var capabilities: UInt32 = 0x0000_0001 | 0x0000_0200 | 0x0000_2000 | 0x0000_8000 | 0x0008_0000 | 0x0020_0000
        if !database.isEmpty { capabilities |= 0x0000_0008 }
        var out: [UInt8] = []
        out += withUnsafeBytes(of: capabilities.littleEndian, Array.init)
        out += withUnsafeBytes(of: UInt32(1 << 24).littleEndian, Array.init)
        out.append(255) // utf8mb4
        out += [UInt8](repeating: 0, count: 23)
        out += Array(username.utf8) + [0]
        out.append(UInt8(scramble.count))
        out += scramble
        if !database.isEmpty { out += Array(database.utf8) + [0] }
        out += Array("caching_sha2_password".utf8) + [0]
        return out
    }

    /// RSA-OAEP (SHA-1, as the server uses) of the NUL-terminated password XORed with the nonce.
    static func encrypt(_ secret: [UInt8], nonce: [UInt8], pem: String) throws -> [UInt8] {
        let mixed = secret.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] }
        let key = try publicKey(pem: pem)
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(mixed) as CFData, &error) as Data? else {
            throw Failure.protocolError("RSA encryption failed: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return [UInt8](encrypted)
    }

    /// The server's key is a PEM `PUBLIC KEY` (SubjectPublicKeyInfo); Security wants the inner PKCS#1 `RSAPublicKey`.
    static func publicKey(pem: String) throws -> SecKey {
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard var der = Data(base64Encoded: base64).map([UInt8].init) else { throw Failure.protocolError("bad public key") }
        if pem.contains("BEGIN PUBLIC KEY"), let inner = spkiBitString(der) { der = inner }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            throw Failure.protocolError("bad public key: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return key
    }

    /// SEQUENCE { SEQUENCE { algorithm }, BIT STRING { RSAPublicKey } } → the RSAPublicKey bytes.
    static func spkiBitString(_ der: [UInt8]) -> [UInt8]? {
        func header(_ i: Int) -> (tag: UInt8, length: Int, start: Int)? {
            guard i + 1 < der.count else { return nil }
            var length = Int(der[i + 1]), start = i + 2
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n <= 4, start + n <= der.count else { return nil }
                length = der[start..<(start + n)].reduce(0) { $0 << 8 | Int($1) }
                start += n
            }
            return (der[i], length, start)
        }
        guard let outer = header(0), outer.tag == 0x30, let algorithm = header(outer.start), algorithm.tag == 0x30,
              let bits = header(algorithm.start + algorithm.length), bits.tag == 0x03, bits.start + bits.length <= der.count else { return nil }
        return Array(der[(bits.start + 1)..<(bits.start + bits.length)])
    }

    static func errorMessage(_ packet: [UInt8]) -> String {
        guard packet.count > 3 else { return "Access denied." }
        var text = packet.dropFirst(3)
        if text.first == UInt8(ascii: "#") { text = text.dropFirst(6) }
        return String(decoding: text, as: UTF8.self)
    }

    static func packet(_ payload: [UInt8], sequence: UInt8) -> [UInt8] {
        let n = payload.count
        return [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), sequence] + payload
    }

    struct PacketReader {
        let inbox: TDSInbox
        var pending: [UInt8] = []

        mutating func next() async throws -> ([UInt8], UInt8) {
            while true {
                if pending.count >= 4 {
                    let length = Int(pending[0]) | Int(pending[1]) << 8 | Int(pending[2]) << 16
                    if pending.count >= 4 + length {
                        let payload = Array(pending[4..<(4 + length)])
                        let sequence = pending[3]
                        pending.removeFirst(4 + length)
                        return (payload, sequence)
                    }
                }
                var chunk = try await inbox.read()
                pending += chunk.readBytes(length: chunk.readableBytes) ?? []
            }
        }
    }
}
