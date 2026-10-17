import Foundation
import Testing
@testable import BunnyGridCore

/// MONGODB-X509 against a mongod started with `--tlsMode requireTLS --tlsCAFile … --auth` (`BUNNYGRID_MONGO_X509_PORT`,
/// `_CA`, `_CERT`, `_KEY`; the client certificate's subject is `BUNNYGRID_MONGO_X509_SUBJECT`, default `CN=certuser`).
/// On a fresh server the test creates an admin through the localhost exception, then the `$external` user.
@Suite("MongoDB X.509", .enabled(if: ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_X509_PORT"] != nil))
struct MongoX509IntegrationTests {
    static let env = ProcessInfo.processInfo.environment

    static func config(user: String = "", mechanism: String = "", client: Bool = true) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .mongodb, host: "localhost", port: Int(env["BUNNYGRID_MONGO_X509_PORT"]!), username: user, tls: .verifyFull)
        config.ssl = SSLFiles(caCertificatePath: env["BUNNYGRID_MONGO_X509_CA"] ?? "",
                              clientCertificatePath: client ? env["BUNNYGRID_MONGO_X509_CERT"] ?? "" : "",
                              clientKeyPath: client ? env["BUNNYGRID_MONGO_X509_KEY"] ?? "" : "")
        config.mongo = MongoOptions(authSource: "admin", authMechanism: mechanism)
        return config
    }

    @Test func authenticatesWithTheClientCertificate() async throws {
        let subject = Self.env["BUNNYGRID_MONGO_X509_SUBJECT"] ?? "CN=certuser"
        let bootstrap = MongoDriver(config: Self.config(), secrets: ConnectionSecrets())
        try await bootstrap.connect()
        _ = try? await bootstrap.runCommand(["createUser": .string("x509admin"), "pwd": .string("x509pass"),
                                             "roles": .array([.string("root")])], database: "admin")
        await bootstrap.disconnect()
        let admin = MongoDriver(config: Self.config(user: "x509admin"), secrets: ConnectionSecrets(password: "x509pass"))
        try await admin.connect()
        _ = try? await admin.runCommand(["createUser": .string(subject), "roles": .array([.document(["role": .string("read"), "db": .string("admin")])])],
                                        database: "$external")
        await admin.disconnect()

        let driver = MongoDriver(config: Self.config(mechanism: "MONGODB-X509"), secrets: ConnectionSecrets())
        try await driver.connect()
        let status = try await driver.runCommand(["connectionStatus": .int32(1)], database: "admin")
        let users = status["authInfo"]?.documentValue?["authenticatedUsers"]?.arrayValue ?? []
        #expect(users.contains { $0.documentValue?["user"]?.stringValue == subject })
        await driver.disconnect()

        let named = MongoDriver(config: Self.config(user: "CN=someone-else", mechanism: "MONGODB-X509"), secrets: ConnectionSecrets())
        await #expect(throws: (any Error).self) { try await named.connect() }
    }
}
