import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct ForeignKeySQLTests {
    let pg = SQLDialect(kind: .postgresql)
    let mysql = SQLDialect(kind: .mysql)
    let sqlite = SQLDialect(kind: .sqlite)

    private let key = TableForeignKey(name: "fk_orders_customer", columns: ["customer_id"], referencedSchema: "sales",
                                      referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE", onUpdate: "SET NULL")

    @Test func clausePerEngine() throws {
        #expect(try pg.foreignKeyClause(key, schema: "public")
                == #"CONSTRAINT "fk_orders_customer" FOREIGN KEY ("customer_id") REFERENCES "sales"."customers" ("id") ON DELETE CASCADE ON UPDATE SET NULL"#)
        #expect(try mysql.addForeignKey(key, table: "orders", schema: "shop")
                == "ALTER TABLE `shop`.`orders` ADD CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `sales`.`customers` (`id`) ON DELETE CASCADE ON UPDATE SET NULL")
        // SQLite never qualifies the parent, and an empty field list points at its primary key.
        let implicit = TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers", referencedColumns: [""])
        #expect(try sqlite.foreignKeyClause(implicit, schema: nil) == #"FOREIGN KEY ("customer_id") REFERENCES "customers""#)
        // Composite keys keep their order; NO ACTION is the default and isn't written.
        let composite = TableForeignKey(name: "fk_line", columns: ["order_id", "line"], referencedTable: "lines", referencedColumns: ["order_id", "n"])
        #expect(try pg.addForeignKey(composite, table: "notes", schema: "public")
                == #"ALTER TABLE "public"."notes" ADD CONSTRAINT "fk_line" FOREIGN KEY ("order_id", "line") REFERENCES "public"."lines" ("order_id", "n")"#)
    }

    @Test func rejectsIncompleteKeys() {
        var missingTable = key
        missingTable.referencedTable = ""
        var mismatched = key
        mismatched.referencedColumns = ["id", "other"]
        var noFields = key
        noFields.columns = []
        var badAction = key
        badAction.onDelete = "EXPLODE"
        for bad in [missingTable, mismatched, noFields, badAction] {
            #expect(throws: TableDesignError.self) { try pg.foreignKeyClause(bad, schema: nil) }
        }
        var implicit = key
        implicit.referencedColumns = []
        #expect(throws: TableDesignError.self) { try pg.foreignKeyClause(implicit, schema: nil) }
        #expect(throws: Never.self) { try sqlite.foreignKeyClause(implicit, schema: nil) }
    }

    @Test func createTableWithKeys() throws {
        let sql = try pg.createTable(name: "orders", schema: "public", columns: [
            ColumnDesign(name: "id", type: "serial", nullable: false, isPrimaryKey: true),
            ColumnDesign(name: "customer_id", type: "int4"),
        ], foreignKeys: [key])
        #expect(sql == """
            CREATE TABLE "public"."orders" (
              "id" serial NOT NULL,
              "customer_id" int4,
              PRIMARY KEY ("id"),
              CONSTRAINT "fk_orders_customer" FOREIGN KEY ("customer_id") REFERENCES "sales"."customers" ("id") ON DELETE CASCADE ON UPDATE SET NULL
            )
            """)
    }

    @Test func altersKeysByDroppingAndAdding() throws {
        let other = TableForeignKey(name: "fk_orders_shop", columns: ["shop_id"], referencedTable: "shops", referencedColumns: ["id"])
        var changed = ForeignKeyDesign(key)
        changed.key.onDelete = "RESTRICT"
        let added = ForeignKeyDesign(key: TableForeignKey(name: "fk_orders_rep", columns: ["rep_id"], referencedTable: "reps", referencedColumns: ["id"]))
        // `other` was removed, `key` changed, one added; drops use the old name, adds the new one.
        let plan = try pg.alterForeignKeys(table: "orders", newTable: "purchases", schema: "public", original: [key, other], design: [changed, added])
        #expect(plan.drops == [
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "fk_orders_customer""#,
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "fk_orders_shop""#,
        ])
        #expect(plan.adds == [
            #"ALTER TABLE "public"."purchases" ADD CONSTRAINT "fk_orders_customer" FOREIGN KEY ("customer_id") REFERENCES "sales"."customers" ("id") ON DELETE RESTRICT ON UPDATE SET NULL"#,
            #"ALTER TABLE "public"."purchases" ADD CONSTRAINT "fk_orders_rep" FOREIGN KEY ("rep_id") REFERENCES "public"."reps" ("id")"#,
        ])
        let unchanged = try mysql.alterForeignKeys(table: "orders", schema: "shop", original: [key], design: [ForeignKeyDesign(key)])
        #expect(unchanged.drops.isEmpty && unchanged.adds.isEmpty)
        #expect(!SQLDialect.foreignKeysChanged(original: [key], design: [ForeignKeyDesign(key)]))
        #expect(SQLDialect.foreignKeysChanged(original: [key], design: []))
        #expect(SQLDialect.foreignKeysChanged(original: [key], design: [changed]))
        #expect(try mysql.alterForeignKeys(table: "orders", schema: "shop", original: [key], design: []).drops
                == ["ALTER TABLE `shop`.`orders` DROP FOREIGN KEY `fk_orders_customer`"])
    }
}

@Suite struct SQLiteRebuildTests {
    private let columns = [
        TableColumn(name: "id", dataType: "INTEGER", nullable: true, isPrimaryKey: true, ordinal: 0),
        TableColumn(name: "customer_id", dataType: "INTEGER", nullable: true, ordinal: 1),
        TableColumn(name: "total", dataType: "REAL", nullable: true, ordinal: 2),
    ]

    @Test func decidesWhenToRebuild() {
        let index = [TableIndex(name: "orders_total", columns: ["total"], unique: false, primary: false)]
        func needed(_ design: [ColumnDesign], keys: [ForeignKeyDesign] = [], indexes: [TableIndex] = []) -> Bool {
            SQLiteTableRebuild.isNeeded(originalColumns: columns, columns: design, originalIndexes: indexes, originalForeignKeys: [], foreignKeys: keys)
        }
        let same = columns.map(ColumnDesign.init)
        #expect(!needed(same))
        #expect(!needed(same + [ColumnDesign(name: "note", type: "TEXT")]), "ADD COLUMN works natively")
        var retyped = same
        retyped[2].type = "NUMERIC"
        #expect(needed(retyped))
        let key = TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"])
        #expect(needed(same, keys: [ForeignKeyDesign(key: key)]))
        #expect(!needed(Array(same.prefix(2))), "DROP COLUMN works natively")
        #expect(needed(Array(same.prefix(2)), indexes: index), "but not for an indexed column")
    }

    @Test func refusesWhatItCantKeep() {
        #expect(SQLiteTableRebuild.unsupportedFeatures(in: #"CREATE TABLE t (a INT CHECK (a > 0))"#) == ["CHECK constraints"])
        #expect(SQLiteTableRebuild.unsupportedFeatures(in: #"CREATE TABLE t ("check" INT, note TEXT DEFAULT 'CHECK (x)')"#).isEmpty)
        #expect(SQLiteTableRebuild.unsupportedFeatures(in: "CREATE TABLE t (a INT PRIMARY KEY) WITHOUT ROWID") == ["WITHOUT ROWID"])
        #expect(SQLiteTableRebuild.unsupportedFeatures(in: "CREATE TABLE t (a INT, b INT GENERATED ALWAYS AS (a * 2))") == ["generated columns"])
        let rebuild = SQLiteTableRebuild(table: "t", originalSQL: "CREATE TABLE t (a TEXT COLLATE NOCASE)",
                                         originalColumns: [TableColumn(name: "a", dataType: "TEXT", nullable: true, ordinal: 0)],
                                         columns: [ColumnDesign(name: "a", type: "INTEGER")], originalIndexes: [], indexes: [],
                                         foreignKeys: [], triggers: [], checkForeignKeys: false)
        #expect(throws: TableDesignError.self) { try rebuild.statements() }
    }

    @Test func rebuildStatements() throws {
        var design = columns.map(ColumnDesign.init)
        design[2].name = "amount"
        design[2].nullable = false
        design[2].defaultValue = "0"
        let key = TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE")
        let indexes = [
            TableIndex(name: "orders_total", columns: ["total"], unique: false, primary: false),
            TableIndex(name: "sqlite_autoindex_orders_1", columns: ["customer_id", "total"], unique: true, primary: false),
        ]
        let rebuild = SQLiteTableRebuild(table: "orders", originalSQL: "CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, total REAL)",
                                         originalColumns: columns, columns: design, originalIndexes: indexes,
                                         indexes: indexes.map(IndexDesign.init), foreignKeys: [key],
                                         triggers: ["CREATE TRIGGER t AFTER INSERT ON orders BEGIN SELECT 1; END"], checkForeignKeys: true)
        #expect(try rebuild.statements() == [
            "PRAGMA foreign_keys = OFF",
            "PRAGMA legacy_alter_table = ON",
            """
            CREATE TABLE "_bunnygrid_new_orders" (
              "id" INTEGER PRIMARY KEY AUTOINCREMENT,
              "customer_id" INTEGER,
              "amount" REAL NOT NULL DEFAULT 0,
              UNIQUE ("customer_id", "amount"),
              FOREIGN KEY ("customer_id") REFERENCES "customers" ("id") ON DELETE CASCADE
            )
            """,
            #"INSERT INTO "_bunnygrid_new_orders" ("id", "customer_id", "amount") SELECT "id", "customer_id", "total" FROM "orders""#,
            #"DROP TABLE "orders""#,
            #"ALTER TABLE "_bunnygrid_new_orders" RENAME TO "orders""#,
            "PRAGMA legacy_alter_table = OFF",
            #"CREATE INDEX "orders_total" ON "orders" ("amount")"#,
            "CREATE TRIGGER t AFTER INSERT ON orders BEGIN SELECT 1; END",
            #"PRAGMA foreign_key_check("orders")"#,
        ])
    }
}

extension SQLiteRebuildTests {
    @Test func keysFollowRenamedFields() throws {
        let columns = [
            TableColumn(name: "id", dataType: "INTEGER", nullable: true, isPrimaryKey: true, ordinal: 0),
            TableColumn(name: "parent_id", dataType: "INTEGER", nullable: true, ordinal: 1),
        ]
        var design = columns.map(ColumnDesign.init)
        design[0].name = "node_id"
        design[1].name = "parent"
        // A key read from the table, on itself, still names the old fields.
        let key = TableForeignKey(name: "", columns: ["parent_id"], referencedTable: "nodes", referencedColumns: ["id"], onDelete: "SET NULL")
        let rebuild = SQLiteTableRebuild(table: "nodes", originalSQL: nil, originalColumns: columns, columns: design, originalIndexes: [],
                                         indexes: [], foreignKeys: [key], triggers: [], checkForeignKeys: true)
        let create = try rebuild.statements()[2]
        #expect(create.contains(#"FOREIGN KEY ("parent") REFERENCES "nodes" ("node_id") ON DELETE SET NULL"#))
    }
}

@Suite struct SQLiteForeignKeyIntegrationTests {
    private func makeDriver() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE);
            CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, total REAL, status TEXT);
            CREATE INDEX orders_customer ON orders(customer_id);
            CREATE TRIGGER orders_touch AFTER UPDATE ON orders BEGIN SELECT 1; END;
            CREATE VIEW big_orders AS SELECT o.id, c.name, o.total FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.total > 900;
            CREATE TABLE payments (id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders(id));
            INSERT INTO customers (id, name, email) VALUES (1, 'Ana', 'ana@example.com'), (2, 'Bia', NULL);
            INSERT INTO orders (customer_id, total, status) VALUES (1, 950, 'paid'), (2, 20, 'open'), (1, 1200, 'paid');
            INSERT INTO payments (order_id) VALUES (1), (3);
            """)
        return driver
    }

    /// What the designer does on Save: plan the rebuild from the catalog and apply it.
    private func rebuild(_ driver: SQLiteDriver, table: String, edit: (inout [ColumnDesign], inout [ForeignKeyDesign]) -> Void) async throws {
        let columns = try await driver.listColumns(table: table, schema: nil)
        let indexes = try await driver.listIndexes(table: table, schema: nil)
        let keys = try await driver.listForeignKeys(table: table, schema: nil)
        var design = columns.map(ColumnDesign.init)
        var keyDesign = keys.map(ForeignKeyDesign.init)
        edit(&design, &keyDesign)
        #expect(SQLiteTableRebuild.isNeeded(originalColumns: columns, columns: design, originalIndexes: indexes,
                                            originalForeignKeys: keys, foreignKeys: keyDesign))
        let plan = SQLiteTableRebuild(
            table: table, originalSQL: try await driver.storedTableSQL(table), originalColumns: columns, columns: design,
            originalIndexes: indexes, indexes: indexes.map(IndexDesign.init), foreignKeys: keyDesign.map(\.key),
            triggers: try await driver.listTriggers(table: table, schema: nil).map(\.definition),
            checkForeignKeys: SQLDialect.foreignKeysChanged(original: keys, design: keyDesign))
        try await driver.applyDesign(try plan.statements())
    }

    @Test func addsForeignKeyByRebuildingTheTable() async throws {
        let driver = try await makeDriver()
        _ = try await driver.executeStatement("PRAGMA foreign_keys = ON")
        try await rebuild(driver, table: "orders") { columns, keys in
            columns[2].type = "NUMERIC"
            keys.append(ForeignKeyDesign(key: TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers",
                                                               referencedColumns: ["id"], onDelete: "CASCADE")))
        }
        #expect(try await driver.listForeignKeys(table: "orders", schema: nil)
                == [TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"], onDelete: "CASCADE")])
        #expect(try await driver.listColumns(table: "orders", schema: nil)[2].dataType == "NUMERIC")
        // Rows, index, trigger, AUTOINCREMENT and the view survive; other tables still point at "orders".
        #expect(try await driver.countRows(table: "orders", schema: nil) == 3)
        #expect(try await driver.listIndexes(table: "orders", schema: nil).map(\.name) == ["orders_customer"])
        #expect(try await driver.listTriggers(table: "orders", schema: nil).map(\.name) == ["orders_touch"])
        #expect(try await driver.storedTableSQL("orders")?.contains("AUTOINCREMENT") == true)
        #expect(try await driver.executeStatement("SELECT COUNT(*) FROM big_orders").rows == [[.integer(2)]])
        #expect(try await driver.listForeignKeys(table: "payments", schema: nil).first?.referencedTable == "orders")
        #expect(try await driver.executeStatement("PRAGMA foreign_keys").rows == [[.integer(1)]], "the setting is put back")
        #expect(try await driver.executeStatement("PRAGMA legacy_alter_table").rows == [[.integer(0)]])
        // The key works: deleting a customer cascades.
        _ = try await driver.executeStatement("DELETE FROM customers WHERE id = 2")
        #expect(try await driver.countRows(table: "orders", schema: nil) == 2)
        // The DDL pane shows the new key.
        let ddl = try await driver.objectDDL(name: "orders", kind: .table, schema: nil)
        #expect(ddl.contains(#"FOREIGN KEY ("customer_id") REFERENCES "customers" ("id") ON DELETE CASCADE"#))
        #expect(ddl.contains("CREATE INDEX"))
        #expect(ddl.contains("CREATE TRIGGER orders_touch"))
    }

    @Test func rebuildingAParentKeepsChildrenPointingAtIt() async throws {
        let driver = try await makeDriver()
        try await rebuild(driver, table: "orders") { columns, _ in
            columns[3].nullable = false
            columns[3].defaultValue = "'open'"
        }
        #expect(try await driver.listForeignKeys(table: "payments", schema: nil).map(\.referencedTable) == ["orders"])
        #expect(try await driver.executeStatement(#"SELECT sql FROM sqlite_master WHERE name = 'payments'"#).rows.first?.first?.displayString.contains("_bunnygrid") == false)
        // Then remove the key from payments.
        try await rebuild(driver, table: "payments") { _, keys in keys.removeAll() }
        #expect(try await driver.listForeignKeys(table: "payments", schema: nil).isEmpty)
        #expect(try await driver.countRows(table: "payments", schema: nil) == 2)
    }

    @Test func failingKeyCheckRollsBack() async throws {
        let driver = try await makeDriver()
        _ = try await driver.executeStatement("INSERT INTO orders (customer_id, total) VALUES (99, 5)")
        await #expect(throws: DatabaseError.self) {
            try await rebuild(driver, table: "orders") { _, keys in
                keys.append(ForeignKeyDesign(key: TableForeignKey(name: "", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"])))
            }
        }
        #expect(try await driver.listForeignKeys(table: "orders", schema: nil).isEmpty)
        #expect(try await driver.countRows(table: "orders", schema: nil) == 4)
        #expect(try await driver.listObjects(schema: nil).contains { $0.name.hasPrefix("_bunnygrid") } == false)
        #expect(try await driver.executeStatement("PRAGMA foreign_keys").rows == [[.integer(0)]])
        #expect(try await driver.executeStatement("PRAGMA legacy_alter_table").rows == [[.integer(0)]])
    }

    @Test func newTableWithKeyAndGeneratedDDL() async throws {
        let driver = try await makeDriver()
        let dialect = SQLDialect(kind: .sqlite)
        let key = TableForeignKey(name: "fk_notes_order", columns: ["order_id"], referencedTable: "orders", referencedColumns: ["id"], onUpdate: "CASCADE")
        try await driver.applyDesign([try dialect.createTable(name: "notes", schema: nil, columns: [
            ColumnDesign(name: "id", type: "INTEGER", nullable: false, isPrimaryKey: true),
            ColumnDesign(name: "order_id", type: "INTEGER"),
        ], foreignKeys: [key])])
        let keys = try await driver.listForeignKeys(table: "notes", schema: nil)
        #expect(keys.map(\.columns) == [["order_id"]])
        #expect(keys.first?.onUpdate == "CASCADE")
        // The catalog-built DDL (used by engines without stored DDL) carries the keys too.
        let generated = try await driver.generatedTableDDL(name: "payments", schema: nil)
        #expect(generated.contains(#"FOREIGN KEY ("order_id") REFERENCES "orders" ("id")"#))
    }
}
