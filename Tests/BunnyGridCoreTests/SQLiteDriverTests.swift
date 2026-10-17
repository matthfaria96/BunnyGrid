import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct SQLiteDriverTests {
    private func makeDriver(readOnly: Bool = false) async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: "", readOnly: readOnly))
        try await driver.connect()
        return driver
    }

    private func seed(_ driver: SQLiteDriver) async throws {
        _ = try await driver.execute("""
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, avatar BLOB);
            CREATE INDEX users_name ON users(name);
            CREATE VIEW top_users AS SELECT * FROM users WHERE score > 5;
            INSERT INTO users (name, score, avatar) VALUES ('ana', 9.5, x'0102'), ('bia', 3, NULL), ('caio', NULL, NULL);
            """)
    }

    @Test func listsTablesAndViews() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let objects = try await driver.listObjects(schema: nil)
        #expect(objects.map(\.name) == ["users", "top_users"])
        #expect(objects.map(\.kind) == [.table, .view])
    }

    @Test func printsStoredDDL() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let table = try await driver.objectDDL(name: "users", kind: .table, schema: nil)
        #expect(table == "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, avatar BLOB);\n\nCREATE INDEX users_name ON users(name);")
        let view = try await driver.objectDDL(name: "top_users", kind: .view, schema: nil)
        #expect(view.hasPrefix("CREATE VIEW top_users AS SELECT"))
        // The generic rebuild used by engines without stored DDL.
        let rebuilt = try await driver.generatedTableDDL(name: "users", schema: nil)
        #expect(rebuilt.contains("CREATE TABLE \"users\""))
        #expect(rebuilt.contains("CREATE INDEX \"users_name\""))
    }

    @Test func describesColumnsAndIndexes() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let columns = try await driver.listColumns(table: "users", schema: nil)
        #expect(columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(columns[0].isPrimaryKey)
        #expect(!columns[1].nullable)
        let indexes = try await driver.listIndexes(table: "users", schema: nil)
        #expect(indexes.contains { $0.name == "users_name" && $0.columns == ["name"] })
    }

    @Test func decodesValueTypes() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let page = try await driver.fetchPage(table: "users", schema: nil, offset: 0, limit: 10, orderBy: [OrderBy(column: "id", direction: .ascending)])
        #expect(page.columns == ["id", "name", "score", "avatar"])
        #expect(page.rows[0] == [.integer(1), .text("ana"), .double(9.5), .blob(Data([1, 2]))])
        #expect(page.rows[2][2] == .null)
        #expect(!page.hasMore)
    }

    @Test func pagesFiltersAndCounts() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let page = try await driver.fetchPage(table: "users", schema: nil, offset: 1, limit: 1, orderBy: [OrderBy(column: "name", direction: .ascending)])
        #expect(page.rows.map { $0[1] } == [.text("bia")])
        #expect(page.hasMore)
        #expect(try await driver.countRows(table: "users", schema: nil) == 3)
        #expect(try await driver.countRows(table: "users", schema: nil, filter: "score IS NOT NULL") == 2)
    }

    @Test func reportsAffectedRows() async throws {
        let driver = try await makeDriver()
        try await seed(driver)
        let results = try await driver.execute("UPDATE users SET score = 0; SELECT COUNT(*) FROM users")
        #expect(results.count == 2)
        #expect(results[0].affectedRows == 3)
        #expect(results[1].rows == [[.integer(3)]])
    }

    @Test func surfacesSyntaxErrors() async throws {
        let driver = try await makeDriver()
        await #expect(throws: DatabaseError.self) {
            try await driver.execute("SELEC 1")
        }
    }

    @Test func readOnlyConnectionsRejectWrites() async throws {
        let driver = try await makeDriver(readOnly: true)
        await #expect(throws: DatabaseError.self) {
            try await driver.execute("CREATE TABLE t (x)")
        }
        let results = try await driver.execute("SELECT 1 + 1")
        #expect(results[0].rows == [[.integer(2)]])
    }
}

@Suite struct ConstraintTests {
    @Test func sqliteListsForeignKeysAndTriggers() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id) ON DELETE CASCADE, title TEXT);
            CREATE TRIGGER books_touch AFTER UPDATE ON books BEGIN SELECT 1; END;
            """)
        let keys = try await driver.listForeignKeys(table: "books", schema: nil)
        #expect(keys == [TableForeignKey(name: "", columns: ["author_id"], referencedTable: "authors", referencedColumns: ["id"], onDelete: "CASCADE", onUpdate: "NO ACTION")])
        let triggers = try await driver.listTriggers(table: "books", schema: nil)
        #expect(triggers.map(\.name) == ["books_touch"])
        #expect(triggers.first?.timing == "AFTER")
        #expect(triggers.first?.events == ["UPDATE"])
    }

    @Test func foreignKeySQL() throws {
        let key = TableForeignKey(name: "books_author", columns: ["author_id"], referencedTable: "authors", referencedColumns: ["id"], onDelete: "CASCADE")
        #expect(try SQLDialect(kind: .postgresql).addForeignKey(key, table: "books", schema: "public")
                == #"ALTER TABLE "public"."books" ADD CONSTRAINT "books_author" FOREIGN KEY ("author_id") REFERENCES "public"."authors" ("id") ON DELETE CASCADE"#)
        #expect(try SQLDialect(kind: .mysql).dropForeignKey(named: "books_author", table: "books", schema: "shop")
                == "ALTER TABLE `shop`.`books` DROP FOREIGN KEY `books_author`")
        #expect(throws: TableDesignError.self) { try SQLDialect(kind: .sqlite).addForeignKey(key, table: "books", schema: nil) }
        #expect(SQLDialect(kind: .postgresql).dropTrigger(named: "t1", table: "books", schema: "public") == #"DROP TRIGGER "t1" ON "public"."books""#)
    }
}
