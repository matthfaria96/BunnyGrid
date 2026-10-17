import CommonCrypto
import CryptoKit
import Foundation

/// SCRAM-SHA-256 and SCRAM-SHA-1 (RFC 5802 / 7677) as MongoDB uses them. SHA-1 hashes the password as
/// `md5("user:mongo:password")` first. Passwords are used as given (no SASLprep beyond ASCII).
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
        let secret = mechanism == .sha1 ? Self.md5Hex("\(username):mongo:\(password)") : password
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
