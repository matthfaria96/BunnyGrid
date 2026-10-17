import dnssd
import Foundation

/// MongoDB-only connection settings (Navicat's Connection Type and Authentication fields). The password is in the Keychain.
public struct MongoOptions: Codable, Hashable, Sendable {
    /// `mongodb+srv://`: `host` is a DNS name whose SRV records list the servers (MongoDB Atlas). Turns TLS on.
    public var srv: Bool
    /// Database the user is defined in; empty uses the connection's database, or `admin`.
    public var authSource: String
    /// `SCRAM-SHA-256`, `SCRAM-SHA-1`, or empty to let the server choose.
    public var authMechanism: String
    public var replicaSet: String
    /// More seed servers (`host:port`) besides `host`/`port`, for replica sets.
    public var extraHosts: [String]

    public init(srv: Bool = false, authSource: String = "", authMechanism: String = "", replicaSet: String = "", extraHosts: [String] = []) {
        self.srv = srv
        self.authSource = authSource
        self.authMechanism = authMechanism
        self.replicaSet = replicaSet
        self.extraHosts = extraHosts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        srv = try c.decodeIfPresent(Bool.self, forKey: .srv) ?? false
        authSource = try c.decodeIfPresent(String.self, forKey: .authSource) ?? ""
        authMechanism = try c.decodeIfPresent(String.self, forKey: .authMechanism) ?? ""
        replicaSet = try c.decodeIfPresent(String.self, forKey: .replicaSet) ?? ""
        extraHosts = try c.decodeIfPresent([String].self, forKey: .extraHosts) ?? []
    }
}

/// `mongodb://user:pass@h1:27017,h2/db?authSource=admin&tls=true` and `mongodb+srv://user@cluster.example.net/db`.
public enum MongoConnectionString {
    public struct Host: Hashable, Sendable {
        public var host: String
        public var port: Int
    }

    public static func parse(_ text: String) throws -> ConnectionURI.Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let srv: Bool
        var rest: Substring
        if trimmed.lowercased().hasPrefix("mongodb+srv://") {
            srv = true
            rest = trimmed.dropFirst("mongodb+srv://".count)
        } else if trimmed.lowercased().hasPrefix("mongodb://") {
            srv = false
            rest = trimmed.dropFirst("mongodb://".count)
        } else {
            throw ConnectionURI.ParseError.invalid
        }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[rest.index(after: slash)...])
            rest = rest[..<slash]
        }
        var username = "", password: String?
        if let at = rest.lastIndex(of: "@") {
            let userInfo = rest[..<at]
            rest = rest[rest.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                username = String(userInfo[..<colon]).removingPercentEncoding ?? ""
                password = String(userInfo[userInfo.index(after: colon)...]).removingPercentEncoding
            } else {
                username = String(userInfo).removingPercentEncoding ?? ""
            }
        }
        let hosts = try rest.split(separator: ",").map { try parseHost(String($0)) }
        guard let first = hosts.first, !first.host.isEmpty else { throw ConnectionURI.ParseError.invalid }
        if srv && hosts.count > 1 { throw ConnectionURI.ParseError.invalid }
        var options: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            options[parts[0].lowercased()] = parts.count > 1 ? parts[1] : ""
        }
        var mongo = MongoOptions(srv: srv)
        mongo.authSource = options["authsource"] ?? ""
        mongo.authMechanism = options["authmechanism"] ?? ""
        mongo.replicaSet = options["replicaset"] ?? ""
        mongo.extraHosts = hosts.dropFirst().map { "\($0.host):\($0.port)" }
        let tlsText = options["tls"] ?? options["ssl"]
        var tls: TLSMode = srv ? .require : .prefer
        if let tlsText { tls = tlsText == "true" ? .require : .disable }
        if tls != .disable, options["tlsallowinvalidcertificates"] != "true", options["tlsinsecure"] != "true", tlsText != nil || srv {
            tls = options["tlsallowinvalidhostnames"] == "true" ? .verifyCA : .verifyFull
        }
        var config = ConnectionConfig(kind: .mongodb, host: first.host, port: srv ? 27017 : first.port, username: username,
                                      database: path.removingPercentEncoding ?? path, tls: tls)
        if let ca = options["tlscafile"], !ca.isEmpty { config.ssl = SSLFiles(caCertificatePath: ca) }
        if let cert = options["tlscertificatekeyfile"], !cert.isEmpty {
            var files = config.ssl ?? SSLFiles()
            files.clientCertificatePath = cert
            files.clientKeyPath = cert
            config.ssl = files
        }
        config.mongo = mongo
        return ConnectionURI.Parsed(config: config, password: password)
    }

    static func parseHost(_ text: String) throws -> Host {
        let text = text.removingPercentEncoding ?? text
        if text.hasPrefix("[") , let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            let port = after.hasPrefix(":") ? Int(after.dropFirst()) : 27017
            guard let port else { throw ConnectionURI.ParseError.invalid }
            return Host(host: host, port: port)
        }
        if let colon = text.lastIndex(of: ":") {
            guard let port = Int(text[text.index(after: colon)...]) else { throw ConnectionURI.ParseError.invalid }
            return Host(host: String(text[..<colon]), port: port)
        }
        return Host(host: text, port: 27017)
    }

    /// The connection as a URI, without the password unless given.
    public static func string(for config: ConnectionConfig, password: String? = nil) -> String {
        let mongo = config.mongo ?? MongoOptions()
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
        var out = mongo.srv ? "mongodb+srv://" : "mongodb://"
        if !config.username.isEmpty {
            out += enc(config.username)
            if let password, !password.isEmpty { out += ":" + enc(password) }
            out += "@"
        }
        out += mongo.srv ? config.host : ([ "\(config.host):\(config.port)" ] + mongo.extraHosts).joined(separator: ",")
        out += "/" + config.database
        var items: [String] = []
        if !mongo.authSource.isEmpty { items.append("authSource=\(enc(mongo.authSource))") }
        if !mongo.authMechanism.isEmpty { items.append("authMechanism=\(mongo.authMechanism)") }
        if !mongo.replicaSet.isEmpty { items.append("replicaSet=\(enc(mongo.replicaSet))") }
        switch config.tls {
        case .disable: if mongo.srv { items.append("tls=false") }
        case .prefer: break
        case .require: items.append(contentsOf: ["tls=true", "tlsAllowInvalidCertificates=true"])
        case .verifyCA: if !mongo.srv { items.append("tls=true") }; items.append("tlsAllowInvalidHostnames=true")
        case .verifyFull: if !mongo.srv { items.append("tls=true") }
        }
        if let ca = config.ssl?.caCertificatePath, !ca.isEmpty { items.append("tlsCAFile=\(enc(ca))") }
        if !items.isEmpty { out += "?" + items.joined(separator: "&") }
        return out
    }

    // MARK: - DNS

    /// SRV records of `_mongodb._tcp.<host>`, and the TXT record's options (`authSource`, `replicaSet`).
    public static func resolveSRV(_ host: String, timeout: TimeInterval = 10) async throws -> (hosts: [Host], options: [String: String]) {
        let srv = try await DNSQuery.run(name: "_mongodb._tcp.\(host)", type: UInt16(kDNSServiceType_SRV), timeout: timeout)
        var hosts: [Host] = []
        for record in srv {
            // priority(2) weight(2) port(2) target (DNS labels).
            guard record.count > 7 else { continue }
            let port = Int(record[4]) << 8 | Int(record[5])
            var labels: [String] = []
            var i = 6
            while i < record.count, record[i] != 0 {
                let length = Int(record[i])
                guard i + 1 + length <= record.count else { break }
                labels.append(String(decoding: record[(i + 1)..<(i + 1 + length)], as: UTF8.self))
                i += 1 + length
            }
            let target = labels.joined(separator: ".")
            // The spec requires the servers to share the SRV name's parent domain.
            let parent = host.split(separator: ".").dropFirst().joined(separator: ".")
            guard !target.isEmpty, parent.isEmpty || target.hasSuffix(parent) else { continue }
            hosts.append(Host(host: target, port: port))
        }
        guard !hosts.isEmpty else { throw DatabaseError.connectionFailed("No SRV records found for _mongodb._tcp.\(host).") }
        var options: [String: String] = [:]
        if let txt = try? await DNSQuery.run(name: host, type: UInt16(kDNSServiceType_TXT), timeout: timeout) {
            for record in txt {
                var i = 0
                var text = ""
                while i < record.count {
                    let length = Int(record[i])
                    text += String(decoding: record[min(i + 1, record.count)..<min(i + 1 + length, record.count)], as: UTF8.self)
                    i += 1 + length
                }
                for pair in text.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 { options[parts[0].lowercased()] = parts[1] }
                }
            }
        }
        return (hosts, options)
    }
}

/// A one-shot DNS query through the system resolver (dnssd).
enum DNSQuery {
    private final class Box: @unchecked Sendable {
        var records: [[UInt8]] = []
        var error: Int32 = 0
        var more = true
    }

    static func run(name: String, type: UInt16, timeout: TimeInterval) async throws -> [[UInt8]] {
        try await Task.detached {
            let box = Box()
            var ref: DNSServiceRef?
            let context = Unmanaged.passUnretained(box).toOpaque()
            let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, length, data, _, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if errorCode != kDNSServiceErr_NoError {
                    box.error = errorCode
                    box.more = false
                    return
                }
                if let data, length > 0 {
                    box.records.append(Array(UnsafeRawBufferPointer(start: data, count: Int(length))))
                }
                box.more = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
            }
            let status = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name, type,
                                               UInt16(kDNSServiceClass_IN), callback, context)
            guard status == kDNSServiceErr_NoError, let ref else {
                throw DatabaseError.connectionFailed("DNS lookup of \(name) failed (\(status)).")
            }
            defer { DNSServiceRefDeallocate(ref) }
            let fd = DNSServiceRefSockFD(ref)
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
                if ready > 0 {
                    DNSServiceProcessResult(ref)
                    if !box.records.isEmpty && !box.more { break }
                    if box.error != 0 { break }
                } else if ready < 0 {
                    break
                }
            } while true
            if box.records.isEmpty {
                throw DatabaseError.connectionFailed("DNS lookup of \(name) returned no records\(box.error != 0 ? " (\(box.error))" : "").")
            }
            return box.records
        }.value
    }
}
