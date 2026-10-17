import Foundation
import NIOSSL

public enum ConnectionTLSError: LocalizedError, Equatable, Sendable {
    case unreadableFile(what: String, path: String, reason: String)
    case keyWithoutCertificate
    case certificateWithoutKey
    case wrongKeyPassphrase(path: String)
    case serverRefusedSSL(mode: TLSMode)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let what, let path, let reason): "SSL: could not read the \(what) at \(path): \(reason)"
        case .keyWithoutCertificate: "SSL: a client key needs its client certificate too."
        case .certificateWithoutKey: "SSL: a client certificate needs its client key too."
        case .wrongKeyPassphrase(let path): "SSL: wrong or missing passphrase for the client key at \(path)."
        case .serverRefusedSSL(let mode): "SSL: the server doesn't support SSL, and the SSL mode “\(mode.displayName)” requires it."
        }
    }
}

/// Builds the NIOSSL client configuration for a connection's SSL tab (mode, CA, client certificate and key).
public enum ConnectionTLS {
    /// nil when SSL is disabled.
    public static func configuration(for config: ConnectionConfig, keyPassphrase: String? = nil) throws -> TLSConfiguration? {
        guard config.tls != .disable else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = switch config.tls {
        // Same as libpq's prefer/require: encrypt without checking the chain.
        case .disable, .prefer, .require: .none
        case .verifyCA: .noHostnameVerification
        case .verifyFull: .fullVerification
        }
        let files = config.ssl ?? SSLFiles()
        let ca = expand(files.caCertificatePath)
        if !ca.isEmpty {
            tls.trustRoots = .certificates(try certificates(at: ca, what: "CA certificate"))
        }
        let cert = expand(files.clientCertificatePath), key = expand(files.clientKeyPath)
        switch (cert.isEmpty, key.isEmpty) {
        case (true, true): break
        case (false, true): throw ConnectionTLSError.certificateWithoutKey
        case (true, false): throw ConnectionTLSError.keyWithoutCertificate
        case (false, false):
            tls.certificateChain = try certificates(at: cert, what: "client certificate").map { .certificate($0) }
            tls.privateKey = .privateKey(try privateKey(at: key, passphrase: keyPassphrase))
        }
        return tls
    }

    static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : (trimmed as NSString).expandingTildeInPath
    }

    private static func certificates(at path: String, what: String) throws -> [NIOSSLCertificate] {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ConnectionTLSError.unreadableFile(what: what, path: path, reason: "the file doesn't exist or can't be opened")
        }
        let certificates: [NIOSSLCertificate]
        do {
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
            certificates = bytes.starts(with: Array("-----".utf8)) || String(decoding: bytes, as: UTF8.self).contains("-----BEGIN")
                ? try NIOSSLCertificate.fromPEMBytes(bytes)
                : [try NIOSSLCertificate(bytes: bytes, format: .der)]
        } catch {
            throw ConnectionTLSError.unreadableFile(what: what, path: path, reason: "not a PEM or DER certificate")
        }
        guard !certificates.isEmpty else {
            throw ConnectionTLSError.unreadableFile(what: what, path: path, reason: "no certificate in the file")
        }
        return certificates
    }

    private static func privateKey(at path: String, passphrase: String?) throws -> NIOSSLPrivateKey {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ConnectionTLSError.unreadableFile(what: "client key", path: path, reason: "the file doesn't exist or can't be opened")
        }
        let bytes: [UInt8]
        do {
            bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw ConnectionTLSError.unreadableFile(what: "client key", path: path, reason: error.localizedDescription)
        }
        let isPEM = String(decoding: bytes, as: UTF8.self).contains("-----BEGIN")
        let format: NIOSSLSerializationFormats = isPEM ? .pem : .der
        let encrypted = String(decoding: bytes, as: UTF8.self).contains("ENCRYPTED")
        do {
            if let passphrase, !passphrase.isEmpty {
                return try NIOSSLPrivateKey(bytes: bytes, format: format) { setter in setter(Array(passphrase.utf8)) }
            }
            if encrypted { throw ConnectionTLSError.wrongKeyPassphrase(path: path) }
            return try NIOSSLPrivateKey(bytes: bytes, format: format)
        } catch let error as ConnectionTLSError {
            throw error
        } catch {
            if encrypted { throw ConnectionTLSError.wrongKeyPassphrase(path: path) }
            throw ConnectionTLSError.unreadableFile(what: "client key", path: path, reason: "not a PEM or DER private key")
        }
    }
}

/// Readable messages for errors thrown while opening a connection (sockets, TLS handshakes).
public enum ConnectionErrorText {
    public static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription,
           error is SSHTunnelError || error is ConnectionTLSError || error is DatabaseError {
            return text
        }
        if let error = error as? NIOSSLError {
            switch error {
            case .handshakeFailed(let inner):
                let detail = String(describing: inner)
                if detail.contains("CERTIFICATE_VERIFY_FAILED") {
                    return "SSL: the server certificate could not be verified. Choose the CA certificate that signed it in the SSL tab, or use the mode Require."
                }
                return "SSL handshake failed: \(detail)"
            case .unableToValidateCertificate:
                return "SSL: the server certificate could not be verified. Choose the CA certificate in the SSL tab, or use the mode Require."
            default:
                return "SSL: \(error)"
            }
        }
        if let error = error as? NIOSSLExtraError {
            if error == .failedToValidateHostname {
                return "SSL: the server certificate doesn't match the host name (\(error)). Use Verify CA, or connect with the name in the certificate."
            }
            return "SSL: \(error)"
        }
        if let error = error as? BoringSSLError {
            return "SSL: \(error)"
        }
        let text = String(describing: error)
        if text.contains("connectTimeout") { return "Timed out connecting to the server." }
        if text.contains("Connection refused") || text.contains("ECONNREFUSED") { return "The server refused the connection (\(text)). Check the host and port, and that the server is running." }
        return text
    }
}
