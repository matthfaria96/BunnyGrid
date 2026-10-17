import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct TableOperationsTests {
    private let users = DatabaseObject(schema: nil, name: "users", kind: .table)

    private func seeded() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, note TEXT);
            CREATE INDEX users_name ON users(name);
            CREATE VIEW named AS SELECT name FROM users;
            INSERT INTO users (name, note) VALUES ('ana', 'it''s'), ('bia', NULL);
            """)
        return driver
    }

    private func count(_ driver: SQLiteDriver, _ table: String) async throws -> Int {
        try await driver.countRows(table: table, schema: nil)
    }

    @Test func dialectStatements() {
        let pg = SQLDialect(kind: .postgresql), my = SQLDialect(kind: .mysql)
        let orders = DatabaseObject(schema: "sales", name: "orders", kind: .table)
        #expect(pg.dropObject(orders) == "DROP TABLE \"sales\".\"orders\"")
        #expect(pg.dropObject(DatabaseObject(schema: "sales", name: "v", kind: .materializedView)) == "DROP MATERIALIZED VIEW \"sales\".\"v\"")
        #expect(pg.truncateTable(orders) == ["TRUNCATE TABLE \"sales\".\"orders\" RESTART IDENTITY"])
        #expect(pg.renameObject(orders, to: "orders_old") == "ALTER TABLE \"sales\".\"orders\" RENAME TO \"orders_old\"")
        #expect(my.renameObject(DatabaseObject(schema: nil, name: "orders", kind: .table), to: "o2") == "RENAME TABLE `orders` TO `o2`")
        #expect(SQLDialect.copyName(for: "orders", existing: ["orders", "orders_copy"]) == "orders_copy2")
    }

    @Test func emptyTruncateRenameDrop() async throws {
        let driver = try await seeded()
        let d = driver.dialect
        _ = try await driver.executeStatement(d.emptyTable(users))
        #expect(try await count(driver, "users") == 0)

        _ = try await driver.execute("INSERT INTO users (name) VALUES ('caio')")
        for sql in d.truncateTable(users) { _ = try await driver.executeStatement(sql) }
        _ = try await driver.execute("INSERT INTO users (name) VALUES ('davi')")
        // Truncate reset the AUTOINCREMENT counter.
        let id = try await driver.executeStatement("SELECT id FROM users").rows.first?.first
        #expect(id == .integer(1))

        _ = try await driver.executeStatement(d.renameObject(users, to: "people"))
        #expect(try await driver.listObjects(schema: nil).map(\.name).contains("people"))
        _ = try await driver.executeStatement(d.dropObject(DatabaseObject(schema: nil, name: "people", kind: .table)))
        #expect(!(try await driver.listObjects(schema: nil).map(\.name).contains("people")))
    }

    @Test func duplicatesStructureAndData() async throws {
        let driver = try await seeded()
        try await driver.duplicateTable(users, as: "users_copy", withData: true)
        try await driver.duplicateTable(users, as: "users_shape", withData: false)
        #expect(try await count(driver, "users_copy") == 2)
        #expect(try await count(driver, "users_shape") == 0)
        let columns = try await driver.listColumns(table: "users_shape", schema: nil)
        #expect(columns.map(\.name) == ["id", "name", "note"])
        #expect(columns.first?.isPrimaryKey == true)
        #expect(try await driver.listIndexes(table: "users_shape", schema: nil).contains { $0.name == "users_shape_users_name" })
    }

    @Test func dumpRoundTrips() async throws {
        let driver = try await seeded()
        let objects = try await driver.listObjects(schema: nil)
        let script = try await SQLDumper.dump(objects, from: driver, includeData: true, header: "BunnyGrid dump")
        #expect(script.hasPrefix("-- BunnyGrid dump"))
        #expect(script.contains("INSERT INTO \"users\" (\"id\", \"name\", \"note\") VALUES (1, 'ana', 'it''s');"))
        // Views come after tables.
        #expect(script.range(of: "CREATE VIEW")!.lowerBound > script.range(of: "CREATE TABLE")!.lowerBound)

        let restored = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await restored.connect()
        _ = try await restored.execute(script)
        #expect(try await count(restored, "users") == 2)
        #expect(try await restored.listObjects(schema: nil).map(\.name).sorted() == ["named", "users"])

        let structure = try await SQLDumper.dump([users], from: driver, includeData: false)
        #expect(!structure.contains("INSERT"))
    }
}

@Suite struct TableExporterTests {
    @Test func exportsEveryPage() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE n (id INTEGER PRIMARY KEY, v TEXT)")
        for i in 1...25 { _ = try await driver.executeStatement("INSERT INTO n (v) VALUES ('r\(i)')") }
        let page = try await driver.fetchAllRows(table: "n", schema: nil, batchSize: 10)
        #expect(page.rows.count == 25)
        #expect(page.rows.last?.last == .text("r25"))
        let object = DatabaseObject(schema: nil, name: "n", kind: .table)
        let csv = String(decoding: try await TableExporter.export(object, from: driver, as: .csv), as: UTF8.self)
        #expect(csv.hasPrefix("id,v\r\n1,r1\r\n"))
        let sql = String(decoding: try await TableExporter.export(object, from: driver, as: .sql), as: UTF8.self)
        #expect(sql.components(separatedBy: "INSERT INTO").count == 26)
    }
}

@Suite struct UserManagementTests {
    @Test func postgresRoles() throws {
        let d = SQLDialect(kind: .postgresql)
        #expect(try d.createUser(UserDraft(name: "app", password: "s'x", createDatabases: true))
                == ["CREATE ROLE \"app\" LOGIN CREATEDB PASSWORD 's''x'"])
        let result = QueryResult(statement: "", columns: ["rolname", "rolsuper", "rolcanlogin", "rolcreatedb", "rolcreaterole"],
                                 rows: [[.text("postgres"), .bool(true), .bool(true), .bool(true), .bool(true)],
                                        [.text("readers"), .bool(false), .bool(false), .bool(false), .bool(false)]])
        let users = d.users(from: result)
        #expect(users.map(\.attributes) == [["Superuser", "Can login", "Create DB", "Create role"], ["Role"]])
        #expect(d.dropUser(users[1]) == "DROP ROLE \"readers\"")
    }

    @Test func mysqlAccounts() throws {
        let d = SQLDialect(kind: .mysql)
        let statements = try d.createUser(UserDraft(name: "app", password: "pw", host: "localhost", superuser: true))
        #expect(statements == ["CREATE USER 'app'@'localhost' IDENTIFIED BY 'pw'",
                               "GRANT ALL PRIVILEGES ON *.* TO 'app'@'localhost' WITH GRANT OPTION"])
        #expect(d.dropUser(DatabaseUser(name: "app", host: "%")) == "DROP USER 'app'@'%'")
        #expect(d.grantsSQL(DatabaseUser(name: "app", host: "%")) == "SHOW GRANTS FOR 'app'@'%'")
        #expect(throws: (any Error).self) { try d.createUser(UserDraft(name: " ")) }
    }

    @Test func otherObjectsRunOnSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (a); CREATE INDEX t_a ON t(a)")
        let indexes = try await driver.executeStatement(driver.dialect.otherObjectQueries[0].sql)
        #expect(indexes.rows.first?.first == .text("t_a"))
    }
}
