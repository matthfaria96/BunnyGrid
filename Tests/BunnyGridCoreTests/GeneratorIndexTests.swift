import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct DataGeneratorTests {
    private func column(_ name: String, _ type: String, pk: Bool = false, defaultValue: String? = nil, nullable: Bool = true) -> TableColumn {
        TableColumn(name: name, dataType: type, nullable: nullable, defaultValue: defaultValue, isPrimaryKey: pk, ordinal: 0)
    }

    @Test func suggestsGeneratorsFromNamesAndTypes() {
        #expect(ValueGenerator.suggested(for: column("payment_id", "int4", pk: true, defaultValue: "nextval('payment_seq')")) == .skip)
        #expect(ValueGenerator.suggested(for: column("id", "INTEGER", pk: true)) == .skip)
        #expect(ValueGenerator.suggested(for: column("email", "varchar(255)")) == .email)
        #expect(ValueGenerator.suggested(for: column("first_name", "text")) == .firstName)
        #expect(ValueGenerator.suggested(for: column("customer_name", "text")) == .fullName)
        #expect(ValueGenerator.suggested(for: column("city", "text")) == .city)
        #expect(ValueGenerator.suggested(for: column("amount", "numeric(5,2)")) == .decimal)
        #expect(ValueGenerator.suggested(for: column("payment_date", "timestamp(6)")) == .dateTime)
        #expect(ValueGenerator.suggested(for: column("active", "bool")) == .boolean)
        #expect(ValueGenerator.suggested(for: column("last_update", "timestamptz(6)", defaultValue: "now()")) == .skip)
        #expect(ValueGenerator.suggested(for: column("customer_id", "int2")) == .integer)
    }

    @Test func seededOutputIsReproducible() {
        let columns: [(name: String, generator: ValueGenerator)] = [("id", .skip), ("name", .fullName), ("email", .email), ("score", .decimal)]
        let a = ValueGenerator.rows(count: 5, columns: columns, seed: 42)
        let b = ValueGenerator.rows(count: 5, columns: columns, seed: 42)
        #expect(a == b)
        #expect(a != ValueGenerator.rows(count: 5, columns: columns, seed: 7))
        guard case .insert(let values) = a[0] else { Issue.record("expected insert"); return }
        #expect(values.map(\.column) == ["name", "email", "score"])
    }

    @Test func valuesHaveTheRightShape() {
        var rng = SeededGenerator(seed: 1)
        guard case .text(let email) = ValueGenerator.email.value(row: 0, using: &rng) else { Issue.record("email"); return }
        #expect(email.contains("@") && !email.contains(" "))
        guard case .text(let uuid) = ValueGenerator.uuid.value(row: 0, using: &rng) else { Issue.record("uuid"); return }
        #expect(UUID(uuidString: uuid) != nil)
        guard case .text(let date) = ValueGenerator.date.value(row: 0, using: &rng) else { Issue.record("date"); return }
        #expect(date.count == 10)
    }

    @Test func valuesRespectColumnLimits() {
        var rng = SeededGenerator(seed: 5)
        for _ in 0..<500 {
            guard case .text(let amount) = ValueGenerator.decimal.value(row: 0, type: "numeric(5,2)", using: &rng),
                  let number = Double(amount) else { Issue.record("decimal"); return }
            #expect(number < 1000 && amount.split(separator: ".").last?.count == 2)
            guard case .integer(let small) = ValueGenerator.integer.value(row: 0, type: "int2", using: &rng) else { Issue.record("int2"); return }
            #expect(small <= 32_767)
            guard case .text(let name) = ValueGenerator.fullName.value(row: 0, type: "varchar(5)", using: &rng) else { Issue.record("name"); return }
            #expect(name.count <= 5)
        }
    }

    @Test func generatedRowsInsertIntoSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.executeStatement("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, score REAL, born TEXT)")
        let columns = try await driver.listColumns(table: "p", schema: nil)
        let plan = columns.map { (name: $0.name, generator: ValueGenerator.suggested(for: $0)) }
        try await driver.applyChanges(ValueGenerator.rows(count: 250, columns: plan, seed: 3), table: "p", schema: nil)
        #expect(try await driver.countRows(table: "p", schema: nil) == 250)
    }
}

@Suite struct IndexDesignTests {
    let pg = SQLDialect(kind: .postgresql)
    let mysql = SQLDialect(kind: .mysql)
    let original = [
        TableIndex(name: "t_pkey", columns: ["id"], unique: true, primary: true),
        TableIndex(name: "t_name_idx", columns: ["name"], unique: false, primary: false),
        TableIndex(name: "t_old_idx", columns: ["old"], unique: false, primary: false),
    ]

    @Test func createAndDropPerDialect() throws {
        let index = IndexDesign(name: "t_email_key", columns: ["email"], unique: true)
        #expect(try pg.createIndex(index, table: "t", schema: "public") == #"CREATE UNIQUE INDEX "t_email_key" ON "public"."t" ("email")"#)
        #expect(pg.dropIndex(named: "t_email_key", table: "t", schema: "public") == #"DROP INDEX "public"."t_email_key""#)
        #expect(mysql.dropIndex(named: "k", table: "t", schema: "shop") == "DROP INDEX `k` ON `shop`.`t`")
        #expect(SQLDialect(kind: .sqlite).dropIndex(named: "k", table: "t", schema: nil) == #"DROP INDEX "k""#)
    }

    @Test func alterDropsChangedAndRemovedThenCreates() throws {
        var design = original.map(IndexDesign.init)
        design.removeLast()                       // drop t_old_idx
        design[1].columns = ["name", "city"]      // change t_name_idx
        design.append(IndexDesign(name: "t_email_key", columns: ["email"], unique: true))
        #expect(try pg.alterIndexes(table: "t", schema: "public", original: original, design: design) == [
            #"DROP INDEX "public"."t_old_idx""#,
            #"DROP INDEX "public"."t_name_idx""#,
            #"CREATE INDEX "t_name_idx" ON "public"."t" ("name", "city")"#,
            #"CREATE UNIQUE INDEX "t_email_key" ON "public"."t" ("email")"#,
        ])
    }

    @Test func unchangedIndexesProduceNothingAndEmptyIndexesAreRejected() throws {
        #expect(try pg.alterIndexes(table: "t", schema: nil, original: original, design: original.map(IndexDesign.init)).isEmpty)
        #expect(throws: TableDesignError.self) {
            try pg.alterIndexes(table: "t", schema: nil, original: [], design: [IndexDesign(name: "x", columns: [])])
        }
    }
}

@Suite struct OpenTransactionTests {
    @Test func changesStayUncommittedUntilCommit() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.executeStatement("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        _ = try await driver.executeStatement("BEGIN")
        try await driver.applyChanges([.insert(values: [ColumnValue("v", .text("a"))])], table: "t", schema: nil, inOpenTransaction: true)
        _ = try await driver.executeStatement("ROLLBACK")
        #expect(try await driver.countRows(table: "t", schema: nil) == 0)
        _ = try await driver.executeStatement("BEGIN")
        try await driver.applyChanges([.insert(values: [ColumnValue("v", .text("b"))])], table: "t", schema: nil, inOpenTransaction: true)
        _ = try await driver.executeStatement("COMMIT")
        #expect(try await driver.countRows(table: "t", schema: nil) == 1)
    }
}
