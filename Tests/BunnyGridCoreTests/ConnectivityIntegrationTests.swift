import Foundation
import PostgresNIO
import Testing
@testable import BunnyGridCore

/// SSL, socket-file and SSH tunnel tests against real servers. Skipped unless the variables are set:
///
/// - `BUNNYGRID_TLS_PG_PORT`, `BUNNYGRID_TLS_PG_USER`: a PostgreSQL with `ssl = on` on 127.0.0.1, whose certificate
///   (CN/SAN `localhost`) is signed by `$BUNNYGRID_TLS_PG_CERTS/ca.crt`. The directory also holds `other-ca.crt`
///   (signed nothing), and `client.crt` / `client.key` / `client-enc.key` (passphrase `keypass`) for the role
///   `certuser`, which pg_hba only lets in with `hostssl … cert`.
/// - `BUNNYGRID_PG_SOCKET_DIR`: the server's `unix_socket_directories`.
/// - `BUNNYGRID_SSH_PORT`, `BUNNYGRID_SSH_USER`, `BUNNYGRID_SSH_KEYS`: an sshd on 127.0.0.1 that accepts the keys
///   `user_ed25519` (passphrase `bunny pass`), `user_ecdsa` (OpenSSH format), `user_ecdsa_pem` (`ssh-keygen -m PEM`)
///   and `user_rsa` in that directory, and no passwords. `BUNNYGRID_SSH_RSA_PORT`: the same with `+ssh-rsa` allowed.
///   A user-level `sshd -D -f <config>` on a high port works when Remote Login is off.
private enum Env {
    static let env = ProcessInfo.processInfo.environment
    static let pgPort = Int(env["BUNNYGRID_TLS_PG_PORT"] ?? "")
    static let pgUser = env["BUNNYGRID_TLS_PG_USER"] ?? "postgres"
    static let certs = env["BUNNYGRID_TLS_PG_CERTS"] ?? ""
    static let socketDir = env["BUNNYGRID_PG_SOCKET_DIR"]
    static let sshPort = Int(env["BUNNYGRID_SSH_PORT"] ?? "")
    static let sshUser = env["BUNNYGRID_SSH_USER"] ?? NSUserName()
    static let sshKeys = env["BUNNYGRID_SSH_KEYS"] ?? ""
    static let sshRSAPort = Int(env["BUNNYGRID_SSH_RSA_PORT"] ?? "")

    static var tlsEnabled: Bool { pgPort != nil && !certs.isEmpty }
    static var sshEnabled: Bool { pgPort != nil && sshPort != nil && !sshKeys.isEmpty }

    static func pg(_ mode: TLSMode, host: String = "localhost", user: String? = nil, ssl: SSLFiles? = nil) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .postgresql, host: host, port: pgPort ?? 5432, username: user ?? pgUser, database: "postgres", tls: mode)
        config.ssl = ssl
        return config
    }

    static func cert(_ name: String) -> String { (certs as NSString).appendingPathComponent(name) }
    static func key(_ name: String) -> String { (sshKeys as NSString).appendingPathComponent(name) }

    static func ssh(key: String) -> SSHTunnelConfig {
        SSHTunnelConfig(enabled: true, host: "127.0.0.1", port: sshPort ?? 22, username: sshUser, authMethod: .publicKey, privateKeyPath: Env.key(key))
    }

    static func temporaryKnownHosts() -> KnownHostsStore {
        KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "known-hosts-\(UUID().uuidString).json"))
    }
}

/// Runs `SELECT 1` and whether the session is encrypted.
private func probe(_ driver: PostgresDriver) async throws -> (one: String, ssl: String) {
    let row = try await driver.executeStatement("SELECT 1, (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())::text").rows.first
    return (row?[0].displayString ?? "", row?[1].displayString ?? "")
}

private func connectError(_ config: ConnectionConfig, secrets: ConnectionSecrets = .init()) async -> String? {
    let driver = PostgresDriver(config: config, secrets: secrets)
    do {
        try await driver.connect()
        await driver.disconnect()
        return nil
    } catch {
        return error.localizedDescription
    }
}

@Suite(.enabled(if: Env.tlsEnabled, "set BUNNYGRID_TLS_PG_PORT and BUNNYGRID_TLS_PG_CERTS"), .serialized)
struct PostgresSSLIntegrationTests {
    @Test func everyModeConnectsWithTheRightCA() async throws {
        let ca = SSLFiles(caCertificatePath: Env.cert("ca.crt"))
        for (mode, encrypted) in [(TLSMode.disable, "false"), (.prefer, "true"), (.require, "true"), (.verifyCA, "true"), (.verifyFull, "true")] {
            let driver = PostgresDriver(config: Env.pg(mode, ssl: ca), password: nil)
            try await driver.connect()
            let result = try await probe(driver)
            #expect(result.one == "1")
            #expect(result.ssl == encrypted, "mode \(mode)")
            await driver.disconnect()
        }
    }

    @Test func verificationFailuresAreExplained() async throws {
        let wrongCA = try #require(await connectError(Env.pg(.verifyCA, ssl: SSLFiles(caCertificatePath: Env.cert("other-ca.crt")))))
        #expect(wrongCA.contains("could not be verified"), "\(wrongCA)")
        // The certificate also names 127.0.0.1 (an IP SAN), checked against the peer address.
        #expect(await connectError(Env.pg(.verifyFull, host: "127.0.0.1", ssl: SSLFiles(caCertificatePath: Env.cert("ca.crt")))) == nil)
        // Require ignores the CA entirely.
        #expect(await connectError(Env.pg(.require, ssl: SSLFiles(caCertificatePath: Env.cert("other-ca.crt")))) == nil)
    }

    @Test func clientCertificateAuthentication() async throws {
        let files = SSLFiles(caCertificatePath: Env.cert("ca.crt"), clientCertificatePath: Env.cert("client.crt"), clientKeyPath: Env.cert("client.key"))
        let driver = PostgresDriver(config: Env.pg(.verifyFull, user: "certuser", ssl: files), password: nil)
        try await driver.connect()
        #expect(try await driver.executeStatement("SELECT current_user").rows.first?.first?.displayString == "certuser")
        await driver.disconnect()

        var encrypted = files
        encrypted.clientKeyPath = Env.cert("client-enc.key")
        #expect(await connectError(Env.pg(.verifyFull, user: "certuser", ssl: encrypted), secrets: ConnectionSecrets(sslKeyPassphrase: "keypass")) == nil)
        let missing = try #require(await connectError(Env.pg(.verifyFull, user: "certuser", ssl: encrypted)))
        #expect(missing.contains("passphrase"), "\(missing)")
        let noCert = try #require(await connectError(Env.pg(.require, user: "certuser")))
        #expect(noCert.contains("certificate") || noCert.contains("pg_hba"), "\(noCert)")
    }

    @Test(.enabled(if: Env.socketDir != nil, "set BUNNYGRID_PG_SOCKET_DIR"))
    func connectsThroughTheSocketDirectory() async throws {
        var config = Env.pg(.verifyFull, host: "no-such-host.invalid")
        config.socketPath = Env.socketDir
        let driver = PostgresDriver(config: config, password: nil)
        try await driver.connect()
        // inet_server_addr() is NULL over a Unix socket.
        let row = try await driver.executeStatement("SELECT inet_server_addr() IS NULL").rows.first
        #expect(row?.first?.displayString == "true")
        await driver.disconnect()
    }
}

@Suite(.enabled(if: Env.sshEnabled, "set BUNNYGRID_SSH_PORT, BUNNYGRID_SSH_KEYS and BUNNYGRID_TLS_PG_PORT"), .serialized)
struct SSHTunnelIntegrationTests {
    @Test func tunnelsPostgresWithEveryKeyType() async throws {
        let manager = SSHTunnelManager(knownHosts: Env.temporaryKnownHosts())
        for (key, passphrase) in [("user_ed25519", "bunny pass"), ("user_ecdsa", nil), ("user_ecdsa_pem", nil), ("user_rsa", nil)] as [(String, String?)] {
            var config = Env.pg(.verifyFull, ssl: SSLFiles(caCertificatePath: Env.tlsEnabled ? Env.cert("ca.crt") : ""))
            if !Env.tlsEnabled { config.tls = .prefer }
            config.ssh = Env.ssh(key: key)
            let endpoint: ConnectionEndpoint
            do {
                endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: passphrase, tunnels: manager)
            } catch SSHTunnelError.rsaKeyRejected {
                // Citadel signs RSA with SHA-1; OpenSSH 8.8+ refuses that unless PubkeyAcceptedAlgorithms has +ssh-rsa.
                #expect(key == "user_rsa")
                continue
            }
            guard case .tcp(let host, let port) = endpoint.address else { Issue.record("expected TCP"); return }
            #expect(host == "127.0.0.1" && port != config.port)
            // verify-full checks the certificate against the database host, not 127.0.0.1.
            #expect(endpoint.tlsServerName == "localhost")
            let driver = PostgresDriver(config: config, password: nil)
            let connection = try await driver.openConnection(at: endpoint)
            let rows = try await connection.query("SELECT 1::text", logger: .init(label: "test")).collect()
            #expect(try rows.first?.decode(String.self) == "1", "key \(key)")
            try await connection.close()
            await endpoint.close(tunnels: manager)
        }
        #expect(await manager.openTunnelCount == 0)
    }

    /// RSA keys work when the server still takes SHA-1 signatures (`PubkeyAcceptedAlgorithms +ssh-rsa`).
    @Test(.enabled(if: Env.sshRSAPort != nil, "set BUNNYGRID_SSH_RSA_PORT")) func rsaKeyWhereSSHRSAIsAllowed() async throws {
        let manager = SSHTunnelManager(knownHosts: Env.temporaryKnownHosts())
        var ssh = Env.ssh(key: "user_rsa")
        ssh.port = Env.sshRSAPort ?? 22
        let lease = try await manager.acquire(ssh: ssh, secret: nil, target: .init(host: "127.0.0.1", port: Env.pgPort ?? 5432))
        #expect(lease.localPort > 0)
        await manager.release(lease)
    }

    @Test func sharesOneTunnelPerConnectionAndClosesItWithTheLastDriver() async throws {
        let knownHosts = Env.temporaryKnownHosts()
        let manager = SSHTunnelManager(knownHosts: knownHosts)
        var config = Env.pg(.prefer)
        config.ssh = Env.ssh(key: "user_ecdsa_pem")
        let first = try await ConnectionEndpoint.open(for: config, sshSecret: nil, tunnels: manager)
        let second = try await ConnectionEndpoint.open(for: config, sshSecret: nil, tunnels: manager)
        #expect(first.address == second.address)
        #expect(await manager.openTunnelCount == 1)
        let lease = try #require(first.lease)
        #expect(lease.tunnel.hostKeyWasNew)
        #expect(knownHosts.key(forHost: "127.0.0.1", port: Env.sshPort ?? 22)?.fingerprint == lease.tunnel.hostKey.fingerprint)
        await first.close(tunnels: manager)
        #expect(await manager.openTunnelCount == 1)
        #expect(await lease.tunnel.isAlive)
        await second.close(tunnels: manager)
        #expect(await manager.openTunnelCount == 0)
        #expect(await !lease.tunnel.isAlive)

        // Next time the key is known.
        let again = try await ConnectionEndpoint.open(for: config, sshSecret: nil, tunnels: manager)
        #expect(again.lease?.tunnel.hostKeyWasNew == false)
        await again.close(tunnels: manager)
    }

    @Test func manyConnectionsAndLargeResultsFlowThroughTheTunnel() async throws {
        let manager = SSHTunnelManager(knownHosts: Env.temporaryKnownHosts())
        var config = Env.pg(.disable)
        config.ssh = Env.ssh(key: "user_ecdsa_pem")
        let endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: nil, tunnels: manager)
        let driver = PostgresDriver(config: config, password: nil)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let connection = try await driver.openConnection(at: endpoint)
                    let rows = try await connection.query("SELECT repeat('x', 1000) FROM generate_series(1, 5000)", logger: .init(label: "test")).collect()
                    try await connection.close()
                    return rows.count
                }
            }
            for try await count in group { #expect(count == 5000) }
        }
        await endpoint.close(tunnels: manager)
    }

    @Test func explainsSSHFailures() async throws {
        let knownHosts = Env.temporaryKnownHosts()
        let manager = SSHTunnelManager(knownHosts: knownHosts)
        let target = SSHTunnel.Target(host: "127.0.0.1", port: Env.pgPort ?? 5432)

        await #expect(throws: SSHTunnelError.passphraseRequired) {
            try await manager.acquire(ssh: Env.ssh(key: "user_ed25519"), secret: nil, target: target)
        }
        await #expect(throws: SSHTunnelError.wrongPassphrase) {
            try await manager.acquire(ssh: Env.ssh(key: "user_ed25519"), secret: "wrong", target: target)
        }
        var password = Env.ssh(key: "")
        password.authMethod = .password
        do {
            _ = try await manager.acquire(ssh: password, secret: "nope", target: target)
            Issue.record("password login should fail")
        } catch let error as SSHTunnelError {
            switch error {
            case .passwordNotAccepted, .authenticationFailed: break
            default: Issue.record("got \(error)")
            }
        }
        // Nothing listens on port 1 of the SSH host.
        do {
            _ = try await manager.acquire(ssh: Env.ssh(key: "user_ecdsa_pem"), secret: nil, target: .init(host: "127.0.0.1", port: 1))
            Issue.record("forward should fail")
        } catch let error as SSHTunnelError {
            guard case .forwardRefused(let where_, _) = error else { Issue.record("got \(error)"); return }
            #expect(where_ == "127.0.0.1:1")
        }
        #expect(await manager.openTunnelCount == 0)
    }

    @Test func refusesAChangedHostKey() async throws {
        let knownHosts = Env.temporaryKnownHosts()
        let id = SSHHostKey.hostID(host: "127.0.0.1", port: Env.sshPort ?? 22)
        let impostor = try #require(SSHHostKey(host: id, openSSHLine: Fixtures.ed25519Public))
        #expect(knownHosts.verify(impostor) == .new)
        let manager = SSHTunnelManager(knownHosts: knownHosts)
        do {
            _ = try await manager.acquire(ssh: Env.ssh(key: "user_ecdsa_pem"), secret: nil, target: .init(host: "127.0.0.1", port: Env.pgPort ?? 5432))
            Issue.record("a changed host key must fail")
        } catch let error as SSHTunnelError {
            guard case .hostKeyChanged(_, let expected, _) = error else { Issue.record("got \(error)"); return }
            #expect(expected == Fixtures.ed25519Fingerprint)
            #expect(error.errorDescription?.contains("Forget Host Key") == true)
        }
        knownHosts.forget(host: "127.0.0.1", port: Env.sshPort ?? 22)
        let lease = try await manager.acquire(ssh: Env.ssh(key: "user_ecdsa_pem"), secret: nil, target: .init(host: "127.0.0.1", port: Env.pgPort ?? 5432))
        await manager.release(lease)
    }
}
