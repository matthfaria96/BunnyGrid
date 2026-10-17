import Foundation
import Testing
@testable import BunnyGridCore

/// Runs against a real PostgreSQL server when `BUNNYGRID_PG_PORT` is set, e.g.
/// `BUNNYGRID_PG_PORT=54329 BUNNYGRID_PG_USER=bunny BUNNYGRID_PG_PASSWORD=… BUNNYGRID_PG_DATABASE=bunnytest swift test`.
private enum PG {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["BUNNYGRID_PG_PORT"] != nil

    static func config(tls: TLSMode = .prefer, readOnly: Bool = false, database: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            kind: .postgresql,
            host: env["BUNNYGRID_PG_HOST"] ?? "localhost",
            port: Int(env["BUNNYGRID_PG_PORT"] ?? "") ?? 5432,
            username: env["BUNNYGRID_PG_USER"] ?? "postgres",
            database: database ?? env["BUNNYGRID_PG_DATABASE"] ?? "postgres",
            tls: tls,
            readOnly: readOnly
        )
    }

    static var password: String? { env["BUNNYGRID_PG_PASSWORD"] }

    static func driver(tls: TLSMode = .prefer, readOnly: Bool = false) async throws -> PostgresDriver {
        let driver = PostgresDriver(config: config(tls: tls, readOnly: readOnly), password: password)
        try await driver.connect()
        return driver
    }
}

@Suite(.enabled(if: PG.enabled, "set BUNNYGRID_PG_PORT to run against PostgreSQL"), .serialized)
struct PostgresIntegrationTests {
    /// A schema of its own per test, dropped afterwards.
    private func withSchema(_ body: (PostgresDriver, String) async throws -> Void) async throws {
        let driver = try await PG.driver()
        let schema = "bg_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.executeStatement("CREATE SCHEMA \(schema)")
        do {
            try await body(driver, schema)
        } catch {
            _ = try? await driver.executeStatement("DROP SCHEMA \(schema) CASCADE")
            await driver.disconnect()
            throw error
        }
        _ = try await driver.executeStatement("DROP SCHEMA \(schema) CASCADE")
        await driver.disconnect()
    }

    @Test func connectsWithPasswordAndListsCatalog() async throws {
        let driver = try await PG.driver()
        #expect(try await driver.serverVersion().hasPrefix("PostgreSQL"))
        #expect(try await driver.listDatabases().contains("postgres"))
        let schemas = try await driver.listSchemas()
        #expect(schemas.contains("public"))
        #expect(schemas.contains("pg_catalog"))
        #expect(schemas.contains("information_schema"))
        await driver.disconnect()
    }

    @Test func wrongPasswordFailsClearly() async {
        let driver = PostgresDriver(config: PG.config(), password: "definitely-wrong")
        await #expect(throws: DatabaseError.self) { try await driver.connect() }
    }

    @Test func tlsDisableAlsoConnects() async throws {
        let driver = try await PG.driver(tls: .disable)
        #expect(try await driver.execute("SELECT 1").first?.rows == [[.integer(1)]])
        await driver.disconnect()
    }

    @Test func listsObjectsAndNavicatStyleTypes() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.execute("""
                CREATE TABLE \(schema).payment (
                  payment_id serial PRIMARY KEY,
                  customer_id int2 NOT NULL,
                  amount numeric(5,2) NOT NULL DEFAULT 0,
                  note varchar(40),
                  payment_date timestamp(6)
                );
                CREATE VIEW \(schema).big_payments AS SELECT * FROM \(schema).payment WHERE amount > 5;
                CREATE MATERIALIZED VIEW \(schema).totals AS SELECT customer_id, sum(amount) FROM \(schema).payment GROUP BY 1;
                CREATE FUNCTION \(schema).double_it(x int) RETURNS int AS $$ SELECT x * 2 $$ LANGUAGE sql;
                CREATE INDEX payment_customer_idx ON \(schema).payment (customer_id, payment_date);
                """)
            let objects = try await driver.listObjects(schema: schema)
            #expect(objects.contains(DatabaseObject(schema: schema, name: "payment", kind: .table)))
            #expect(objects.contains(DatabaseObject(schema: schema, name: "big_payments", kind: .view)))
            #expect(objects.contains(DatabaseObject(schema: schema, name: "totals", kind: .materializedView)))
            #expect(objects.contains(DatabaseObject(schema: schema, name: "double_it", kind: .routine)))

            let columns = try await driver.listColumns(table: "payment", schema: schema)
            #expect(columns.map(\.dataType) == ["int4", "int2", "numeric(5,2)", "varchar(40)", "timestamp(6)"])
            #expect(columns.first?.isPrimaryKey == true)
            #expect(columns[2].nullable == false)

            let indexes = try await driver.listIndexes(table: "payment", schema: schema)
            #expect(indexes.contains { $0.name == "payment_customer_idx" && $0.columns == ["customer_id", "payment_date"] })
            #expect(indexes.contains { $0.primary })
        }
    }

    @Test func decodesValueTypes() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.execute("""
                CREATE TABLE \(schema).t (i int8, n numeric(8,3), f float8, b bool, s text, d date, ts timestamp,
                                          u uuid, j jsonb, raw bytea, empty text);
                INSERT INTO \(schema).t VALUES (42, 12.345, 1.5, true, 'olá', '2024-02-29', '2024-02-29 13:45:00',
                  'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '{"a": 1}', '\\x0102ff', NULL);
                """)
            let row = try #require(try await driver.fetchPage(table: "t", schema: schema, offset: 0, limit: 10).rows.first)
            #expect(row[0] == .integer(42))
            #expect(row[1] == .text("12.345"))
            #expect(row[2] == .double(1.5))
            #expect(row[3] == .bool(true))
            #expect(row[4] == .text("olá"))
            #expect(row[5] == .text("2024-02-29"))
            #expect(row[6] == .text("2024-02-29 13:45:00"))
            #expect(row[7] == .text("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
            #expect(row[8] == .text(#"{"a": 1}"#))
            #expect(row[9] == .blob(Data([0x01, 0x02, 0xff])))
            #expect(row[10] == .null)
        }
    }

    @Test func reportsAffectedRowsAndErrors() async throws {
        try await withSchema { driver, schema in
            let results = try await driver.execute("""
                CREATE TABLE \(schema).t (id int PRIMARY KEY, v text);
                INSERT INTO \(schema).t VALUES (1, 'a'), (2, 'b'), (3, 'c');
                UPDATE \(schema).t SET v = 'z' WHERE id > 1;
                DELETE FROM \(schema).t WHERE id = 1 RETURNING id
                """)
            #expect(results[1].affectedRows == 3)
            #expect(results[2].affectedRows == 2)
            #expect(results[3].columns == ["id"])
            #expect(results[3].rows == [[.integer(1)]])
            await #expect(throws: DatabaseError.self) { try await driver.execute("SELECT * FROM \(schema).missing") }
            // The connection keeps working after an error.
            #expect(try await driver.countRows(table: "t", schema: schema) == 2)
        }
    }

    @Test func gridChangesCommitAndRollBack() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.execute("CREATE TABLE \(schema).items (id serial PRIMARY KEY, name text NOT NULL, qty int DEFAULT 7)")
            try await driver.applyChanges([
                .insert(values: [ColumnValue("name", .text("a"))]),
                .insert(values: [ColumnValue("name", .text("b")), ColumnValue("qty", .text("3"))]),
            ], table: "items", schema: schema)
            let page = try await driver.fetchPage(table: "items", schema: schema, offset: 0, limit: 10, orderBy: [OrderBy(column: "id", direction: .ascending)])
            #expect(page.rows.map { $0[2] } == [.integer(7), .integer(3)])

            await #expect(throws: DatabaseError.self) {
                try await driver.applyChanges([
                    .update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("name", .text("changed"))]),
                    .update(key: [ColumnValue("id", .integer(2))], values: [ColumnValue("name", .null)]),
                ], table: "items", schema: schema)
            }
            let names = try await driver.fetchPage(table: "items", schema: schema, offset: 0, limit: 10, orderBy: [OrderBy(column: "id", direction: .ascending)]).rows.map { $0[1] }
            #expect(names == [.text("a"), .text("b")])

            await #expect(throws: DatabaseError.self) {
                try await driver.applyChanges([.delete(key: [ColumnValue("id", .integer(999))])], table: "items", schema: schema)
            }
        }
    }

    @Test func designerAltersRealTable() async throws {
        try await withSchema { driver, schema in
            let dialect = SQLDialect(kind: .postgresql)
            _ = try await driver.executeStatement(try dialect.createTable(name: "people", schema: schema, columns: [
                ColumnDesign(name: "id", type: "serial", nullable: false, isPrimaryKey: true),
                ColumnDesign(name: "name", type: "varchar(45)"),
            ]))
            let before = try await driver.listColumns(table: "people", schema: schema)
            var design = before.map(ColumnDesign.init)
            design[1].name = "full_name"
            design[1].type = "varchar(100)"
            design[1].nullable = false
            design.append(ColumnDesign(name: "active", type: "bool", defaultValue: "true"))
            // Existing rows need a value before NOT NULL; the table is empty here.
            for statement in try dialect.alterTable(name: "people", schema: schema, original: before, design: design) {
                _ = try await driver.executeStatement(statement)
            }
            let after = try await driver.listColumns(table: "people", schema: schema)
            #expect(after.map(\.name) == ["id", "full_name", "active"])
            #expect(after[1].dataType == "varchar(100)")
            #expect(after[1].nullable == false)
            #expect(after[2].defaultValue == "true")
            // Re-running the plan on the new state is a no-op.
            #expect(try dialect.alterTable(name: "people", schema: schema, original: after, design: after.map(ColumnDesign.init)).isEmpty)
        }
    }

    @Test func manualTransactionIsIsolatedUntilCommit() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.executeStatement("CREATE TABLE \(schema).t (id serial PRIMARY KEY, v text)")
            let dedicated = try await PG.driver()
            _ = try await dedicated.executeStatement("BEGIN")
            try await dedicated.applyChanges([.insert(values: [ColumnValue("v", .text("pending"))])], table: "t", schema: schema, inOpenTransaction: true)
            #expect(try await dedicated.countRows(table: "t", schema: schema) == 1)
            #expect(try await driver.countRows(table: "t", schema: schema) == 0, "other connections don't see uncommitted rows")
            _ = try await dedicated.executeStatement("COMMIT")
            #expect(try await driver.countRows(table: "t", schema: schema) == 1)
            await dedicated.disconnect()
        }
    }

    @Test func designerIndexesOnRealTable() async throws {
        try await withSchema { driver, schema in
            let dialect = SQLDialect(kind: .postgresql)
            _ = try await driver.executeStatement("CREATE TABLE \(schema).t (id serial PRIMARY KEY, email text, city text)")
            var design = try await driver.listIndexes(table: "t", schema: schema).map(IndexDesign.init)
            design.append(IndexDesign(name: "t_email_key", columns: ["email"], unique: true))
            design.append(IndexDesign(name: "t_city_idx", columns: ["city", "email"]))
            for statement in try dialect.alterIndexes(table: "t", schema: schema, original: try await driver.listIndexes(table: "t", schema: schema), design: design) {
                _ = try await driver.executeStatement(statement)
            }
            var after = try await driver.listIndexes(table: "t", schema: schema)
            #expect(after.contains { $0.name == "t_email_key" && $0.unique })
            #expect(after.contains { $0.name == "t_city_idx" && $0.columns == ["city", "email"] })
            // Remove one again.
            let trimmed = after.map(IndexDesign.init).filter { $0.name != "t_city_idx" }
            for statement in try dialect.alterIndexes(table: "t", schema: schema, original: after, design: trimmed) {
                _ = try await driver.executeStatement(statement)
            }
            after = try await driver.listIndexes(table: "t", schema: schema)
            #expect(!after.contains { $0.name == "t_city_idx" })
            #expect(after.contains { $0.primary })
        }
    }

    @Test func generatedDataInsertsIntoPostgres() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.executeStatement("""
                CREATE TABLE \(schema).people (id serial PRIMARY KEY, full_name varchar(12) NOT NULL, email text, active bool,
                  score numeric(4,2), born date, created_at timestamptz DEFAULT now(), ref uuid)
                """)
            let columns = try await driver.listColumns(table: "people", schema: schema)
            let plan = columns.map { (name: $0.name, generator: ValueGenerator.suggested(for: $0)) }
            #expect(plan.first { $0.name == "id" }?.generator == .skip)
            #expect(plan.first { $0.name == "created_at" }?.generator == .skip)
            let types = Dictionary(columns.map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first })
            try await driver.applyChanges(ValueGenerator.rows(count: 500, columns: plan, types: types, seed: 11), table: "people", schema: schema)
            #expect(try await driver.countRows(table: "people", schema: schema) == 500)
        }
    }

    @Test func tableStatisticsForObjectsTab() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.execute("""
                CREATE TABLE \(schema).t (id int);
                INSERT INTO \(schema).t SELECT generate_series(1, 300);
                COMMENT ON TABLE \(schema).t IS 'Three hundred rows';
                ANALYZE \(schema).t
                """)
            let stats = try await driver.tableStatistics(schema: schema)
            #expect(stats["t"]?.rows == 300)
            #expect((stats["t"]?.sizeBytes ?? 0) > 0)
            #expect(stats["t"]?.comment == "Three hundred rows")
        }
    }

    @Test func dumpRunsBackAsAScript() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.execute("""
                CREATE TABLE \(schema).t (id serial PRIMARY KEY, name text, amount numeric(6,2), ok bool, raw bytea, at timestamp);
                INSERT INTO \(schema).t (name, amount, ok, raw, at) VALUES
                  ('O''Brien \\ slash', 12.5, true, '\\x00ff', '2024-02-29 13:45:00'), (NULL, NULL, NULL, NULL, NULL);
                CREATE VIEW \(schema).named AS SELECT * FROM \(schema).t WHERE name IS NOT NULL;
                """)
            let objects = try await driver.listObjects(schema: schema).filter { $0.kind != .routine }
            let before = try await driver.fetchAllRows(table: "t", schema: schema)
            let script = try await SQLDumper.dump(objects, from: driver, options: SQLDumpOptions(rowsPerInsert: 10))
            _ = try await driver.execute("DROP VIEW \(schema).named; DROP TABLE \(schema).t")
            let report = await driver.runScript(SQLSplitter.split(script), options: ScriptRunOptions(useTransaction: true))
            #expect(report.errors.isEmpty, "\(report.errors.map(\.message))")
            #expect(try await driver.fetchAllRows(table: "t", schema: schema).rows == before.rows)
            #expect(try await driver.countRows(table: "named", schema: schema) == 1)
            // The serial sequence came back and continues after the restored ids.
            _ = try await driver.executeStatement("INSERT INTO \(schema).t (name) VALUES ('next')")
            #expect(try await driver.execute("SELECT max(id) FROM \(schema).t").first?.rows == [[.integer(3)]])
        }
    }

    @Test func scriptErrorRollsBackTheTransaction() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.executeStatement("CREATE TABLE \(schema).t (id int PRIMARY KEY)")
            let report = await driver.runScript(["INSERT INTO \(schema).t VALUES (1)", "INSERT INTO \(schema).t VALUES (1)"],
                                                options: ScriptRunOptions(stopOnError: true, useTransaction: true))
            #expect(report.rolledBack)
            #expect(report.errors.first?.message.contains("duplicate key") == true)
            #expect(try await driver.countRows(table: "t", schema: schema) == 0)
        }
    }

    @Test func importsTypedJSONValues() async throws {
        try await withSchema { driver, schema in
            _ = try await driver.executeStatement("CREATE TABLE \(schema).t (id int PRIMARY KEY, price numeric(6,2), ok bool, meta jsonb, note text)")
            let table = try JSONTableReader.read(Data(#"[{"id": 1, "price": 9.99, "ok": true, "meta": {"a": [1, 2]}, "note": null}]"#.utf8))
            let changes = table.rows.map { row in RowChange.insert(values: zip(table.columns, row).map { ColumnValue($0, $1) }) }
            try await driver.applyChanges(changes, table: "t", schema: schema)
            let row = try #require(try await driver.fetchAllRows(table: "t", schema: schema).rows.first)
            #expect(row == [.integer(1), .text("9.99"), .bool(true), .text(#"{"a": [1, 2]}"#), .null])
        }
    }

    @Test func readOnlyConnectionsRejectWrites() async throws {
        let driver = try await PG.driver(readOnly: true)
        await #expect(throws: DatabaseError.self) { try await driver.execute("CREATE TABLE should_not_exist (x int)") }
        #expect(try await driver.execute("SELECT 2").first?.rows == [[.integer(2)]])
        await driver.disconnect()
    }
}
