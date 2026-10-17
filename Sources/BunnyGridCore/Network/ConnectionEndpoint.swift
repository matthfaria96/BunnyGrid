import Foundation

/// Shares SSH tunnels between the drivers of a connection (PostgreSQL opens one driver per database,
/// table tabs open their own for transactions). A tunnel closes when its last driver disconnects.
public actor SSHTunnelManager {
    public static let shared = SSHTunnelManager()

    struct Key: Hashable, Sendable {
        var ssh: SSHTunnelConfig
        var secret: String?
        var target: SSHTunnel.Target
    }

    private struct Entry {
        let id: UUID
        let task: Task<SSHTunnel, any Error>
        var leases: Int
    }

    /// Where host keys are remembered (trust on first use).
    public let knownHosts: KnownHostsStore
    private var entries: [Key: Entry] = [:]

    public init(knownHosts: KnownHostsStore = KnownHostsStore()) {
        self.knownHosts = knownHosts
    }

    /// A tunnel to `target` through `ssh`, opening one if needed. Pair every lease with `release`.
    public func acquire(ssh: SSHTunnelConfig, secret: String?, target: SSHTunnel.Target) async throws -> SSHTunnelLease {
        let key = Key(ssh: ssh, secret: secret, target: target)
        if let entry = entries[key] {
            let tunnel = try await entry.task.value
            if await tunnel.isAlive, entries[key]?.id == entry.id {
                entries[key]?.leases += 1
                return SSHTunnelLease(key: key, entryID: entry.id, tunnel: tunnel)
            }
            // The SSH session dropped: open a fresh one; drivers still on the old one fail and reconnect.
            if entries[key]?.id == entry.id { entries[key] = nil }
            await tunnel.close()
        }
        let id = UUID()
        let knownHosts = knownHosts
        let task = Task { try await SSHTunnel.open(ssh: ssh, secret: secret, target: target, knownHosts: knownHosts) }
        entries[key] = Entry(id: id, task: task, leases: 1)
        do {
            let tunnel = try await task.value
            return SSHTunnelLease(key: key, entryID: id, tunnel: tunnel)
        } catch {
            if entries[key]?.id == id { entries[key] = nil }
            throw error
        }
    }

    public func release(_ lease: SSHTunnelLease) async {
        guard var entry = entries[lease.key], entry.id == lease.entryID else {
            await lease.tunnel.close()
            return
        }
        entry.leases -= 1
        if entry.leases > 0 {
            entries[lease.key] = entry
        } else {
            entries[lease.key] = nil
            await lease.tunnel.close()
        }
    }

    /// Number of open tunnels, for tests.
    public var openTunnelCount: Int { entries.count }
}

public struct SSHTunnelLease: Sendable {
    let key: SSHTunnelManager.Key
    let entryID: UUID
    public let tunnel: SSHTunnel

    public var localPort: Int { tunnel.localPort }
}

/// Where a driver actually opens its socket: straight to host:port, a Unix socket file, or the local end of an
/// SSH tunnel. Drivers open one in `connect()` and close it in `disconnect()`.
public struct ConnectionEndpoint: Sendable {
    public enum Address: Equatable, Sendable {
        case tcp(host: String, port: Int)
        case unixSocket(path: String)
    }

    public let address: Address
    /// Name checked against the server certificate and sent as SNI: the database host, also through a tunnel.
    /// nil for IP addresses and sockets.
    public let tlsServerName: String?
    public let lease: SSHTunnelLease?

    public var usesTLS: Bool {
        if case .tcp = address { true } else { false }
    }

    public init(address: Address, tlsServerName: String?, lease: SSHTunnelLease? = nil) {
        self.address = address
        self.tlsServerName = tlsServerName
        self.lease = lease
    }

    /// The direct (tunnel-less) endpoint for a config.
    public static func direct(for config: ConnectionConfig) -> ConnectionEndpoint {
        if let socket = config.activeSocketPath {
            return ConnectionEndpoint(address: .unixSocket(path: socketFile(socket, kind: config.kind, port: config.port)), tlsServerName: nil)
        }
        return ConnectionEndpoint(address: .tcp(host: config.host, port: config.port), tlsServerName: serverName(for: config.host))
    }

    public static func open(for config: ConnectionConfig, sshSecret: String?, tunnels: SSHTunnelManager = .shared) async throws -> ConnectionEndpoint {
        guard let ssh = config.activeSSH else { return direct(for: config) }
        if config.activeSocketPath != nil { throw SSHTunnelError.socketNotSupported }
        let lease = try await tunnels.acquire(ssh: ssh, secret: sshSecret, target: SSHTunnel.Target(host: config.host, port: config.port))
        return ConnectionEndpoint(address: .tcp(host: "127.0.0.1", port: lease.localPort), tlsServerName: serverName(for: config.host), lease: lease)
    }

    public func close(tunnels: SSHTunnelManager = .shared) async {
        if let lease { await tunnels.release(lease) }
    }

    /// libpq takes the socket's directory (`/tmp`) and adds `.s.PGSQL.<port>`; MySQL takes the file itself.
    static func socketFile(_ path: String, kind: DatabaseKind, port: Int) -> String {
        var isDirectory: ObjCBool = false
        if kind == .postgresql, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return (path as NSString).appendingPathComponent(".s.PGSQL.\(port)")
        }
        return path
    }

    /// SNI and hostname checks need a DNS name; IP literals are left out.
    static func serverName(for host: String) -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return nil }
        return host
    }
}
