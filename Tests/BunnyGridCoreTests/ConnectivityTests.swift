import Foundation
import NIOSSL
import Testing
@testable import BunnyGridCore

/// Throwaway keys and certificates generated for these tests only.
enum Fixtures {
    static let ed25519 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCvfn40/guAn6HgoxFUXWxC5BEfHSUt+G6OKs8JqL5ZIAAAAIiLoBOxi6AT
        sQAAAAtzc2gtZWQyNTUxOQAAACCvfn40/guAn6HgoxFUXWxC5BEfHSUt+G6OKs8JqL5ZIA
        AAAEB0A3VvZO38k3V3sxZbDJPcUXMHkDvZrqMfB3hcrupDaK9+fjT+C4CfoeCjEVRdbELk
        ER8dJS34bo4qzwmovlkgAAAABHRlc3QB
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK9+fjT+C4CfoeCjEVRdbELkER8dJS34bo4qzwmovlkg test"
    /// What `ssh-keygen -l` prints for `ed25519Public`.
    static let ed25519Fingerprint = "SHA256:ISbefR/0PU8QgC4RLmBGkRN9tp4zl5twwnD+LYAWxZ8"

    /// Passphrase "secret".
    static let ed25519Encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD1qFHZDN
        CLWzidXhzRmAXOAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHP+2XD4Pan+EsLs
        Qb2Liy4R4Gm8lEffTGGhof0nKnAtAAAAkAd8JJ9SFkjOxIz0sCfsDA7tGw8qotLNgbc4aF
        DWiWPFJj3fKqiyfa/2M4hGbhm/6BIftpOP0kK7ue8bcXpYep+hPhuDx8ZvxuOeH/atRhI0
        Gi9AXSO4KMIOaatKj+VCrAcJ0Qo8p6djoXVyBInhPrIftI2tdiToh2SHMZUtcP2K46q7BK
        angEdfjy8kIsVU2Q==
        -----END OPENSSH PRIVATE KEY-----
        """

    static let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIBZjCCAQygAwIBAgIUP7UpKmKZs3BTCy1UKuLCzKQ6JdAwCgYIKoZIzj0EAwIw
        GTEXMBUGA1UEAwwOYnVubnlncmlkLXRlc3QwHhcNMjYxMDE3MDY0NjQwWhcNMzYx
        MDE0MDY0NjQwWjAZMRcwFQYDVQQDDA5idW5ueWdyaWQtdGVzdDBZMBMGByqGSM49
        AgEGCCqGSM49AwEHA0IABJdD9CevwV5nIyyx9vvJ7g5/WpgWBsVcBfvQHRuAoABn
        mnQkLt04VRqG1+8lYsmRgcCB6qOWWZB8ubp2Ry6MMoijMjAwMB0GA1UdDgQWBBTy
        MEs2Ng84aGV35Vid5uAyx9QsOjAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMC
        A0gAMEUCIQC0FZ7NNWfddBJmHbYnTpp07F7C04jOEqzwUzJw/VnSywIgPwcQIgqJ
        u7zHjVWQA3MMvWvlJKQZ43ZJ9m50G3zhxeA=
        -----END CERTIFICATE-----
        """
    static let certificateKey = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg2zsY/0rweHlkq1yN
        O3HT4/A213Mt/blAaATsrXmV4XyhRANCAASXQ/Qnr8FeZyMssfb7ye4Of1qYFgbF
        XAX70B0bgKAAZ5p0JC7dOFUahtfvJWLJkYHAgeqjllmQfLm6dkcujDKI
        -----END PRIVATE KEY-----
        """
    /// The same key, passphrase "keypass".
    static let certificateKeyEncrypted = """
        -----BEGIN EC PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-256-CBC,A9C9F18CFC792A7D4196B2660EB70E1E

        wTkxObMAkUY2hXneqqNs7iqZ0nE2n6nLUnXdcabYL6uuJE003p3lK5xamHdU9kiY
        +z29wJx2lfxYFo//wwCA7KqzYRLCCJxEDiNmU1FD1qGXrrTSmqi2LaDC2NDtjnS7
        ETV3AN0j/fLAtUbYZ5XGXUfUNb3VOzkzLoEMrvNbGio=
        -----END EC PRIVATE KEY-----
        """

    /// Writes `contents` to a new temporary file and returns its path.
    static func file(_ contents: String, name: String = "fixture") throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

@Suite struct ConnectionConfigCodingTests {
    /// A connections.json entry written before SSL files, SSH and sockets existed.
    static let legacyJSON = """
        [{"color":"blue","database":"shop","filePath":"","host":"db.example.com","id":"6F1B3F7A-8C1E-4D7B-9E59-0D3C2A7C1E11",
          "kind":"postgresql","name":"Shop","port":5432,"readOnly":false,"tls":"require","username":"ana"}]
        """

    @Test func decodesConnectionsWithoutTheNewFields() throws {
        let configs = try JSONDecoder().decode([ConnectionConfig].self, from: Data(Self.legacyJSON.utf8))
        let config = try #require(configs.first)
        #expect(config.tls == .require)
        #expect(config.ssl == nil && config.ssh == nil && config.socketPath == nil)
        #expect(config.activeSSH == nil && config.activeSocketPath == nil)
    }

    @Test func roundTripsSSLSSHAndSocket() throws {
        var config = ConnectionConfig(kind: .mysql, host: "10.0.0.5", username: "app", tls: .verifyFull)
        config.ssl = SSLFiles(caCertificatePath: "~/certs/ca.pem", clientCertificatePath: "/c.pem", clientKeyPath: "/k.pem")
        config.ssh = SSHTunnelConfig(enabled: true, host: "bastion", port: 2222, username: "ops", authMethod: .publicKey, privateKeyPath: "~/.ssh/id_ed25519")
        config.socketPath = "/tmp/mysql.sock"
        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([ConnectionConfig].self, from: data)
        #expect(decoded == [config])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"verify-full\""))
        #expect(!json.lowercased().contains("password\":"), "no secrets in connections.json")
    }

    @Test func decodesPartialNestedObjects() throws {
        let json = """
            {"id":"6F1B3F7A-8C1E-4D7B-9E59-0D3C2A7C1E11","name":"","kind":"postgresql","host":"h","port":5432,"username":"u",
             "database":"","filePath":"","tls":"verify-ca","color":"none","readOnly":false,
             "ssh":{"enabled":true,"host":"jump"},"ssl":{"caCertificatePath":"/ca.pem"}}
            """
        let config = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        #expect(config.tls == .verifyCA)
        #expect(config.ssh == SSHTunnelConfig(enabled: true, host: "jump", port: 22, username: "", authMethod: .password, privateKeyPath: ""))
        #expect(config.ssl == SSLFiles(caCertificatePath: "/ca.pem"))
    }

    @Test func tunnelAndSocketOnlyApplyToServerEngines() {
        var config = ConnectionConfig(kind: .sqlite, filePath: "/tmp/a.db")
        config.ssh = SSHTunnelConfig(enabled: true, host: "jump")
        config.socketPath = "/tmp/x.sock"
        #expect(config.activeSSH == nil && config.activeSocketPath == nil)
        config.kind = .postgresql
        #expect(config.activeSSH?.host == "jump")
        config.ssh?.enabled = false
        #expect(config.activeSSH == nil)
        config.socketPath = "  "
        #expect(config.activeSocketPath == nil)
        config.socketPath = "~/pg"
        #expect(config.activeSocketPath == NSString(string: "~/pg").expandingTildeInPath)
    }

    @Test func tlsModeProperties() {
        #expect(!TLSMode.prefer.isEnforced && TLSMode.require.isEnforced && TLSMode.verifyFull.isEnforced)
        #expect(!TLSMode.require.verifiesCertificate && TLSMode.verifyCA.verifiesCertificate)
        #expect(TLSMode(rawValue: "verify-ca") == .verifyCA)
    }
}

@Suite struct KeychainNamingTests {
    @Test func accountsPerConnection() throws {
        let id = try #require(UUID(uuidString: "6F1B3F7A-8C1E-4D7B-9E59-0D3C2A7C1E11"))
        #expect(KeychainStore.sshAccount(for: id) == "6F1B3F7A-8C1E-4D7B-9E59-0D3C2A7C1E11.ssh")
        #expect(KeychainStore.sslKeyAccount(for: id) == "6F1B3F7A-8C1E-4D7B-9E59-0D3C2A7C1E11.ssl-key")
        #expect(KeychainStore().service == "app.bunnygrid.connections")
    }
}

@Suite struct ConnectionURIConnectivityTests {
    @Test func parsesVerifyModesAndCertificates() throws {
        let pg = try ConnectionURI.parse("postgresql://ana@db.example.com/shop?sslmode=verify-full&sslrootcert=/ca.pem&sslcert=/c.pem&sslkey=/k.pem")
        #expect(pg.config.tls == .verifyFull)
        #expect(pg.config.ssl == SSLFiles(caCertificatePath: "/ca.pem", clientCertificatePath: "/c.pem", clientKeyPath: "/k.pem"))
        #expect(try ConnectionURI.parse("postgresql://h/db?sslmode=verify-ca").config.tls == .verifyCA)
        let mysql = try ConnectionURI.parse("mysql://root@h/db?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem")
        #expect(mysql.config.tls == .verifyFull)
        #expect(mysql.config.ssl?.caCertificatePath == "/ca.pem")
        #expect(try ConnectionURI.parse("mysql://h?ssl-mode=VERIFY_CA").config.tls == .verifyCA)
        #expect(try ConnectionURI.parse("mysql://h?ssl-mode=PREFERRED").config.tls == .prefer)
        #expect(try ConnectionURI.parse("postgresql://h/db").config.ssl == nil)
    }

    @Test func parsesSocketFiles() throws {
        let query = try ConnectionURI.parse("postgresql://ana@/shop?host=/tmp")
        #expect(query.config.socketPath == "/tmp" && query.config.host == "localhost" && query.config.database == "shop")
        let encoded = try ConnectionURI.parse("postgresql://ana@%2Fvar%2Frun%2Fpostgresql/shop")
        #expect(encoded.config.socketPath == "/var/run/postgresql")
        let mysql = try ConnectionURI.parse("mysql://root@localhost/db?socket=/tmp/mysql.sock")
        #expect(mysql.config.socketPath == "/tmp/mysql.sock" && mysql.config.host == "localhost")
        #expect(throws: ConnectionURI.ParseError.invalid) { try ConnectionURI.parse("postgresql:///shop") }
    }

    @Test func buildsURIsWithTheNewSettings() throws {
        var pg = ConnectionConfig(kind: .postgresql, host: "db", port: 5432, username: "ana", database: "shop", tls: .verifyCA)
        pg.ssl = SSLFiles(caCertificatePath: "/ca.pem")
        #expect(ConnectionURI.string(for: pg) == "postgresql://ana@db:5432/shop?sslmode=verify-ca&sslrootcert=/ca.pem")
        var mysql = ConnectionConfig(kind: .mysql, host: "localhost", username: "root", tls: .verifyFull)
        mysql.socketPath = "/tmp/mysql.sock"
        let uri = ConnectionURI.string(for: mysql)
        #expect(uri == "mysql://root@localhost:3306?ssl-mode=VERIFY_IDENTITY&socket=/tmp/mysql.sock")
        let back = try ConnectionURI.parse(uri)
        #expect(back.config.tls == .verifyFull && back.config.socketPath == "/tmp/mysql.sock")
        pg.socketPath = "/tmp"
        let parsed = try ConnectionURI.parse(ConnectionURI.string(for: pg))
        #expect(parsed.config.socketPath == "/tmp" && parsed.config.ssl == pg.ssl && parsed.config.tls == .verifyCA)
    }
}

@Suite struct ConnectionTLSTests {
    private func config(_ mode: TLSMode, ssl: SSLFiles? = nil) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .postgresql, host: "db.example.com", tls: mode)
        config.ssl = ssl
        return config
    }

    @Test func modesMapToCertificateVerification() throws {
        #expect(try ConnectionTLS.configuration(for: config(.disable)) == nil)
        #expect(try ConnectionTLS.configuration(for: config(.prefer))?.certificateVerification == CertificateVerification.none)
        #expect(try ConnectionTLS.configuration(for: config(.require))?.certificateVerification == CertificateVerification.none)
        #expect(try ConnectionTLS.configuration(for: config(.verifyCA))?.certificateVerification == .noHostnameVerification)
        #expect(try ConnectionTLS.configuration(for: config(.verifyFull))?.certificateVerification == .fullVerification)
        // No CA file: the system's trusted roots.
        #expect(try ConnectionTLS.configuration(for: config(.verifyFull))?.trustRoots == .default)
    }

    @Test func loadsCAAndClientCertificate() throws {
        let cert = try Fixtures.file(Fixtures.certificate, name: "cert.pem")
        let key = try Fixtures.file(Fixtures.certificateKey, name: "key.pem")
        let tls = try #require(try ConnectionTLS.configuration(for: config(.verifyFull, ssl: SSLFiles(caCertificatePath: cert, clientCertificatePath: cert, clientKeyPath: key))))
        let expected = try NIOSSLCertificate.fromPEMBytes(Array(Fixtures.certificate.utf8))
        #expect(tls.trustRoots == .certificates(expected))
        #expect(tls.certificateChain == expected.map { .certificate($0) })
        #expect(tls.privateKey != nil)
    }

    @Test func decryptsAnEncryptedClientKey() throws {
        let cert = try Fixtures.file(Fixtures.certificate, name: "cert.pem")
        let key = try Fixtures.file(Fixtures.certificateKeyEncrypted, name: "key.pem")
        let files = SSLFiles(clientCertificatePath: cert, clientKeyPath: key)
        #expect(try ConnectionTLS.configuration(for: config(.require, ssl: files), keyPassphrase: "keypass")?.privateKey != nil)
        #expect(throws: ConnectionTLSError.wrongKeyPassphrase(path: key)) {
            try ConnectionTLS.configuration(for: config(.require, ssl: files))
        }
        #expect(throws: ConnectionTLSError.wrongKeyPassphrase(path: key)) {
            try ConnectionTLS.configuration(for: config(.require, ssl: files), keyPassphrase: "nope")
        }
    }

    @Test func explainsBadFiles() throws {
        let cert = try Fixtures.file(Fixtures.certificate, name: "cert.pem")
        #expect(throws: ConnectionTLSError.certificateWithoutKey) {
            try ConnectionTLS.configuration(for: config(.require, ssl: SSLFiles(clientCertificatePath: cert)))
        }
        #expect(throws: ConnectionTLSError.keyWithoutCertificate) {
            try ConnectionTLS.configuration(for: config(.require, ssl: SSLFiles(clientKeyPath: cert)))
        }
        do {
            _ = try ConnectionTLS.configuration(for: config(.verifyCA, ssl: SSLFiles(caCertificatePath: "/nonexistent/ca.pem")))
            Issue.record("expected an error")
        } catch let error as ConnectionTLSError {
            #expect(error.errorDescription?.contains("/nonexistent/ca.pem") == true)
        }
        let garbage = try Fixtures.file("not a certificate", name: "ca.pem")
        #expect(throws: ConnectionTLSError.self) {
            try ConnectionTLS.configuration(for: config(.verifyCA, ssl: SSLFiles(caCertificatePath: garbage)))
        }
    }

    @Test func serverNameSkipsIPAddresses() {
        #expect(ConnectionEndpoint.serverName(for: "db.example.com") == "db.example.com")
        #expect(ConnectionEndpoint.serverName(for: "10.1.2.3") == nil)
        #expect(ConnectionEndpoint.serverName(for: "::1") == nil)
    }
}

@Suite struct ConnectionEndpointTests {
    @Test func directTCPAndSocketFiles() throws {
        let tcp = ConnectionEndpoint.direct(for: ConnectionConfig(kind: .postgresql, host: "db.example.com", port: 6543))
        #expect(tcp.address == .tcp(host: "db.example.com", port: 6543) && tcp.tlsServerName == "db.example.com" && tcp.usesTLS)

        let directory = FileManager.default.temporaryDirectory.appending(path: "bg-sock-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var pg = ConnectionConfig(kind: .postgresql, host: "ignored", port: 5433)
        pg.socketPath = directory
        let socket = ConnectionEndpoint.direct(for: pg)
        #expect(socket.address == .unixSocket(path: directory + "/.s.PGSQL.5433") && !socket.usesTLS && socket.tlsServerName == nil)

        var mysql = ConnectionConfig(kind: .mysql, host: "ignored")
        mysql.socketPath = "/tmp/mysql.sock"
        #expect(ConnectionEndpoint.direct(for: mysql).address == .unixSocket(path: "/tmp/mysql.sock"))
    }

    @Test func tunnelRejectsSocketFilesAndMissingFields() async throws {
        var config = ConnectionConfig(kind: .postgresql, host: "db")
        config.ssh = SSHTunnelConfig(enabled: true, host: "jump", username: "ops")
        config.socketPath = "/tmp"
        await #expect(throws: SSHTunnelError.socketNotSupported) { try await ConnectionEndpoint.open(for: config, sshSecret: nil) }
        config.socketPath = nil
        config.ssh?.host = ""
        await #expect(throws: SSHTunnelError.missingHost) { try await ConnectionEndpoint.open(for: config, sshSecret: nil) }
        config.ssh = SSHTunnelConfig(enabled: true, host: "jump", username: "ops", authMethod: .publicKey)
        await #expect(throws: SSHTunnelError.missingPrivateKey) { try await ConnectionEndpoint.open(for: config, sshSecret: nil) }
        #expect(await SSHTunnelManager.shared.openTunnelCount == 0)
    }

    @Test func unreachableSSHServerFailsClearly() async throws {
        let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString).json"))
        let manager = SSHTunnelManager(knownHosts: store)
        let ssh = SSHTunnelConfig(enabled: true, host: "127.0.0.1", port: 1, username: "nobody", authMethod: .password)
        do {
            _ = try await manager.acquire(ssh: ssh, secret: "x", target: .init(host: "db", port: 5432))
            Issue.record("expected an error")
        } catch let error as SSHTunnelError {
            guard case .unreachable(let host, let port, _) = error else { Issue.record("got \(error)"); return }
            #expect(host == "127.0.0.1" && port == 1)
            #expect(error.errorDescription?.hasPrefix("SSH: could not reach 127.0.0.1:1") == true)
        }
        #expect(await manager.openTunnelCount == 0)
    }
}

@Suite struct SSHKeyTests {
    @Test func readsOpenSSHKeys() throws {
        _ = try SSHCredentials.authenticationMethod(username: "u", privateKey: Fixtures.ed25519, passphrase: nil)
        _ = try SSHCredentials.authenticationMethod(username: "u", privateKey: Fixtures.ed25519Encrypted, passphrase: "secret")
        #expect(!SSHCredentials.isEncryptedOpenSSHKey(Fixtures.ed25519))
        #expect(SSHCredentials.isEncryptedOpenSSHKey(Fixtures.ed25519Encrypted))
    }

    @Test func explainsPassphraseAndFormatProblems() throws {
        #expect(throws: SSHTunnelError.passphraseRequired) {
            try SSHCredentials.authenticationMethod(username: "u", privateKey: Fixtures.ed25519Encrypted, passphrase: nil)
        }
        #expect(throws: SSHTunnelError.wrongPassphrase) {
            try SSHCredentials.authenticationMethod(username: "u", privateKey: Fixtures.ed25519Encrypted, passphrase: "wrong")
        }
        #expect(throws: SSHTunnelError.self) {
            try SSHCredentials.authenticationMethod(username: "u", privateKey: Fixtures.ed25519Public, passphrase: nil)
        }
        #expect(throws: SSHTunnelError.self) {
            try SSHCredentials.authenticationMethod(username: "u", privateKey: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----", passphrase: nil)
        }
    }

    @Test func readsTheKeyFileFromTheConfig() throws {
        let path = try Fixtures.file(Fixtures.ed25519, name: "id_ed25519")
        let ssh = SSHTunnelConfig(enabled: true, host: "h", username: "u", authMethod: .publicKey, privateKeyPath: path)
        _ = try SSHCredentials.authenticationMethod(for: ssh, secret: nil)
        var missing = ssh
        missing.privateKeyPath = "/nonexistent/id_ed25519"
        #expect(throws: SSHTunnelError.self) { try SSHCredentials.authenticationMethod(for: missing, secret: nil) }
    }
}

@Suite struct KnownHostsTests {
    @Test func fingerprintMatchesSSHKeygen() throws {
        let key = try #require(SSHHostKey(host: "h:22", openSSHLine: Fixtures.ed25519Public))
        #expect(key.fingerprint == Fixtures.ed25519Fingerprint)
        #expect(key.typeName == "ED25519" && key.algorithm == "ssh-ed25519")
        #expect(SSHHostKey(host: "h:22", openSSHLine: "garbage") == nil)
    }

    @Test func trustsOnFirstUseAndCatchesChanges() throws {
        let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString).json"))
        let id = SSHHostKey.hostID(host: "Bastion.example.com", port: 22)
        #expect(id == "bastion.example.com:22")
        let key = try #require(SSHHostKey(host: id, openSSHLine: Fixtures.ed25519Public))
        #expect(store.verify(key) == .new)
        #expect(store.verify(key) == .trusted)
        #expect(store.key(forHost: "bastion.example.com", port: 22)?.fingerprint == Fixtures.ed25519Fingerprint)

        let other = SSHHostKey(host: id, algorithm: "ssh-ed25519", publicKey: Data(repeating: 7, count: 51).base64EncodedString())
        guard case .mismatch(let expected) = store.verify(other) else { Issue.record("expected a mismatch"); return }
        #expect(expected.publicKey == key.publicKey)
        // A reload from disk sees the same.
        #expect(KnownHostsStore(fileURL: store.fileURL).verify(key) == .trusted)

        store.forget(host: "bastion.example.com", port: 22)
        #expect(store.key(forHost: "bastion.example.com", port: 22) == nil)
        #expect(store.verify(other) == .new)
    }
}
