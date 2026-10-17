import CryptoKit
import Foundation

/// NTLMv2 ([MS-NLMP]) without SSPI, for SQL Server Windows Authentication with `DOMAIN\user` and a password:
/// NEGOTIATE goes in LOGIN7's SSPI field, the server's CHALLENGE comes back in an SSPI token, and AUTHENTICATE
/// goes in an SSPI message. No signing or sealing is negotiated (TDS doesn't use them), so there is no session key
/// exchange and no MIC.
public struct NTLMClient: Sendable {
    public var user: String
    public var domain: String
    public var password: String
    public var workstation: String

    /// `DOMAIN\user`, `user@domain` (sent as a UPN with an empty domain) or a bare user name.
    public init(account: String, password: String, workstation: String = "") {
        if let slash = account.firstIndex(of: "\\") {
            domain = String(account[..<slash])
            user = String(account[account.index(after: slash)...])
        } else {
            domain = ""
            user = account
        }
        self.password = password
        self.workstation = workstation
    }

    static let signature: [UInt8] = Array("NTLMSSP".utf8) + [0]

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt32
        static let unicode = Flags(rawValue: 0x0000_0001)
        static let requestTarget = Flags(rawValue: 0x0000_0004)
        static let ntlm = Flags(rawValue: 0x0000_0200)
        static let alwaysSign = Flags(rawValue: 0x0000_8000)
        static let extendedSessionSecurity = Flags(rawValue: 0x0008_0000)
        static let targetInfo = Flags(rawValue: 0x0080_0000)
        static let version = Flags(rawValue: 0x0200_0000)
        static let bits128 = Flags(rawValue: 0x2000_0000)
        static let bits56 = Flags(rawValue: 0x8000_0000)

        static let client: Flags = [.unicode, .requestTarget, .ntlm, .alwaysSign, .extendedSessionSecurity, .targetInfo, .version, .bits128, .bits56]
    }

    /// Windows 10 / NTLM revision 15, as most clients send it.
    static let versionBytes: [UInt8] = [10, 0, 0x5A, 0x29, 0, 0, 0, 15]

    public func negotiate() -> [UInt8] {
        var out = Self.signature
        out += le(UInt32(1))
        out += le(Flags.client.rawValue)
        out += [UInt8](repeating: 0, count: 16) // domain and workstation fields: empty
        out += Self.versionBytes
        return out
    }

    public struct Challenge: Equatable, Sendable {
        public var flags: UInt32
        public var serverChallenge: [UInt8]
        public var targetInfo: [UInt8]

        /// MsvAvTimestamp (7) from the target info, when the server sent one.
        public var timestamp: [UInt8]? {
            var i = 0
            while i + 4 <= targetInfo.count {
                let id = UInt16(targetInfo[i]) | UInt16(targetInfo[i + 1]) << 8
                let length = Int(targetInfo[i + 2]) | Int(targetInfo[i + 3]) << 8
                if id == 0 || i + 4 + length > targetInfo.count { return nil }
                if id == 7, length == 8 { return Array(targetInfo[(i + 4)..<(i + 12)]) }
                i += 4 + length
            }
            return nil
        }
    }

    public static func parseChallenge(_ bytes: [UInt8]) throws -> Challenge {
        guard bytes.count >= 48, Array(bytes[0..<8]) == signature, u32(bytes, 8) == 2 else {
            throw TDSError.protocolViolation("not an NTLM challenge")
        }
        let flags = u32(bytes, 20)
        let challenge = Array(bytes[24..<32])
        let infoLength = Int(u16(bytes, 40)), infoOffset = Int(u32(bytes, 44))
        guard infoOffset + infoLength <= bytes.count else { throw TDSError.protocolViolation("bad NTLM target info") }
        return Challenge(flags: flags, serverChallenge: challenge, targetInfo: Array(bytes[infoOffset..<(infoOffset + infoLength)]))
    }

    /// NTOWFv2: HMAC-MD5(MD4(UTF-16LE(password)), UTF-16LE(UPPER(user) + domain)).
    public static func ntowfv2(password: String, user: String, domain: String) -> [UInt8] {
        hmacMD5(MD4.hash(utf16(password)), utf16(user.uppercased() + domain))
    }

    /// The NTLMv2 responses for a challenge. `clientChallenge` and `time` (FILETIME, little-endian) are random and now
    /// unless given (tests use the spec's values).
    public func responses(_ challenge: Challenge, clientChallenge: [UInt8]? = nil, time: [UInt8]? = nil)
        -> (lm: [UInt8], nt: [UInt8], ntProof: [UInt8], sessionBaseKey: [UInt8]) {
        let key = Self.ntowfv2(password: password, user: user, domain: domain)
        let client = clientChallenge ?? (0..<8).map { _ in UInt8.random(in: 0...255) }
        let stamp = time ?? challenge.timestamp ?? Self.fileTime(Date())
        let temp: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 0] + stamp + client + [0, 0, 0, 0] + challenge.targetInfo + [0, 0, 0, 0]
        let proof = Self.hmacMD5(key, challenge.serverChallenge + temp)
        // With a server timestamp, the LM response is zeros ([MS-NLMP] 3.1.5.1.2).
        let lm = challenge.timestamp != nil && time == nil
            ? [UInt8](repeating: 0, count: 24)
            : Self.hmacMD5(key, challenge.serverChallenge + client) + client
        return (lm, proof + temp, proof, Self.hmacMD5(key, proof))
    }

    public func authenticate(_ challenge: Challenge, clientChallenge: [UInt8]? = nil, time: [UInt8]? = nil) -> [UInt8] {
        let r = responses(challenge, clientChallenge: clientChallenge, time: time)
        let payloads = [r.lm, r.nt, Self.utf16(domain), Self.utf16(user), Self.utf16(workstation), []]
        var offset = 72
        var header = Self.signature + le(UInt32(3))
        var body: [UInt8] = []
        for payload in payloads {
            header += le(UInt16(payload.count)) + le(UInt16(payload.count)) + le(UInt32(offset))
            body += payload
            offset += payload.count
        }
        let flags = Flags.client.rawValue & (challenge.flags | Flags.version.rawValue)
        header += le(flags)
        header += Self.versionBytes
        return header + body
    }

    // MARK: Helpers

    static func fileTime(_ date: Date) -> [UInt8] {
        le(UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
    }

    static func hmacMD5(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func utf16(_ text: String) -> [UInt8] { TDSLogin7.utf16(text) }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * $1) } }
}

private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

/// MD4 (RFC 1320), only for the NT hash; CommonCrypto's is deprecated.
enum MD4 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var a: UInt32 = 0x6745_2301, b: UInt32 = 0xEFCD_AB89, c: UInt32 = 0x98BA_DCFE, d: UInt32 = 0x1032_5476
        var data = message + [0x80]
        while data.count % 64 != 56 { data.append(0) }
        data += le(UInt64(message.count) &* 8)
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            let x = (0..<16).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[chunk + i * 4 + $1]) << (8 * $1) } }
            let (aa, bb, cc, dd) = (a, b, c, d)
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
            func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
            for i in 0..<16 {
                let s: [UInt32] = [3, 7, 11, 19]
                let t = rotl(a &+ f(b, c, d) &+ x[i], s[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            for i in 0..<16 {
                let s: [UInt32] = [3, 5, 9, 13]
                let k = (i % 4) * 4 + i / 4
                let t = rotl(a &+ g(b, c, d) &+ x[k] &+ 0x5A82_7999, s[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            let order = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            for i in 0..<16 {
                let s: [UInt32] = [3, 9, 11, 15]
                let t = rotl(a &+ h(b, c, d) &+ x[order[i]] &+ 0x6ED9_EBA1, s[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }
        return le(a) + le(b) + le(c) + le(d)
    }
}
