import CryptoKit
import Foundation
import NIOConcurrencyHelpers

/// An SSH server's host key, as remembered on first use.
public struct SSHHostKey: Codable, Hashable, Sendable {
    /// `host:port` the key was presented by (host lowercased).
    public var host: String
    /// Key type, e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`.
    public var algorithm: String
    /// Base64 of the key in SSH wire format (the second field of an OpenSSH public key line).
    public var publicKey: String
    public var firstSeen: Date

    public init(host: String, algorithm: String, publicKey: String, firstSeen: Date = Date()) {
        self.host = host
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.firstSeen = firstSeen
    }

    /// Parses an OpenSSH public key line (`ssh-ed25519 AAAA… comment`).
    public init?(host: String, openSSHLine: String, firstSeen: Date = Date()) {
        let fields = openSSHLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, Data(base64Encoded: String(fields[1])) != nil else { return nil }
        self.init(host: host, algorithm: String(fields[0]), publicKey: String(fields[1]), firstSeen: firstSeen)
    }

    /// OpenSSH's fingerprint: `SHA256:` and the unpadded base64 of the key blob's SHA-256, as `ssh-keygen -l` prints it.
    public var fingerprint: String {
        let blob = Data(base64Encoded: publicKey) ?? Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Short key type for the UI: ED25519, RSA, ECDSA.
    public var typeName: String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": "RSA"
        case let a where a.hasPrefix("ecdsa-"): "ECDSA"
        default: algorithm
        }
    }

    /// Identifier of an SSH server in the store.
    public static func hostID(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}

/// Trust-on-first-use store of SSH host keys, kept as JSON in the data directory (`ssh-known-hosts.json`).
/// The first key a server presents is saved; a different key later fails the connection until it is forgotten.
public struct KnownHostsStore: Sendable {
    public enum Verdict: Equatable, Sendable {
        case trusted
        /// Never seen: the key was saved.
        case new
        case mismatch(expected: SSHHostKey)
    }

    public let fileURL: URL
    /// Serializes read-modify-write across tunnels opening at the same time.
    private static let lock = NIOLock()

    public init(fileURL: URL = KnownHostsStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `ssh-known-hosts.json` in `BUNNYGRID_DATA_DIR`, else in Application Support/BunnyGrid (next to connections.json).
    public static var defaultFileURL: URL {
        let directory: URL
        if let dir = ProcessInfo.processInfo.environment["BUNNYGRID_DATA_DIR"], !dir.isEmpty {
            directory = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            directory = ConnectionStore.defaultFileURL.deletingLastPathComponent()
        }
        return directory.appending(path: "ssh-known-hosts.json")
    }

    public func all() -> [SSHHostKey] {
        Self.lock.withLock { load() }
    }

    public func key(forHost host: String, port: Int) -> SSHHostKey? {
        let id = SSHHostKey.hostID(host: host, port: port)
        return all().first { $0.host == id }
    }

    /// Checks a presented key and remembers it if the host is new.
    public func verify(_ key: SSHHostKey) -> Verdict {
        Self.lock.withLock {
            var keys = load()
            if let known = keys.first(where: { $0.host == key.host }) {
                return known.algorithm == key.algorithm && known.publicKey == key.publicKey ? .trusted : .mismatch(expected: known)
            }
            keys.append(key)
            save(keys)
            return .new
        }
    }

    /// Forgets a host's key so the next connection trusts whatever it presents.
    public func forget(host: String, port: Int) {
        let id = SSHHostKey.hostID(host: host, port: port)
        Self.lock.withLock {
            save(load().filter { $0.host != id })
        }
    }

    private func load() -> [SSHHostKey] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SSHHostKey].self, from: data)) ?? []
    }

    private func save(_ keys: [SSHHostKey]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(keys).write(to: fileURL, options: .atomic)
    }
}
