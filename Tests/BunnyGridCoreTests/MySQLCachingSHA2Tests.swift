import Foundation
import NIOCore
import Testing
@testable import BunnyGridCore

@Suite("MySQL caching_sha2_password full authentication")
struct MySQLCachingSHA2Tests {
    @Test func handshakeAndScramble() throws {
        // A MySQL 8 greeting: version, connection id, nonce part 1, capabilities…, nonce part 2, plugin name.
        var bytes: [UInt8] = [10] + Array("8.4.0".utf8) + [0, 1, 0, 0, 0] + Array(1...8) + [0, 0xFF, 0xFF, 255, 2, 0, 0xFF, 0xDF, 21]
        bytes += [UInt8](repeating: 0, count: 10) + Array(9...20) + [0] + Array("caching_sha2_password".utf8) + [0]
        let handshake = try MySQLCachingSHA2.parseHandshake(bytes)
        #expect(handshake.serverVersion == "8.4.0")
        #expect(handshake.nonce == Array(1...20))
        #expect(handshake.plugin == "caching_sha2_password")
        #expect(MySQLCachingSHA2.scramble(password: "", nonce: handshake.nonce).isEmpty)
        #expect(MySQLCachingSHA2.scramble(password: "secret", nonce: handshake.nonce).count == 32)
        #expect(MySQLCachingSHA2.packet([1, 2, 3], sequence: 4) == [3, 0, 0, 4, 1, 2, 3])
        #expect(MySQLCachingSHA2.errorMessage([0xFF, 0x15, 0x04] + Array("#28000Access denied".utf8)) == "Access denied")
    }

    @Test func rsaKeyFromPEM() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        // Wrap PKCS#1 in a SubjectPublicKeyInfo, as the server sends it.
        func length(_ n: Int) -> [UInt8] { n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)] }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + length(pkcs1.count + 1) + [0] + [UInt8](pkcs1)
        let spki: [UInt8] = [0x30] + length(algorithm.count + bitString.count) + algorithm + bitString
        let pem = "-----BEGIN PUBLIC KEY-----\n" + Data(spki).base64EncodedString(options: .lineLength64Characters) + "\n-----END PUBLIC KEY-----\n"
        let nonce = Array<UInt8>(repeating: 7, count: 20)
        let encrypted = try MySQLCachingSHA2.encrypt(Array("pw".utf8) + [0], nonce: nonce, pem: pem)
        let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(encrypted) as CFData, nil) as Data?)
        #expect([UInt8](decrypted) == (Array("pw".utf8) + [0]).map { $0 ^ 7 })
    }

    static let env = ProcessInfo.processInfo.environment

    /// Against `scripts/test-servers/mysql.sh` (user bunny / bunnypass): after FLUSH PRIVILEGES empties the cache,
    /// full authentication works over TCP (RSA) and over the socket (clear text), and a wrong password fails.
    @Test(.enabled(if: env["BUNNYGRID_MYSQL_PORT"] != nil && env["BUNNYGRID_MYSQL_PASSWORD"] != nil))
    func fullAuthenticationAgainstServer() async throws {
        let port = Int(Self.env["BUNNYGRID_MYSQL_PORT"]!)!
        let user = Self.env["BUNNYGRID_MYSQL_USER"] ?? "bunny", password = Self.env["BUNNYGRID_MYSQL_PASSWORD"]!
        let admin = MySQLDriver(config: ConnectionConfig(kind: .mysql, host: "127.0.0.1", port: port, username: user, tls: .require), password: password)
        try await admin.connect()
        _ = try await admin.executeStatement("FLUSH PRIVILEGES")
        let tcp = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: port)
        try await MySQLCachingSHA2.authenticate(address: tcp, username: user, password: password, database: "", overSocket: false)
        await #expect(throws: (any Error).self) {
            try await MySQLCachingSHA2.authenticate(address: tcp, username: user, password: "wrong", database: "", overSocket: false)
        }
        if let socket = Self.env["BUNNYGRID_MYSQL_SOCKET"] {
            _ = try await admin.executeStatement("FLUSH PRIVILEGES")
            try await MySQLCachingSHA2.authenticate(address: try SocketAddress(unixDomainSocketPath: socket), username: user, password: password,
                                                    database: "", overSocket: true)
        }
        // Plain TCP through the driver after the cache was emptied.
        _ = try await admin.executeStatement("FLUSH PRIVILEGES")
        let plain = MySQLDriver(config: ConnectionConfig(kind: .mysql, host: "127.0.0.1", port: port, username: user, tls: .disable), password: password)
        try await plain.connect()
        await plain.disconnect()
        await admin.disconnect()
    }
}
