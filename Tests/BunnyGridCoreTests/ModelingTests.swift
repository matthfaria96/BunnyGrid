import CoreGraphics
import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct ModelingTests {
    private func shop() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT);
            CREATE TABLE products (id INTEGER PRIMARY KEY, title TEXT NOT NULL, price NUMERIC(10,2) DEFAULT 0);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers ON DELETE CASCADE, placed_at DATETIME);
            CREATE TABLE order_items (
              order_id INTEGER NOT NULL REFERENCES orders(id), product_id INTEGER REFERENCES products(id), qty INTEGER DEFAULT 1,
              PRIMARY KEY (order_id, product_id));
            CREATE TABLE profiles (customer_id INTEGER PRIMARY KEY REFERENCES customers(id), bio TEXT);
            CREATE TABLE employees (id INTEGER PRIMARY KEY, manager_id INTEGER REFERENCES employees(id));
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
            CREATE VIEW big_orders AS SELECT * FROM orders;
            """)
        return driver
    }

    @Test func reverseEngineersTablesAndForeignKeys() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        #expect(model.sourceKind == .sqlite)
        #expect(model.tables.map(\.name) == ["customers", "employees", "order_items", "orders", "products", "profiles", "settings"])

        let items = try #require(model.table("order_items"))
        #expect(items.primaryKey == ["order_id", "product_id"])
        #expect(items.columns.map(\.isForeignKey) == [true, true, false])
        #expect(items.columns[1].nullable)

        let order = try #require(model.relationships.first { $0.fromTable == "orders" })
        // `REFERENCES customers` without columns points at the parent's primary key.
        #expect(order.toTable == "customers" && order.fromColumns == ["customer_id"] && order.toColumns == ["id"])
        #expect(order.onDelete == "CASCADE")
        #expect(!order.isOptional && !order.isOneToOne)

        let product = try #require(model.relationships.first { $0.fromTable == "order_items" && $0.toTable == "products" })
        #expect(product.isOptional)
        #expect(model.relationships.first { $0.fromTable == "profiles" }?.isOneToOne == true)
        #expect(model.relationships.first { $0.fromTable == "employees" }?.isSelfReference == true)
        #expect(model.relationships.count == 5)
        #expect(model.neighbors(of: "customers") == ["orders", "profiles"])
    }

    @Test func keysToMissingTablesMarkColumnsButDrawNoLine() {
        let model = ERModel(sourceKind: .postgresql, inputs: [
            .init(schema: "public", name: "a", columns: [TableColumn(name: "b_id", dataType: "int4", nullable: true, ordinal: 1)],
                  foreignKeys: [TableForeignKey(name: "a_b", columns: ["b_id"], referencedSchema: "other", referencedTable: "b", referencedColumns: ["id"])]),
        ])
        #expect(model.tables[0].id == "public.a")
        #expect(model.tables[0].columns[0].isForeignKey)
        #expect(model.relationships.isEmpty)
    }

    // MARK: - Layout

    private func assertNoOverlap(_ model: ERModel, _ positions: [String: CGPoint]) {
        let frames = ERLayout.frames(model, positions: positions)
        #expect(frames.count == model.tables.count)
        let list = frames.sorted { $0.key < $1.key }
        for (i, a) in list.enumerated() {
            for b in list[(i + 1)...] {
                #expect(!a.value.intersects(b.value), "\(a.key) overlaps \(b.key)")
            }
        }
    }

    @Test func autoLayoutIsDeterministicWithoutOverlaps() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        let first = ERLayout.autoLayout(model)
        #expect(first == ERLayout.autoLayout(model))
        // Input order doesn't matter.
        let shuffled = ERModel(sourceKind: model.sourceKind, tables: model.tables.reversed(), relationships: model.relationships.reversed())
        #expect(ERLayout.autoLayout(shuffled) == first)
        assertNoOverlap(model, first)

        // Parents sit left of the tables that reference them; related tables share a block.
        let frames = ERLayout.frames(model, positions: first)
        #expect(frames["customers"]!.maxX < frames["orders"]!.minX)
        #expect(frames["orders"]!.maxX < frames["order_items"]!.minX)
        #expect(frames["products"]!.maxX < frames["order_items"]!.minX)
        // The diagram starts at the margin.
        let bounds = ERLayout.bounds(frames.values)
        #expect(bounds.minX == ERLayout.margin && bounds.minY == ERLayout.margin)
    }

    @Test func largeSchemaLayoutHasNoOverlaps() {
        var inputs: [ERModel.TableInput] = []
        for i in 0..<40 {
            var columns = [TableColumn(name: "id", dataType: "integer", nullable: false, isPrimaryKey: true, ordinal: 0)]
            var keys: [TableForeignKey] = []
            // A few chains, a cycle (t5 ↔ t6) and loners.
            if i % 7 != 0 && i < 30 {
                let parent = i - 1
                columns.append(TableColumn(name: "t\(parent)_id", dataType: "integer", nullable: true, ordinal: 1))
                keys.append(TableForeignKey(name: "", columns: ["t\(parent)_id"], referencedTable: "t\(parent)", referencedColumns: ["id"]))
            }
            if i == 5 {
                columns.append(TableColumn(name: "t6_id", dataType: "integer", nullable: true, ordinal: 2))
                keys.append(TableForeignKey(name: "", columns: ["t6_id"], referencedTable: "t6", referencedColumns: ["id"]))
            }
            for extra in 0..<(i % 5) { columns.append(TableColumn(name: "column_with_long_name_\(extra)", dataType: "varchar(255)", nullable: true, ordinal: 10 + extra)) }
            inputs.append(.init(name: "t\(i)", columns: columns, foreignKeys: keys))
        }
        let model = ERModel(sourceKind: .sqlite, inputs: inputs)
        let positions = ERLayout.autoLayout(model)
        assertNoOverlap(model, positions)
        #expect(positions == ERLayout.autoLayout(model))
    }

    @Test func savedPositionsSurviveAndNewTablesGoBelow() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        var saved = ERLayout.autoLayout(model)
        saved["customers"] = CGPoint(x: 900, y: 700)
        saved["dropped_table"] = CGPoint(x: 1, y: 1)
        saved.removeValue(forKey: "settings")
        let merged = ERLayout.layout(model, keeping: saved)
        #expect(merged["customers"] == CGPoint(x: 900, y: 700))
        #expect(merged["dropped_table"] == nil)
        #expect(merged.count == model.tables.count)
        let kept = ERLayout.frames(model, positions: saved.filter { $0.key != "dropped_table" })
        #expect(merged["settings"]!.y > ERLayout.bounds(kept.values).maxY)
    }

    @Test func routesLeaveTheChildAndReachTheParentRow() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        let frames = ERLayout.frames(model, positions: ERLayout.autoLayout(model))
        let relation = try #require(model.relationships.first { $0.fromTable == "orders" })
        let points = try #require(ERLayout.route(relation, in: model, frames: frames))
        #expect(points.first!.x == frames["orders"]!.minX)
        #expect(points.first!.y == frames["orders"]!.minY + ERLayout.rowCenter(1))
        #expect(points.last!.x == frames["customers"]!.maxX)
        #expect(points.last!.y == frames["customers"]!.minY + ERLayout.rowCenter(0))
        let loop = try #require(ERLayout.route(model.relationships.first { $0.isSelfReference }!, in: model, frames: frames))
        #expect(loop.first!.x == loop.last!.x)
    }

    // MARK: - Persistence

    @Test func layoutStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-model-\(UUID().uuidString)/model-layouts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ERLayoutStore(fileURL: url)
        let id = UUID()
        let key = ERLayoutStore.key(connectionID: id, database: "main", schema: nil)
        let other = ERLayoutStore.key(connectionID: id, database: "dvd", schema: "public")
        #expect(store.positions(for: key) == nil)
        try store.save(["a": CGPoint(x: 10, y: 20), "public.b": CGPoint(x: 300.5, y: 40)], for: key)
        try store.save(["c": CGPoint(x: 1, y: 2)], for: other)
        let reopened = ERLayoutStore(fileURL: url)
        #expect(reopened.positions(for: key) == ["a": CGPoint(x: 10, y: 20), "public.b": CGPoint(x: 300.5, y: 40)])
        #expect(reopened.positions(for: other) == ["c": CGPoint(x: 1, y: 2)])
        try reopened.remove(key)
        #expect(reopened.positions(for: key) == nil)
        #expect(reopened.positions(for: other) != nil)
    }

    // MARK: - Forward engineering

    @Test func generatesSQLiteWithInlineKeysThatRuns() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        let sql = model.generateSQL(for: .sqlite)
        #expect(sql.hasPrefix("-- 7 tables, 5 relationships (SQLite)"))
        #expect(!sql.contains("ALTER TABLE"))
        #expect(sql.contains(#"CONSTRAINT "fk_orders_customer_id" FOREIGN KEY ("customer_id") REFERENCES "customers" ("id") ON DELETE CASCADE"#))
        #expect(sql.contains(#""price" NUMERIC(10,2) DEFAULT 0"#))
        // Parents are created before children.
        let customers = try #require(sql.range(of: #"CREATE TABLE "customers""#)).lowerBound
        let orders = try #require(sql.range(of: #"CREATE TABLE "orders""#)).lowerBound
        let items = try #require(sql.range(of: #"CREATE TABLE "order_items""#)).lowerBound
        #expect(customers < orders && orders < items)

        // The script rebuilds the same model in an empty database.
        let copy = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await copy.connect()
        _ = try await copy.execute(sql)
        let rebuilt = try await ERModel.reverseEngineer(driver: copy, schema: nil)
        #expect(rebuilt.tables.map(\.name) == model.tables.map(\.name))
        #expect(Set(rebuilt.relationships.map(\.id)) == Set(model.relationships.map(\.id)))
        #expect(rebuilt.table("order_items")?.primaryKey == ["order_id", "product_id"])
    }

    @Test func generatesPostgreSQLWithTranslatedTypes() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        let sql = model.generateSQL(for: .postgresql, options: .init(includeDrop: true))
        #expect(sql.hasPrefix("-- 7 tables, 5 relationships (SQLite → PostgreSQL)"))
        #expect(sql.contains(#"DROP TABLE IF EXISTS "order_items" CASCADE;"#))
        #expect(sql.contains(#""id" integer NOT NULL"#))
        #expect(sql.contains(#""placed_at" timestamp"#))
        #expect(sql.contains(#""price" numeric(10,2) DEFAULT 0"#))
        #expect(sql.contains(#"ALTER TABLE "orders" ADD CONSTRAINT "fk_orders_customer_id" FOREIGN KEY ("customer_id") REFERENCES "customers" ("id") ON DELETE CASCADE;"#))
        #expect(sql.contains(#"ALTER TABLE "employees" ADD CONSTRAINT "fk_employees_manager_id" FOREIGN KEY ("manager_id") REFERENCES "employees" ("id");"#))
        // Every CREATE comes before the first ALTER, so key order never matters.
        let lastCreate = try #require(sql.range(of: "CREATE TABLE", options: .backwards)).lowerBound
        let firstAlter = try #require(sql.range(of: "ALTER TABLE")).lowerBound
        #expect(lastCreate < firstAlter)
    }

    @Test func generatesMySQLWithKeyColumnsAsVarchar() async throws {
        let model = try await ERModel.reverseEngineer(driver: try await shop(), schema: nil)
        let sql = model.generateSQL(for: .mysql, options: .init(tables: ["customers", "orders", "settings"]))
        #expect(sql.hasPrefix("-- 3 tables, 1 relationship (SQLite → MySQL)"))
        #expect(sql.contains("CREATE TABLE `settings` (\n  `key` varchar(255) NOT NULL,\n  `value` text,\n  PRIMARY KEY (`key`)\n);"))
        #expect(sql.contains("`placed_at` datetime"))
        #expect(sql.contains("ALTER TABLE `orders` ADD CONSTRAINT `fk_orders_customer_id` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE;"))
        #expect(!sql.contains("order_items"))
    }

    @Test func postgresSourceKeepsSchemaAndTurnsSequencesIntoAutoIncrement() {
        let model = ERModel(sourceKind: .postgresql, inputs: [
            .init(schema: "public", name: "film", columns: [
                TableColumn(name: "film_id", dataType: "int4", nullable: false, defaultValue: "nextval('film_film_id_seq'::regclass)", isPrimaryKey: true, ordinal: 1),
                TableColumn(name: "title", dataType: "varchar(255)", nullable: false, ordinal: 2),
                TableColumn(name: "rating", dataType: "text", nullable: true, defaultValue: "'G'::text", ordinal: 3),
                TableColumn(name: "updated", dataType: "timestamp(6)", nullable: false, defaultValue: "now()", ordinal: 4),
                TableColumn(name: "special", dataType: "bool", nullable: true, ordinal: 5),
            ]),
        ])
        let same = model.generateSQL(for: .postgresql)
        #expect(same.contains(#"CREATE TABLE "public"."film""#))
        #expect(same.contains(#""film_id" int4 NOT NULL DEFAULT nextval('film_film_id_seq'::regclass)"#))

        let mysql = model.generateSQL(for: .mysql)
        #expect(mysql.contains("CREATE TABLE `film`"))
        #expect(mysql.contains("`film_id` int NOT NULL AUTO_INCREMENT"))
        #expect(mysql.contains("`rating` text DEFAULT 'G'"))
        #expect(mysql.contains("`updated` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP"))
        #expect(mysql.contains("`special` tinyint(1)"))

        let sqlite = model.generateSQL(for: .sqlite)
        #expect(sqlite.contains(#""film_id" INTEGER NOT NULL,"#))
        #expect(sqlite.contains(#""title" VARCHAR(255) NOT NULL"#))
    }
}
