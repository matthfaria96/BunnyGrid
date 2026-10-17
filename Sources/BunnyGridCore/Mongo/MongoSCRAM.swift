import CommonCrypto
import CryptoKit
import Foundation

/// SCRAM-SHA-256 and SCRAM-SHA-1 (RFC 5802 / 7677) as MongoDB uses them. SHA-1 hashes the password as
/// `md5("user:mongo:password")` first. SCRAM-SHA-256 passwords go through SASLprep (RFC 4013), as the MongoDB auth spec asks.
public struct MongoSCRAM: Sendable {
    public enum Mechanism: String, Sendable {
        case sha256 = "SCRAM-SHA-256"
        case sha1 = "SCRAM-SHA-1"
    }

    public let mechanism: Mechanism
    let username: String
    let password: String
    let clientNonce: String
    private(set) var clientFirstBare = ""
    private(set) var serverSignature: [UInt8] = []

    public init(mechanism: Mechanism, username: String, password: String, clientNonce: String? = nil) {
        self.mechanism = mechanism
        self.username = username
        self.password = password
        self.clientNonce = clientNonce ?? Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    public mutating func clientFirst() -> String {
        clientFirstBare = "n=\(Self.escape(username)),r=\(clientNonce)"
        return "n,," + clientFirstBare
    }

    public enum SCRAMError: LocalizedError, Equatable {
        case badServerMessage
        case nonceMismatch
        case badServerSignature

        public var errorDescription: String? {
            switch self {
            case .badServerMessage: "Authentication failed: unexpected SCRAM message from the server."
            case .nonceMismatch: "Authentication failed: the server nonce doesn't match."
            case .badServerSignature: "Authentication failed: the server signature is wrong."
            }
        }
    }

    static func attributes(_ message: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    /// The client-final message for the server-first message.
    public mutating func clientFinal(serverFirst: String) throws -> String {
        let attrs = Self.attributes(serverFirst)
        guard let nonce = attrs["r"], let saltText = attrs["s"], let salt = Data(base64Encoded: saltText),
              let iterations = attrs["i"].flatMap(Int.init), iterations > 0 else { throw SCRAMError.badServerMessage }
        guard nonce.hasPrefix(clientNonce) else { throw SCRAMError.nonceMismatch }
        let secret = mechanism == .sha1 ? Self.md5Hex("\(username):mongo:\(password)") : try Self.saslPrep(password)
        let salted = Self.pbkdf2(password: Array(secret.utf8), salt: [UInt8](salt), iterations: iterations, sha256: mechanism == .sha256)
        let clientKey = hmac(salted, Array("Client Key".utf8))
        let storedKey = hash(clientKey)
        let withoutProof = "c=biws,r=\(nonce)"
        let authMessage = Array("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let signature = hmac(storedKey, authMessage)
        let proof = zip(clientKey, signature).map { $0 ^ $1 }
        let serverKey = hmac(salted, Array("Server Key".utf8))
        serverSignature = hmac(serverKey, authMessage)
        return "\(withoutProof),p=\(Data(proof).base64EncodedString())"
    }

    public func verify(serverFinal: String) throws {
        let attrs = Self.attributes(serverFinal)
        if let error = attrs["e"] { throw DatabaseError.connectionFailed("Authentication failed: \(error)") }
        guard let v = attrs["v"], let data = Data(base64Encoded: v), [UInt8](data) == serverSignature else {
            throw SCRAMError.badServerSignature
        }
    }

    private func hmac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        let key = SymmetricKey(data: key)
        switch mechanism {
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
    }

    private func hash(_ data: [UInt8]) -> [UInt8] {
        switch mechanism {
        case .sha256: Array(SHA256.hash(data: data))
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        }
    }

    /// SASLprep (RFC 4013, the stringprep profile of RFC 3454): non-ASCII spaces become U+0020, characters
    /// "commonly mapped to nothing" go away, the result is NFKC-normalised, and prohibited or unassigned-looking
    /// code points (controls, private use, surrogates, non-characters, tagging) and bad bidi mixes are refused.
    public static func saslPrep(_ text: String) throws -> String {
        if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return text }
        var mapped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if [0x00A0, 0x1680, 0x202F, 0x205F, 0x3000].contains(v) || (0x2000...0x200B).contains(v) {
                mapped.append(" ")
            } else if [0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D, 0x200C, 0x200D, 0x2060, 0xFEFF].contains(v)
                        || (0xFE00...0xFE0F).contains(v) || v == 0x200B {
                continue
            } else {
                mapped.append(scalar)
            }
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping
        var hasRandAL = false, hasL = false
        for scalar in normalized.unicodeScalars {
            let v = scalar.value
            let prohibited = Self.isProhibited(scalar)
            if prohibited { throw DatabaseError.connectionFailed("The password has a character SASLprep forbids (U+\(String(v, radix: 16, uppercase: true))).") }
            if Self.isRandAL(scalar) { hasRandAL = true } else if scalar.properties.isAlphabetic { hasL = true }
        }
        if hasRandAL {
            let scalars = Array(normalized.unicodeScalars)
            if hasL || !Self.isRandAL(scalars.first!) || !Self.isRandAL(scalars.last!) {
                throw DatabaseError.connectionFailed("The password mixes right-to-left and left-to-right text in a way SASLprep forbids.")
            }
        }
        return normalized
    }

    static func isProhibited(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if scalar.properties.generalCategory == .unassigned || (v & 0xFFFE) == 0xFFFE { return true }
        switch v {
        case 0..<0x20, 0x7F...0x9F, 0x06DD, 0x070F, 0x180E, 0x200E...0x200F, 0x202A...0x202E, 0x2028...0x2029,
             0x2060...0x2063, 0x206A...0x206F, 0xFFF9...0xFFFD, 0x1D173...0x1D17A, 0xE000...0xF8FF, 0xF0000...0x10FFFF,
             0xFDD0...0xFDEF, 0x2FF0...0x2FFB, 0xE0001, 0xE0020...0xE007F, 0x0340...0x0341:
            return true
        default:
            return false
        }
    }

    /// Right-to-left letters (RFC 3454 table D.1, by block: Hebrew, Arabic, Syriac, Thaana, NKo… and their presentation forms).
    static func isRandAL(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        guard scalar.properties.isAlphabetic || (0x05BE...0x05C6).contains(v) else { return false }
        return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, sha256: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: sha256 ? 32 : 20)
        let count = out.count
        _ = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1),
                                 UInt32(iterations), &out, count)
        }
        return out
    }
}
