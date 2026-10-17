import Foundation
import Testing
@testable import BunnyGridCore

/// Runs against a real SQL Server when `BUNNYGRID_MSSQL_PORT` is set, e.g. a disposable container:
/// `docker run -d --platform linux/amd64 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=… -p 14331:1433 mcr.microsoft.com/mssql/server:2022-latest`
/// then `BUNNYGRID_MSSQL_PORT=14331 BUNNYGRID_MSSQL_PASSWORD=… swift test --filter SQLServer`.
/// The login needs CREATE DATABASE: each test works in a database of its own, dropped afterwards.
private enum MSSQL {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["BUNNYGRID_MSSQL_PORT"] != nil

    static func config(database: String = "", tls: TLSMode = .require, readOnly: Bool = false) -> ConnectionConfig {
        ConnectionConfig(kind: .sqlserver, host: env["BUNNYGRID_MSSQL_HOST"] ?? "127.0.0.1",
                         port: Int(env["BUNNYGRID_MSSQL_PORT"] ?? "") ?? 1433, username: env["BUNNYGRID_MSSQL_USER"] ?? "sa",
                         database: database, tls: tls, readOnly: readOnly)
    }

    static var password: String? { env["BUNNYGRID_MSSQL_PASSWORD"] }

    static func driver(database: String = "", tls: TLSMode = .require) async throws -> SQLServerDriver {
        let driver = SQLServerDriver(config: config(database: database, tls: tls), password: password)
        try await driver.connect()
        return driver
    }
}

@Suite(.enabled(if: MSSQL.enabled, "set BUNNYGRID_MSSQL_PORT to run against SQL Server"), .serialized)
struct SQLServerIntegrationTests {
    private func withDatabase(_ body: (SQLServerDriver, String) async throws -> Void) async throws {
        let admin = try await MSSQL.driver()
        let db = "bg_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await admin.executeStatement("CREATE DATABASE [\(db)]")
        let driver = try await MSSQL.driver(database: db)
        var failure: (any Error)?
        do { try await body(driver, db) } catch { failure = error }
        await driver.disconnect()
        _ = try? await admin.executeStatement("ALTER DATABASE [\(db)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE")
        _ = try? await admin.executeStatement("DROP DATABASE [\(db)]")
        await admin.disconnect()
        if let failure { throw failure }
    }

    @Test func connectsWithEachEncryptionMode() async throws {
        for mode in [TLSMode.require, .prefer, .disable] {
            let driver = SQLServerDriver(config: MSSQL.config(tls: mode), password: MSSQL.password)
            do {
                try await driver.connect()
                #expect(try await driver.executeStatement("SELECT 1 AS one").rows == [[.integer(1)]], "\(mode)")
                await driver.disconnect()
            } catch {
                // A server with "force encryption" refuses Disabled with a clear message.
                #expect(mode == .disable && error.localizedDescription.contains("encrypt"), "\(mode): \(error)")
            }
        }
        #expect(try await MSSQL.driver().serverVersion().contains("Microsoft SQL Server"))
    }

    @Test func verifyFullRejectsTheSelfSignedCertificate() async {
        let driver = SQLServerDriver(config: MSSQL.config(tls: .verifyFull), password: MSSQL.password)
        await #expect(throws: DatabaseError.self) { try await driver.connect() }
    }

    @Test func wrongPasswordFailsClearly() async {
        let driver = SQLServerDriver(config: MSSQL.config(), password: "definitely-wrong")
        do {
            try await driver.connect()
            Issue.record("connected with a wrong password")
        } catch {
            #expect(error.localizedDescription.contains("Login failed"))
        }
    }

    @Test func decodesEveryType() async throws {
        let driver = try await MSSQL.driver()
        let result = try await driver.executeStatement("""
            SELECT CAST(255 AS tinyint), CAST(-2 AS smallint), CAST(7 AS int), CAST(9000000000 AS bigint), CAST(1 AS bit),
                   CAST(-123.45 AS decimal(10,2)), CAST(12.34 AS money), CAST(1.5 AS smallmoney), CAST(0.5 AS float), CAST(3.14 AS real),
                   CAST('caé' AS varchar(10)), CAST(N'ação ✓' AS nvarchar(20)), CAST('ab' AS char(3)), CAST(N'x' AS nchar(2)),
                   CAST(REPLICATE(CAST(N'z' AS nvarchar(max)), 9000) AS nvarchar(max)), CAST('t' AS text), CAST(N'n' AS ntext),
                   0xCAFE, CAST(0x01 AS binary(2)), CAST(0xBEEF AS varbinary(max)),
                   CAST('2026-10-17' AS date), CAST('09:30:00.1234567' AS time(7)), CAST('2026-10-17 09:30:00.123' AS datetime),
                   CAST('2026-10-17 09:30:00.1234567' AS datetime2(7)), CAST('2026-10-17 09:30:00 -03:00' AS datetimeoffset(0)),
                   CAST('2026-10-17 09:30' AS smalldatetime), CAST('00112233-4455-6677-8899-AABBCCDDEEFF' AS uniqueidentifier),
                   CAST('<a>1</a>' AS xml), CAST(5 AS sql_variant), NULL, CAST(NULL AS nvarchar(max))
            """)
        let row = try #require(result.rows.first)
        #expect(Array(row[0..<10]) == [.integer(255), .integer(-2), .integer(7), .integer(9_000_000_000), .bool(true),
                                       .text("-123.45"), .text("12.3400"), .text("1.5000"), .double(0.5), .double(3.14)])
        #expect(Array(row[10..<14]) == [.text("caé"), .text("ação ✓"), .text("ab "), .text("x ")])
        #expect(row[14] == .text(String(repeating: "z", count: 9000)))
        #expect(Array(row[15..<20]) == [.text("t"), .text("n"), .blob(Data([0xCA, 0xFE])), .blob(Data([0x01, 0x00])), .blob(Data([0xBE, 0xEF]))])
        #expect(Array(row[20..<27]) == [.text("2026-10-17"), .text("09:30:00.1234567"), .text("2026-10-17 09:30:00.123"),
                                        .text("2026-10-17 09:30:00.1234567"), .text("2026-10-17 09:30:00 -03:00"),
                                        .text("2026-10-17 09:30:00"), .text("00112233-4455-6677-8899-AABBCCDDEEFF")])
        #expect(Array(row[27...]) == [.text("<a>1</a>"), .integer(5), .null, .null])
        await driver.disconnect()
    }

    @Test func catalogDDLAndPaging() async throws {
        try await withDatabase { driver, db in
            for sql in [
                "CREATE SCHEMA sales",
                "CREATE TABLE sales.customers (id int IDENTITY(1,1) NOT NULL CONSTRAINT PK_customers PRIMARY KEY, name nvarchar(50) NOT NULL, vip bit NOT NULL CONSTRAINT DF_vip DEFAULT (0))",
                "CREATE TABLE sales.orders (id bigint NOT NULL PRIMARY KEY, customer_id int NOT NULL CONSTRAINT FK_orders_customers REFERENCES sales.customers(id) ON DELETE CASCADE, total decimal(10,2) NULL, CONSTRAINT CK_total CHECK (total >= 0))",
                "CREATE INDEX ix_orders_customer ON sales.orders (customer_id) INCLUDE (total)",
                "CREATE VIEW sales.big_orders AS SELECT * FROM sales.orders WHERE total > 100",
                "CREATE PROCEDURE sales.touch AS BEGIN SET NOCOUNT ON; SELECT 1; END",
                "CREATE TRIGGER sales.tr_orders ON sales.orders AFTER INSERT AS BEGIN SET NOCOUNT ON; END",
                "INSERT INTO sales.customers (name) VALUES (N'Ana'), (N'Bia'), (N'Caio')",
            ] { _ = try await driver.executeStatement(sql) }

            #expect(try await driver.listDatabases().contains(db))
            #expect(try await driver.listSchemas().contains("sales"))
            let objects = try await driver.listObjects(schema: "sales")
            #expect(Set(objects.map { "\($0.kind.rawValue):\($0.name)" }) == ["table:customers", "table:orders", "view:big_orders", "routine:touch"])

            let columns = try await driver.listColumns(table: "orders", schema: "sales")
            #expect(columns.map(\.name) == ["id", "customer_id", "total"])
            #expect(columns.map(\.dataType) == ["bigint", "int", "decimal(10,2)"])
            #expect(columns[0].isPrimaryKey && !columns[2].nullable == false)
            let indexes = try await driver.listIndexes(table: "orders", schema: "sales")
            #expect(indexes.contains { $0.name == "ix_orders_customer" && $0.columns == ["customer_id"] && !$0.unique })
            #expect(indexes.contains { $0.primary })
            let keys = try await driver.listForeignKeys(table: "orders", schema: "sales")
            #expect(keys == [TableForeignKey(name: "FK_orders_customers", columns: ["customer_id"], referencedSchema: "sales",
                                             referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE", onUpdate: "NO ACTION")])
            let triggers = try await driver.listTriggers(table: "orders", schema: "sales")
            #expect(triggers.map(\.name) == ["tr_orders"] && triggers[0].events == ["INSERT"])

            let ddl = try await driver.objectDDL(name: "customers", kind: .table, schema: "sales")
            #expect(ddl.contains("[id] int IDENTITY(1,1) NOT NULL"))
            #expect(ddl.contains("CONSTRAINT [DF_vip] DEFAULT ((0))"))
            #expect(ddl.contains("CONSTRAINT [PK_customers] PRIMARY KEY CLUSTERED ([id])"))
            let ordersDDL = try await driver.objectDDL(name: "orders", kind: .table, schema: "sales")
            #expect(ordersDDL.contains("INCLUDE ([total])") && ordersDDL.contains("CHECK ([total]>=(0))"))
            #expect(ordersDDL.hasSuffix("ON DELETE CASCADE;"))
            #expect(try await driver.objectDDL(name: "big_orders", kind: .view, schema: "sales").hasPrefix("CREATE VIEW"))
            #expect(try await driver.objectDDL(name: "touch", kind: .routine, schema: "sales").contains("PROCEDURE"))

            let page = try await driver.fetchPage(table: "customers", schema: "sales", offset: 1, limit: 1,
                                                  orderBy: [OrderBy(column: "id", direction: .ascending)])
            #expect(page.columns == ["id", "name", "vip"] && page.rows == [[.integer(2), .text("Bia"), .bool(false)]])
            #expect(try await driver.countRows(table: "customers", schema: "sales") == 3)
            let stats = try await driver.tableStatistics(schema: "sales")
            #expect(stats["customers"]?.rows == 3)

            // Rebuilding the dump in a fresh schema-less copy: tables, rows (identity values kept), keys at the end.
            let dump = try await SQLDumper.dump(objects.filter { $0.kind == .table }, from: driver, options: SQLDumpOptions())
            #expect(dump.contains("SET IDENTITY_INSERT [sales].[customers] ON;"))
            for statement in SQLSplitter.split(dump.replacingOccurrences(of: "[sales]", with: "[dbo]").replacingOccurrences(of: "sales.", with: "dbo.")) {
                _ = try await driver.executeStatement(statement)
            }
            #expect(try await driver.countRows(table: "customers", schema: "dbo") == 3)
            #expect(try await driver.listForeignKeys(table: "orders", schema: "dbo").count == 1)
        }
    }

    @Test func applyChangesWithTypedParametersAndTransactions() async throws {
        try await withDatabase { driver, _ in
            _ = try await driver.executeStatement("""
                CREATE TABLE dbo.items (id int IDENTITY PRIMARY KEY, name nvarchar(40) NULL, price decimal(8,2) NULL, ok bit NULL,
                                        born date NULL, at datetime2(3) NULL, uid uniqueidentifier NULL, photo varbinary(max) NULL, score float NULL)
                """)
            let columns = try await driver.listColumns(table: "items", schema: "dbo")
            let insert = RowChange.insert(values: [ColumnValue("name", .text("Chá ✓")), ColumnValue("price", .text("12.50")), ColumnValue("ok", .text("true")),
                                                   ColumnValue("born", .text("2026-10-17")), ColumnValue("at", .text("2026-10-17 09:30:00.250")),
                                                   ColumnValue("uid", .text("00112233-4455-6677-8899-aabbccddeeff")),
                                                   ColumnValue("photo", .blob(Data([1, 2, 3]))), ColumnValue("score", .double(2.5))])
            try await driver.applyChanges([insert], table: "items", schema: "dbo", columns: columns)
            var rows = try await driver.executeStatement("SELECT * FROM dbo.items").rows
            #expect(rows == [[.integer(1), .text("Chá ✓"), .text("12.50"), .bool(true), .text("2026-10-17"), .text("2026-10-17 09:30:00.250"),
                              .text("00112233-4455-6677-8899-AABBCCDDEEFF"), .blob(Data([1, 2, 3])), .double(2.5)]])

            let update = RowChange.update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("photo", .null), ColumnValue("name", .text("x"))])
            try await driver.applyChanges([update], table: "items", schema: "dbo", columns: columns)
            rows = try await driver.executeStatement("SELECT name, photo FROM dbo.items").rows
            #expect(rows == [[.text("x"), .null]])

            // A failing change rolls back the whole batch.
            let bad = RowChange.update(key: [ColumnValue("id", .integer(99))], values: [ColumnValue("name", .text("y"))])
            await #expect(throws: DatabaseError.self) {
                try await driver.applyChanges([.delete(key: [ColumnValue("id", .integer(1))]), bad], table: "items", schema: "dbo", columns: columns)
            }
            #expect(try await driver.countRows(table: "items", schema: "dbo") == 1)

            // Manual transaction across batches (the descriptor follows ENVCHANGE).
            _ = try await driver.executeStatement("BEGIN TRANSACTION")
            _ = try await driver.executeStatement("DELETE FROM dbo.items")
            #expect(try await driver.countRows(table: "items", schema: "dbo") == 0)
            _ = try await driver.executeStatement("ROLLBACK")
            #expect(try await driver.countRows(table: "items", schema: "dbo") == 1)
            let affected = try await driver.executeStatement("UPDATE dbo.items SET score = 1")
            #expect(affected.affectedRows == 1)
        }
    }

    @Test func designerAlterStatementsRun() async throws {
        try await withDatabase { driver, _ in
            _ = try await driver.executeStatement("CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, n nvarchar(10) NULL DEFAULT (N'a'), gone int NULL DEFAULT 1)")
            let original = try await driver.listColumns(table: "t", schema: "dbo")
            var renamed = ColumnDesign(original[1])
            renamed.name = "label"
            renamed.type = "nvarchar(20)"
            renamed.nullable = false
            renamed.defaultValue = "N'b'"
            let statements = try driver.dialect.alterTable(name: "t", schema: "dbo", original: original,
                                                           design: [ColumnDesign(original[0]), renamed, ColumnDesign(name: "qty", type: "int")])
            try await driver.applyDesign(statements)
            let after = try await driver.listColumns(table: "t", schema: "dbo")
            #expect(after.map(\.name) == ["id", "label", "qty"])
            #expect(after[1].dataType == "nvarchar(20)" && !after[1].nullable && after[1].defaultValue == "(N'b')")
            _ = try await driver.executeStatement(driver.dialect.renameObject(DatabaseObject(schema: "dbo", name: "t", kind: .table), to: "t2"))
            try await driver.duplicateTable(DatabaseObject(schema: "dbo", name: "t2", kind: .table), as: "t3", withData: true)
            #expect(try await driver.listColumns(table: "t3", schema: "dbo").filter(\.isPrimaryKey).map(\.name) == ["id"])
        }
    }

    @Test func rowCapStopsTheServerAndCancelInterrupts() async throws {
        let driver = try await MSSQL.driver()
        let capped = try await driver.executeStatement("SELECT TOP 50000 a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b", maxRows: 10)
        #expect(capped.rows.count == 10 && capped.isTruncated)
        // The connection is usable after the ATTENTION.
        #expect(try await driver.executeStatement("SELECT 2").rows == [[.integer(2)]])

        let running = Task { try await driver.executeStatement("WAITFOR DELAY '00:00:20'") }
        try await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        try await driver.cancelCurrentQuery()
        do {
            _ = try await running.value
            Issue.record("the statement wasn't cancelled")
        } catch {
            #expect(error.localizedDescription.contains("cancelled"))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(try await driver.executeStatement("SELECT 3").rows == [[.integer(3)]])
        // Errors come back as messages and leave the connection usable.
        await #expect(throws: DatabaseError.self) { try await driver.executeStatement("SELECT * FROM no_such_table") }
        #expect(try await driver.executeStatement("SELECT 4").rows == [[.integer(4)]])
        await driver.disconnect()
    }

    @Test func explainReturnsAPlanTree() async throws {
        let driver = try await MSSQL.driver()
        let result = try await driver.executeStatement(driver.dialect.explain("SELECT name FROM sys.objects WHERE object_id = 5"))
        let plan = try #require(QueryPlan.parse(result, kind: .sqlserver))
        #expect(plan.first?.title.hasPrefix("SELECT name FROM sys.objects") == true)
        #expect(plan.first?.children.isEmpty == false)
        // SHOWPLAN is off again: the next statement runs.
        #expect(try await driver.executeStatement("SELECT 5").rows == [[.integer(5)]])
        await driver.disconnect()
    }

    @Test func listsLogins() async throws {
        let driver = try await MSSQL.driver()
        let users = driver.dialect.users(from: try await driver.executeStatement(try #require(driver.dialect.listUsersSQL)))
        #expect(users.contains { $0.name == "sa" && $0.attributes.contains("sysadmin") })
        await driver.disconnect()
    }
}
