import Testing
@testable import BunnyGridCore

@Suite struct ConnectionURITests {
    @Test func parsesPostgres() throws {
        let parsed = try ConnectionURI.parse("postgresql://ana%40corp:s%3Acret@db.example.com:6543/sales?sslmode=require")
        #expect(parsed.config.kind == .postgresql)
        #expect(parsed.config.host == "db.example.com")
        #expect(parsed.config.port == 6543)
        #expect(parsed.config.username == "ana@corp")
        #expect(parsed.password == "s:cret")
        #expect(parsed.config.database == "sales")
        #expect(parsed.config.tls == .require)
    }

    @Test func defaultsPortAndTLS() throws {
        let mysql = try ConnectionURI.parse("mysql://root@localhost/shop")
        #expect(mysql.config.kind == .mysql && mysql.config.port == 3306 && mysql.config.tls == .prefer)
        #expect(mysql.password == nil)
        #expect(try ConnectionURI.parse("postgres://u@h").config.port == 5432)
        #expect(try ConnectionURI.parse("mariadb://u@h/db?ssl=false").config.tls == .disable)
    }

    @Test func parsesSQLitePaths() throws {
        let parsed = try ConnectionURI.parse("sqlite:///Users/me/data/app.db")
        #expect(parsed.config.kind == .sqlite)
        #expect(parsed.config.filePath == "/Users/me/data/app.db")
        #expect(parsed.config.name == "app.db")
    }

    @Test func rejectsUnknownAndMalformed() {
        #expect(throws: ConnectionURI.ParseError.unsupportedScheme("oracle")) { try ConnectionURI.parse("oracle://h/db") }
        #expect(throws: ConnectionURI.ParseError.invalid) { try ConnectionURI.parse("not a uri") }
        #expect(throws: ConnectionURI.ParseError.invalid) { try ConnectionURI.parse("postgresql://") }
    }
}

@Suite struct ConnectionURIStringTests {
    @Test func buildsURIsThatParseBack() throws {
        let config = ConnectionConfig(kind: .postgresql, host: "db.example.com", port: 6543, username: "ana", database: "shop", tls: .require)
        let uri = ConnectionURI.string(for: config)
        #expect(uri == "postgresql://ana@db.example.com:6543/shop?sslmode=require")
        let parsed = try ConnectionURI.parse(ConnectionURI.string(for: config, password: "s3cret"))
        #expect(parsed.password == "s3cret")
        #expect(parsed.config.host == "db.example.com")
        #expect(parsed.config.tls == .require)
        #expect(ConnectionURI.string(for: ConnectionConfig(kind: .mysql, host: "localhost", username: "root")) == "mysql://root@localhost:3306")
        #expect(ConnectionURI.string(for: ConnectionConfig(kind: .sqlite, filePath: "/tmp/a b.db")) == "sqlite:///tmp/a%20b.db")
    }
}
