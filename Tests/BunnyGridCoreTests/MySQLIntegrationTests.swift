import Foundation
import Testing
@testable import BunnyGridCore

/// Runs against a real MySQL or MariaDB server when `BUNNYGRID_MYSQL_PORT` is set, e.g.
/// `BUNNYGRID_MYSQL_PORT=33069 BUNNYGRID_MYSQL_USER=root BUNNYGRID_MYSQL_PASSWORD=… swift test --filter MySQL`.
/// `BUNNYGRID_MYSQL_KIND=mariadb` labels the connection as MariaDB. The user needs CREATE/DROP DATABASE:
/// each test works in a database of its own, dropped afterwards.
private enum MySQL {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["BUNNYGRID_MYSQL_PORT"] != nil
    static var kind: DatabaseKind { env["BUNNYGRID_MYSQL_KIND"]?.lowercased() == "mariadb" ? .mariadb : .mysql }

    static func config(database: String? = nil, tls: TLSMode = .disable, readOnly: Bool = false) -> ConnectionConfig {
        ConnectionConfig(
            kind: kind,
            host: env["BUNNYGRID_MYSQL_HOST"] ?? "127.0.0.1",
            port: Int(env["BUNNYGRID_MYSQL_PORT"] ?? "") ?? 3306,
            username: env["BUNNYGRID_MYSQL_USER"] ?? "root",
            database: database ?? env["BUNNYGRID_MYSQL_DATABASE"] ?? "",
            tls: tls,
            readOnly: readOnly
        )
    }

    static var password: String? { env["BUNNYGRID_MYSQL_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } }

    static func driver(database: String? = nil, readOnly: Bool = false) async throws -> MySQLDriver {
        let driver = MySQLDriver(config: config(database: database, readOnly: readOnly), password: password)
        try await driver.connect()
        return driver
    }
}

@Suite(.enabled(if: MySQL.enabled, "set BUNNYGRID_MYSQL_PORT to run against MySQL/MariaDB"), .serialized)
struct MySQLIntegrationTests {
    /// A database of its own per test (MySQL's "schema"), connected to and dropped afterwards.
    private func withDatabase(_ body: (MySQLDriver, String) async throws -> Void) async throws {
        let admin = try await MySQL.driver()
        let db = "bg_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await admin.executeStatement("CREATE DATABASE `\(db)` CHARACTER SET utf8mb4")
        let driver = try await MySQL.driver(database: db)
        do {
            try await body(driver, db)
        } catch {
            await driver.disconnect()
            _ = try? await admin.executeStatement("DROP DATABASE `\(db)`")
            await admin.disconnect()
            throw error
        }
        await driver.disconnect()
        _ = try await admin.executeStatement("DROP DATABASE `\(db)`")
        await admin.disconnect()
    }

    @Test func connectsAndListsCatalog() async throws {
        try await withDatabase { driver, db in
            let version = try await driver.serverVersion()
            #expect(version.hasPrefix(MySQL.kind.displayName))
            let databases = try await driver.listDatabases()
            #expect(databases.contains(db))
            #expect(databases.contains("information_schema"))
            #expect(try await driver.listSchemas() == databases)
        }
    }

    @Test func wrongPasswordFailsClearly() async {
        let driver = MySQLDriver(config: MySQL.config(), password: "definitely-wrong")
        await #expect(throws: DatabaseError.self) { try await driver.connect() }
    }

    @Test func tlsPreferAlsoConnects() async throws {
        let driver = MySQLDriver(config: MySQL.config(tls: .prefer), password: MySQL.password)
        try await driver.connect()
        #expect(try await driver.execute("SELECT 1").first?.rows == [[.integer(1)]])
        await driver.disconnect()
    }

    @Test func listsObjectsTypesIndexesAndDDL() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.execute("""
                CREATE TABLE customer (id int unsigned AUTO_INCREMENT PRIMARY KEY, email varchar(80) NOT NULL UNIQUE) ENGINE=InnoDB;
                CREATE TABLE payment (
                  payment_id int AUTO_INCREMENT PRIMARY KEY,
                  customer_id int unsigned NOT NULL,
                  amount decimal(5,2) NOT NULL DEFAULT 0.00,
                  note varchar(40),
                  paid_at datetime(6),
                  CONSTRAINT fk_payment_customer FOREIGN KEY (customer_id) REFERENCES customer (id) ON DELETE CASCADE
                ) ENGINE=InnoDB COMMENT='Payments';
                CREATE INDEX payment_customer_idx ON payment (customer_id, paid_at);
                CREATE VIEW big_payments AS SELECT * FROM payment WHERE amount > 5;
                CREATE FUNCTION double_it(x int) RETURNS int DETERMINISTIC RETURN x * 2;
                CREATE TRIGGER payment_note BEFORE INSERT ON payment FOR EACH ROW SET NEW.note = COALESCE(NEW.note, 'none');
                """)
            let objects = try await driver.listObjects(schema: db)
            #expect(objects.contains(DatabaseObject(schema: db, name: "payment", kind: .table)))
            #expect(objects.contains(DatabaseObject(schema: db, name: "big_payments", kind: .view)))
            #expect(objects.contains(DatabaseObject(schema: db, name: "double_it", kind: .routine)))

            let columns = try await driver.listColumns(table: "payment", schema: db)
            #expect(columns.map(\.name) == ["payment_id", "customer_id", "amount", "note", "paid_at"])
            #expect(columns.map(\.dataType).contains("decimal(5,2)"))
            #expect(columns.map(\.dataType).contains("varchar(40)"))
            #expect(columns.map(\.dataType).contains("datetime(6)"))
            #expect(columns[0].isPrimaryKey)
            #expect(columns[2].nullable == false)
            #expect(columns[3].nullable)

            let indexes = try await driver.listIndexes(table: "payment", schema: db)
            #expect(indexes.contains { $0.name == "payment_customer_idx" && $0.columns == ["customer_id", "paid_at"] && !$0.unique })
            #expect(indexes.contains { $0.primary && $0.unique })
            #expect(try await driver.listIndexes(table: "customer", schema: db).contains { $0.name == "email" && $0.unique })

            let keys = try await driver.listForeignKeys(table: "payment", schema: db)
            #expect(keys.count == 1)
            #expect(keys.first?.columns == ["customer_id"])
            #expect(keys.first?.referencedTable == "customer")
            #expect(keys.first?.referencedColumns == ["id"])
            #expect(keys.first?.onDelete == "CASCADE")

            let triggers = try await driver.listTriggers(table: "payment", schema: db)
            #expect(triggers.map(\.name) == ["payment_note"])
            #expect(triggers.first?.timing == "BEFORE")
            #expect(triggers.first?.events == ["INSERT"])

            let ddl = try await driver.objectDDL(name: "payment", kind: .table, schema: db)
            #expect(ddl.hasPrefix("CREATE TABLE `payment`"))
            #expect(ddl.contains("fk_payment_customer"))
            #expect(try await driver.objectDDL(name: "big_payments", kind: .view, schema: db).contains("VIEW `big_payments`"))
            #expect(try await driver.objectDDL(name: "double_it", kind: .routine, schema: db).contains("FUNCTION `double_it`"))
        }
    }

    @Test func decodesValueTypes() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.execute("""
                CREATE TABLE t (i bigint, u bigint unsigned, n decimal(8,3), f double, b tinyint(1), s varchar(20), tx text,
                                d date, dt datetime, dt6 datetime(6), tm time, y year, j json, raw varbinary(8), bits bit(8),
                                e enum('a','b'), nothing varchar(5));
                INSERT INTO t VALUES (42, 18446744073709551615, 12.345, 1.5, 1, 'olá', 'long text', '2024-02-29', '2024-02-29 13:45:00',
                  '2024-02-29 13:45:00.120000', '-838:59:59', 2024, '{"a": 1}', X'0102FF', b'00000101', 'b', NULL);
                """)
            let row = try #require(try await driver.fetchPage(table: "t", schema: db, offset: 0, limit: 10).rows.first)
            #expect(row[0] == .integer(42))
            #expect(row[1] == .text("18446744073709551615"))
            #expect(row[2] == .text("12.345"))
            #expect(row[3] == .double(1.5))
            #expect(row[4] == .integer(1))
            #expect(row[5] == .text("olá"))
            #expect(row[6] == .text("long text"))
            #expect(row[7] == .text("2024-02-29"))
            #expect(row[8] == .text("2024-02-29 13:45:00"))
            #expect(row[9] == .text("2024-02-29 13:45:00.120000"))
            #expect(row[10] == .text("-838:59:59"))
            #expect(row[11] == .integer(2024))
            if case .text(let json) = row[12] { #expect(json.contains("\"a\"")) } else { Issue.record("json should be text, got \(row[12])") }
            #expect(row[13] == .blob(Data([0x01, 0x02, 0xff])))
            #expect(row[14] == .blob(Data([0x05])))
            #expect(row[15] == .text("b"))
            #expect(row[16] == .null)
        }
    }

    @Test func reportsAffectedRowsAndErrors() async throws {
        try await withDatabase { driver, db in
            let results = try await driver.execute("""
                CREATE TABLE t (id int PRIMARY KEY, v varchar(5));
                INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c');
                UPDATE t SET v = 'z' WHERE id > 1;
                DELETE FROM t WHERE id = 1
                """)
            #expect(results[1].affectedRows == 3)
            #expect(results[2].affectedRows == 2)
            #expect(results[3].affectedRows == 1)
            do {
                _ = try await driver.execute("SELECT * FROM missing")
                Issue.record("expected an error")
            } catch {
                #expect(error.localizedDescription.contains("missing"))
                #expect(!error.localizedDescription.hasPrefix("MySQL error"), "the server message, without MySQLNIO's prefix")
            }
            #expect(try await driver.countRows(table: "t", schema: db) == 2, "the connection keeps working after an error")
        }
    }

    @Test func emptyResultsKeepColumnNames() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("CREATE TABLE t (id int PRIMARY KEY, label varchar(10))")
            let empty = try await driver.executeStatement("SELECT id, label AS name FROM t WHERE id > 5")
            #expect(empty.columns == ["id", "name"])
            #expect(empty.rows.isEmpty)
            #expect(empty.affectedRows == nil, "a result set, not a row count")
            #expect(try await driver.fetchPage(table: "t", schema: db, offset: 0, limit: 10).columns == ["id", "label"])
            let update = try await driver.executeStatement("UPDATE t SET label = 'x' WHERE id = 1")
            #expect(update.columns.isEmpty)
            #expect(update.affectedRows == 0)
        }
    }

    @Test func parameterErrorsShowTheServerMessage() async throws {
        try await withDatabase { driver, _ in
            do {
                _ = try await driver.executeStatement("SELECT * FROM missing WHERE id = ?", parameters: [.integer(1)])
                Issue.record("expected an error")
            } catch {
                #expect(error.localizedDescription.contains("missing"))
                #expect(!error.localizedDescription.contains("MySQL error"))
            }
        }
    }

    @Test func unpreparableStatementsFallBackToTextProtocol() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("CREATE TABLE t (id int PRIMARY KEY)")
            // LOCK TABLES and CREATE PROCEDURE can't be prepared (ER_UNSUPPORTED_PS).
            _ = try await driver.executeStatement("LOCK TABLES t WRITE")
            _ = try await driver.executeStatement("INSERT INTO t VALUES (1)")
            _ = try await driver.executeStatement("UNLOCK TABLES")
            _ = try await driver.executeStatement("CREATE PROCEDURE p() BEGIN SELECT 1; END")
            #expect(try await driver.listObjects(schema: db).contains { $0.name == "p" && $0.kind == .routine })
            let text = try await driver.executeStatement("SHOW CREATE PROCEDURE p")
            #expect(!text.rows.isEmpty)
        }
    }

    @Test func gridChangesCommitAndRollBack() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("CREATE TABLE items (id int AUTO_INCREMENT PRIMARY KEY, name varchar(20) NOT NULL DEFAULT '', qty int DEFAULT 7) ENGINE=InnoDB")
            try await driver.applyChanges([
                .insert(values: [ColumnValue("name", .text("a"))]),
                .insert(values: [ColumnValue("name", .text("b")), ColumnValue("qty", .text("3"))]),
            ], table: "items", schema: db)
            let order = [OrderBy(column: "id", direction: .ascending)]
            #expect(try await driver.fetchPage(table: "items", schema: db, offset: 0, limit: 10, orderBy: order).rows.map { $0[2] } == [.integer(7), .integer(3)])

            await #expect(throws: DatabaseError.self) {
                try await driver.applyChanges([
                    .update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("name", .text("changed"))]),
                    .update(key: [ColumnValue("id", .integer(2))], values: [ColumnValue("name", .null)]),
                ], table: "items", schema: db)
            }
            let names = try await driver.fetchPage(table: "items", schema: db, offset: 0, limit: 10, orderBy: order).rows.map { $0[1] }
            #expect(names == [.text("a"), .text("b")], "the failed batch was rolled back")

            await #expect(throws: DatabaseError.self) {
                try await driver.applyChanges([.delete(key: [ColumnValue("id", .integer(999))])], table: "items", schema: db)
            }
            try await driver.applyChanges([.insert(values: [])], table: "items", schema: db)
            #expect(try await driver.countRows(table: "items", schema: db) == 3)
        }
    }

    @Test func editedValuesRoundTripAsTypedParameters() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("""
                CREATE TABLE t (id int AUTO_INCREMENT PRIMARY KEY, n int, big bigint, f double, b tinyint(1), d date, ts datetime,
                                raw varbinary(16), amount decimal(8,3), note text, qty int DEFAULT 7) ENGINE=InnoDB
                """)
            let columns = try await driver.listColumns(table: "t", schema: db)
            let bytes = Data([0x00, 0x27, 0x5c, 0xff])
            try await driver.applyChanges([.insert(values: [
                ColumnValue("n", .text("42")), ColumnValue("big", .text("9007199254740993")), ColumnValue("f", .text("2.5")),
                ColumnValue("b", .text("1")), ColumnValue("d", .text("2024-02-29")), ColumnValue("ts", .text("2024-02-29 13:45:00")),
                ColumnValue("raw", .blob(bytes)), ColumnValue("amount", .text("12.345")), ColumnValue("note", .text("O'Hara \\ x")),
            ])], table: "t", schema: db, columns: columns)
            let row = try #require(try await driver.executeStatement(
                "SELECT id, n, big, f, b, CAST(d AS CHAR), CAST(ts AS CHAR), raw, CAST(amount AS CHAR), note, qty FROM t").rows.first)
            #expect(Array(row.dropFirst()) == [.integer(42), .integer(9_007_199_254_740_993), .double(2.5), .integer(1), .text("2024-02-29"),
                                               .text("2024-02-29 13:45:00"), .blob(bytes), .text("12.345"), .text("O'Hara \\ x"), .integer(7)])

            try await driver.applyChanges([
                .update(key: [ColumnValue("id", row[0])], values: [ColumnValue("n", .text("-5")), ColumnValue("raw", .blob(Data())), .defaultValue("qty")]),
            ], table: "t", schema: db, columns: columns)
            #expect(try await driver.executeStatement("SELECT n, raw, qty FROM t").rows == [[.integer(-5), .blob(Data()), .integer(7)]])
        }
    }

    @Test func designerAltersRealTable() async throws {
        try await withDatabase { driver, db in
            let dialect = driver.dialect
            _ = try await driver.executeStatement(try dialect.createTable(name: "people", schema: db, columns: [
                ColumnDesign(name: "id", type: "int", nullable: false, isPrimaryKey: true),
                ColumnDesign(name: "name", type: "varchar(45)"),
            ]))
            let before = try await driver.listColumns(table: "people", schema: db)
            var design = before.map(ColumnDesign.init)
            design[1].name = "full_name"
            design[1].type = "varchar(100)"
            design[1].nullable = false
            design.append(ColumnDesign(name: "active", type: "tinyint(1)", defaultValue: "1"))
            for statement in try dialect.alterTable(name: "people", schema: db, original: before, design: design) {
                _ = try await driver.executeStatement(statement)
            }
            let after = try await driver.listColumns(table: "people", schema: db)
            #expect(after.map(\.name) == ["id", "full_name", "active"])
            #expect(after[1].dataType == "varchar(100)")
            #expect(after[1].nullable == false)
            #expect(after[2].defaultValue == "1")
            #expect(try dialect.alterTable(name: "people", schema: db, original: after, design: after.map(ColumnDesign.init)).isEmpty)
        }
    }

    /// MODIFY COLUMN rewrites the whole definition: string defaults must come back quoted, and AUTO_INCREMENT,
    /// ON UPDATE and comments must be repeated or the server drops them.
    @Test func designerModifyKeepsDefaultsAndAttributes() async throws {
        try await withDatabase { driver, db in
            let dialect = driver.dialect
            _ = try await driver.executeStatement("""
                CREATE TABLE t (id int NOT NULL AUTO_INCREMENT PRIMARY KEY COMMENT 'the key',
                                label varchar(20) DEFAULT 'it''s', plain varchar(5), touched datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                                qty int NOT NULL DEFAULT 3) ENGINE=InnoDB
                """)
            let before = try await driver.listColumns(table: "t", schema: db)
            #expect(before[1].defaultValue == "'it''s'")
            #expect(before[2].defaultValue == nil)
            #expect(before[4].defaultValue == "3")
            #expect(try dialect.alterTable(name: "t", schema: db, original: before, design: before.map(ColumnDesign.init)).isEmpty)

            var design = before.map(ColumnDesign.init)
            design[0].type = "bigint"
            design[1].type = "varchar(40)"
            design[2].type = "varchar(10)"
            design[3].nullable = false
            design[4].type = "bigint"
            for statement in try dialect.alterTable(name: "t", schema: db, original: before, design: design) {
                _ = try await driver.executeStatement(statement)
            }
            let after = try await driver.listColumns(table: "t", schema: db)
            #expect(after[0].extra == "AUTO_INCREMENT COMMENT 'the key'")
            #expect(after[1].defaultValue == "'it''s'")
            #expect(after[1].dataType == "varchar(40)")
            #expect(after[2].defaultValue == nil)
            #expect(after[3].extra?.uppercased().hasPrefix("ON UPDATE CURRENT_TIMESTAMP") == true)
            #expect(after[4].defaultValue == "3")
            _ = try await driver.executeStatement("INSERT INTO t () VALUES ()")
            #expect(try await driver.executeStatement("SELECT id, label FROM t").rows == [[.integer(1), .text("it's")]])
        }
    }

    @Test func designerIndexesOnRealTable() async throws {
        try await withDatabase { driver, db in
            let dialect = driver.dialect
            _ = try await driver.executeStatement("CREATE TABLE t (id int PRIMARY KEY, email varchar(80), city varchar(40))")
            var design = try await driver.listIndexes(table: "t", schema: db).map(IndexDesign.init)
            design.append(IndexDesign(name: "t_email_key", columns: ["email"], unique: true))
            design.append(IndexDesign(name: "t_city_idx", columns: ["city", "email"]))
            for statement in try dialect.alterIndexes(table: "t", schema: db, original: try await driver.listIndexes(table: "t", schema: db), design: design) {
                _ = try await driver.executeStatement(statement)
            }
            var after = try await driver.listIndexes(table: "t", schema: db)
            #expect(after.contains { $0.name == "t_email_key" && $0.unique })
            #expect(after.contains { $0.name == "t_city_idx" && $0.columns == ["city", "email"] })
            let trimmed = after.map(IndexDesign.init).filter { $0.name != "t_city_idx" }
            for statement in try dialect.alterIndexes(table: "t", schema: db, original: after, design: trimmed) {
                _ = try await driver.executeStatement(statement)
            }
            after = try await driver.listIndexes(table: "t", schema: db)
            #expect(!after.contains { $0.name == "t_city_idx" })
            #expect(after.contains { $0.primary })
        }
    }

    @Test func designerForeignKeysOnRealTables() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.execute("""
                CREATE TABLE customers (id int PRIMARY KEY, region char(2), code int, UNIQUE KEY region_code (region, code)) ENGINE=InnoDB;
                CREATE TABLE orders (id int PRIMARY KEY, customer_id int, region char(2), code int) ENGINE=InnoDB;
                INSERT INTO customers VALUES (1, 'BR', 7);
                INSERT INTO orders VALUES (10, 1, 'BR', 7);
                """)
            let dialect = driver.dialect
            let byCustomer = TableForeignKey(name: "fk_orders_customer", columns: ["customer_id"], referencedSchema: db,
                                             referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE")
            let byRegion = TableForeignKey(name: "fk_orders_region", columns: ["region", "code"], referencedSchema: db,
                                           referencedTable: "customers", referencedColumns: ["region", "code"])
            let add = try dialect.alterForeignKeys(table: "orders", schema: db, original: [],
                                                   design: [ForeignKeyDesign(key: byCustomer), ForeignKeyDesign(key: byRegion)])
            for statement in add.drops + add.adds { _ = try await driver.executeStatement(statement) }
            let keys = try await driver.listForeignKeys(table: "orders", schema: db)
            #expect(keys.map(\.name) == ["fk_orders_customer", "fk_orders_region"])
            #expect(keys.last?.columns == ["region", "code"])
            #expect(keys.last?.referencedColumns == ["region", "code"])
            #expect(keys.first?.onDelete == "CASCADE")
            // MariaDB reports an unspecified rule as RESTRICT (the same thing in InnoDB).
            #expect(keys.first?.onUpdate == (MySQL.kind == .mariadb ? "RESTRICT" : "NO ACTION"))
            #expect(!SQLDialect.foreignKeysChanged(original: keys, design: keys.map(ForeignKeyDesign.init)))

            var changed = ForeignKeyDesign(keys[0])
            changed.key.onUpdate = "RESTRICT"
            let alter = try dialect.alterForeignKeys(table: "orders", schema: db, original: keys, design: [changed])
            for statement in alter.drops + alter.adds { _ = try await driver.executeStatement(statement) }
            let after = try await driver.listForeignKeys(table: "orders", schema: db)
            #expect(after.map(\.name) == ["fk_orders_customer"])
            #expect(after.first?.onUpdate == "RESTRICT")
            #expect(after.first?.onDelete == "CASCADE")
            _ = try await driver.executeStatement("DELETE FROM customers WHERE id = 1")
            #expect(try await driver.countRows(table: "orders", schema: db) == 0, "ON DELETE CASCADE is in force")
        }
    }

    @Test func manualTransactionIsIsolatedUntilCommit() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("CREATE TABLE t (id int AUTO_INCREMENT PRIMARY KEY, v varchar(10)) ENGINE=InnoDB")
            let dedicated = try await MySQL.driver(database: db)
            _ = try await dedicated.executeStatement(dedicated.dialect.beginTransaction)
            try await dedicated.applyChanges([.insert(values: [ColumnValue("v", .text("pending"))])], table: "t", schema: db, inOpenTransaction: true)
            #expect(try await dedicated.countRows(table: "t", schema: db) == 1)
            #expect(try await driver.countRows(table: "t", schema: db) == 0, "other connections don't see uncommitted rows")
            _ = try await dedicated.executeStatement("COMMIT")
            #expect(try await driver.countRows(table: "t", schema: db) == 1)
            await dedicated.disconnect()
        }
    }

    @Test func generatedDataInserts() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.executeStatement("""
                CREATE TABLE people (id int AUTO_INCREMENT PRIMARY KEY, full_name varchar(12) NOT NULL, email varchar(80), active tinyint(1),
                  score decimal(4,2), born date, created_at timestamp DEFAULT CURRENT_TIMESTAMP)
                """)
            let columns = try await driver.listColumns(table: "people", schema: db)
            let plan = columns.map { (name: $0.name, generator: ValueGenerator.suggested(for: $0)) }
            let types = Dictionary(columns.map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first })
            try await driver.applyChanges(ValueGenerator.rows(count: 200, columns: plan, types: types, seed: 5), table: "people", schema: db)
            #expect(try await driver.countRows(table: "people", schema: db) == 200)
        }
    }

    @Test func tableStatisticsForObjectsTab() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.execute("""
                CREATE TABLE t (id int PRIMARY KEY) ENGINE=InnoDB COMMENT='Some rows';
                INSERT INTO t VALUES (1), (2), (3);
                ANALYZE TABLE t
                """)
            let stats = try await driver.tableStatistics(schema: db)
            #expect(stats["t"]?.engine == "InnoDB")
            #expect(stats["t"]?.comment == "Some rows")
            #expect((stats["t"]?.sizeBytes ?? 0) > 0)
            #expect(stats["t"]?.created != nil)
        }
    }

    @Test func dumpRestoresIntoAnotherDatabase() async throws {
        try await withDatabase { source, db in
            _ = try await source.execute("""
                CREATE TABLE parent (id int PRIMARY KEY, name varchar(20)) ENGINE=InnoDB;
                CREATE TABLE child (id int PRIMARY KEY, parent_id int, note text,
                  FOREIGN KEY (parent_id) REFERENCES parent (id)) ENGINE=InnoDB;
                INSERT INTO parent VALUES (1, 'O''Brien'), (2, 'back\\\\slash');
                INSERT INTO child VALUES (10, 1, 'line\\nbreak'), (11, 2, NULL);
                CREATE VIEW child_names AS SELECT c.id, p.name FROM child c JOIN parent p ON p.id = c.parent_id;
                """)
            let objects = try await source.listObjects(schema: db).filter { $0.kind != .routine }
            let script = try await SQLDumper.dump(objects, from: source, options: SQLDumpOptions(rowsPerInsert: 50))
            #expect(script.contains("SET FOREIGN_KEY_CHECKS = 0;"))
            #expect(!script.contains("`\(db)`.`child`"), "bare names, so the dump restores anywhere")

            try await withDatabase { target, _ in
                let report = await target.runScript(SQLSplitter.split(script))
                #expect(report.errors.isEmpty, "\(report.errors.map(\.message))")
                let restored = try await target.fetchAllRows(table: "parent", schema: nil)
                #expect(restored.rows == [[.integer(1), .text("O'Brien")], [.integer(2), .text("back\\slash")]])
                #expect(try await target.fetchAllRows(table: "child", schema: nil).rows[0][2] == .text("line\nbreak"))
                #expect(try await target.countRows(table: "child_names", schema: nil) == 2)
            }
        }
    }

    @Test func exportsWorkbookAndCSV() async throws {
        try await withDatabase { driver, db in
            _ = try await driver.execute("CREATE TABLE t (id int PRIMARY KEY, v varchar(10)); INSERT INTO t VALUES (1, 'a,b'), (2, NULL)")
            let object = DatabaseObject(schema: db, name: "t", kind: .table)
            let csv = String(decoding: try await TableExporter.export(object, from: driver, as: .csv), as: UTF8.self)
            #expect(csv == "id,v\r\n1,\"a,b\"\r\n2,\r\n")
            let xlsx = try await TableExporter.export(object, from: driver, as: .xlsx)
            #expect(ZipReader.entries(xlsx)?["xl/worksheets/sheet1.xml"] != nil)
        }
    }

    @Test func runsAMysqldumpStyleScript() async throws {
        try await withDatabase { driver, db in
            let script = """
                /*!40101 SET NAMES utf8mb4 */;
                DROP TABLE IF EXISTS `t`;
                CREATE TABLE `t` (`id` int NOT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB;
                LOCK TABLES `t` WRITE;
                INSERT INTO `t` VALUES (1),(2);
                UNLOCK TABLES;
                DELIMITER ;;
                CREATE TRIGGER t_bi BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.id = NEW.id * 10; END ;;
                DELIMITER ;
                INSERT INTO `t` VALUES (3);
                """
            let report = await driver.runScript(SQLSplitter.split(script))
            #expect(report.errors.isEmpty, "\(report.errors.map(\.message))")
            let ids = try await driver.fetchAllRows(table: "t", schema: db).rows.map { $0[0] }
            #expect(ids == [.integer(1), .integer(2), .integer(30)])
        }
    }

    @Test func userManagerRoundTrip() async throws {
        let driver = try await MySQL.driver()
        let dialect = driver.dialect
        let name = "bg_user_\(UUID().uuidString.prefix(6).lowercased())"
        do {
            for statement in try dialect.createUser(UserDraft(name: name, password: "first'pass", host: "%", createDatabases: true)) {
                _ = try await driver.executeStatement(statement)
            }
            let users = dialect.users(from: try await driver.executeStatement(try #require(dialect.listUsersSQL)))
            let user = try #require(users.first { $0.name == name })
            #expect(user.host == "%")
            #expect(user.attributes == ["Create"])
            let grants = try await driver.executeStatement(try #require(dialect.grantsSQL(user)))
            #expect(grants.rows.contains { $0.first?.displayString.contains("CREATE") == true })
            _ = try await driver.executeStatement(dialect.setPassword(user, to: "second"))

            var config = MySQL.config(tls: .prefer)
            config.username = name
            let login = MySQLDriver(config: config, password: "second")
            try await login.connect()
            await login.disconnect()
            _ = try await driver.executeStatement(dialect.dropUser(user))
        } catch {
            _ = try? await driver.executeStatement("DROP USER IF EXISTS '\(name)'@'%'")
            await driver.disconnect()
            throw error
        }
        await driver.disconnect()
    }

    @Test func readOnlyConnectionsRejectWrites() async throws {
        let driver = try await MySQL.driver(readOnly: true)
        await #expect(throws: DatabaseError.self) { try await driver.execute("CREATE DATABASE should_not_exist") }
        #expect(try await driver.execute("SELECT 2").first?.rows == [[.integer(2)]])
        await driver.disconnect()
    }
}

/// SSL, socket file and SSH tunnel against MySQL/MariaDB. Each case is skipped unless its variables are set:
/// `BUNNYGRID_MYSQL_SSL_CA` (CA of a server with SSL on), `BUNNYGRID_MYSQL_SSL_CERT` / `_KEY` / `_USER` (client
/// certificate for a user created `REQUIRE X509`), `BUNNYGRID_MYSQL_SOCKET` (the server's socket file), and
/// `BUNNYGRID_SSH_PORT` / `BUNNYGRID_SSH_USER` / `BUNNYGRID_SSH_KEYS` (an sshd that reaches the server; key `user_ecdsa`).
@Suite(.enabled(if: MySQL.enabled, "set BUNNYGRID_MYSQL_PORT to run against MySQL/MariaDB"), .serialized)
struct MySQLConnectivityIntegrationTests {
    private static let env = ProcessInfo.processInfo.environment

    private func ping(_ config: ConnectionConfig, secrets: ConnectionSecrets = ConnectionSecrets(password: MySQL.password)) async throws -> MySQLDriver {
        let driver = MySQLDriver(config: config, secrets: secrets)
        try await driver.connect()
        #expect(try await driver.execute("SELECT 1").first?.rows.first?.first?.displayString == "1")
        return driver
    }

    @Test(.enabled(if: env["BUNNYGRID_MYSQL_SSL_CA"] != nil, "set BUNNYGRID_MYSQL_SSL_CA"))
    func verifiedSSL() async throws {
        var config = MySQL.config(tls: .verifyCA)
        config.ssl = SSLFiles(caCertificatePath: Self.env["BUNNYGRID_MYSQL_SSL_CA"] ?? "")
        let driver = try await ping(config)
        let cipher = try await driver.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.rows.first?.last?.displayString ?? ""
        #expect(!cipher.isEmpty)
        await driver.disconnect()
        config.ssl = SSLFiles(caCertificatePath: "/nonexistent/ca.pem")
        let failing = MySQLDriver(config: config, secrets: ConnectionSecrets(password: MySQL.password))
        await #expect(throws: DatabaseError.self) { try await failing.connect() }
    }

    @Test(.enabled(if: env["BUNNYGRID_MYSQL_SSL_CERT"] != nil && env["BUNNYGRID_MYSQL_SSL_USER"] != nil, "set BUNNYGRID_MYSQL_SSL_CERT, _KEY and _USER"))
    func clientCertificate() async throws {
        var config = MySQL.config(tls: .require)
        config.username = Self.env["BUNNYGRID_MYSQL_SSL_USER"] ?? ""
        config.ssl = SSLFiles(clientCertificatePath: Self.env["BUNNYGRID_MYSQL_SSL_CERT"] ?? "", clientKeyPath: Self.env["BUNNYGRID_MYSQL_SSL_KEY"] ?? "")
        let driver = try await ping(config, secrets: ConnectionSecrets())
        await driver.disconnect()
    }

    @Test(.enabled(if: env["BUNNYGRID_MYSQL_SOCKET"] != nil, "set BUNNYGRID_MYSQL_SOCKET"))
    func socketFile() async throws {
        var config = MySQL.config()
        config.host = "no-such-host.invalid"
        config.socketPath = Self.env["BUNNYGRID_MYSQL_SOCKET"]
        let driver = try await ping(config)
        await driver.disconnect()
    }

    @Test(.enabled(if: env["BUNNYGRID_SSH_PORT"] != nil && env["BUNNYGRID_SSH_KEYS"] != nil, "set BUNNYGRID_SSH_PORT and BUNNYGRID_SSH_KEYS"))
    func sshTunnelAndCancel() async throws {
        var config = MySQL.config()
        config.ssh = SSHTunnelConfig(
            enabled: true, host: "127.0.0.1", port: Int(Self.env["BUNNYGRID_SSH_PORT"] ?? "") ?? 22,
            username: Self.env["BUNNYGRID_SSH_USER"] ?? NSUserName(), authMethod: .publicKey,
            privateKeyPath: ((Self.env["BUNNYGRID_SSH_KEYS"] ?? "") as NSString).appendingPathComponent("user_ecdsa"))
        let driver = try await ping(config)
        // KILL QUERY goes over a second connection through the same tunnel.
        let sleeper = Task { try await driver.executeStatement("SELECT SLEEP(20)") }
        try await Task.sleep(for: .milliseconds(500))
        try await driver.cancelCurrentQuery()
        let started = ContinuousClock.now
        _ = try? await sleeper.value
        #expect(ContinuousClock.now - started < .seconds(10))
        await driver.disconnect()
    }
}
