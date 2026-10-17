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
        #expect(throws: ConnectionURI.ParseError.unsupportedScheme("mongodb")) { try ConnectionURI.parse("mongodb://h/db") }
        #expect(throws: ConnectionURI.ParseError.invalid) { try ConnectionURI.parse("not a uri") }
        #expect(throws: ConnectionURI.ParseError.invalid) { try ConnectionURI.parse("postgresql://") }
    }
}
