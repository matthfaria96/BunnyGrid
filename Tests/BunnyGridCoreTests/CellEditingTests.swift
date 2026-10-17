import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct ColumnTypeCategoryTests {
    @Test(arguments: [
        ("int4", ColumnTypeCategory.integer), ("int(11) unsigned", .integer), ("bigserial", .integer), ("year", .integer),
        ("numeric(5,2)", .decimal), ("decimal(10,0)", .decimal), ("money", .decimal),
        ("float8", .real), ("double precision", .real),
        ("bool", .boolean), ("varchar(40)", .text), ("character varying(10)", .text), ("enum('a','b')", .text),
        ("jsonb", .json), ("bytea", .binary), ("longblob", .binary), ("varbinary(16)", .binary),
        ("date", .date), ("time(6)", .time), ("timetz", .timeWithTimeZone), ("timestamp(6)", .dateTime),
        ("timestamptz", .dateTimeWithTimeZone), ("timestamp(3) with time zone", .dateTimeWithTimeZone),
        ("uuid", .uuid), ("_int4", .other), ("integer[]", .other), ("interval", .other), ("point", .other),
    ])
    func classifiesServerTypes(type: String, expected: ColumnTypeCategory) {
        #expect(ColumnTypeCategory.classify(type, kind: .postgresql) == expected)
    }

    @Test func sqliteUsesAffinityRules() {
        #expect(ColumnTypeCategory.classify("INTEGER", kind: .sqlite) == .integer)
        #expect(ColumnTypeCategory.classify("UNSIGNED BIG INT", kind: .sqlite) == .integer)
        #expect(ColumnTypeCategory.classify("NVARCHAR(100)", kind: .sqlite) == .text)
        #expect(ColumnTypeCategory.classify("BLOB", kind: .sqlite) == .binary)
        #expect(ColumnTypeCategory.classify("DOUBLE", kind: .sqlite) == .real)
        #expect(ColumnTypeCategory.classify("DATETIME", kind: .sqlite) == .dateTime)
        #expect(ColumnTypeCategory.classify("NUMERIC", kind: .sqlite) == .decimal)
        #expect(ColumnTypeCategory.classify("", kind: .sqlite) == .other)
        #expect(ColumnTypeCategory.classify(nil, kind: .sqlite) == .other)
    }
}

@Suite struct SQLParameterTests {
    @Test func convertsEditedTextByColumnType() {
        #expect(SQLParameter(.text(" 42 "), category: .integer) == .integer(42))
        #expect(SQLParameter(.text("4.5"), category: .real) == .double(4.5))
        #expect(SQLParameter(.text("true"), category: .boolean) == .bool(true))
        #expect(SQLParameter(.text("0"), category: .boolean) == .bool(false))
        #expect(SQLParameter(.integer(1), category: .boolean) == .bool(true))
        #expect(SQLParameter(.text("2026-10-17"), category: .date) == .typed("2026-10-17", .date))
        #expect(SQLParameter(.text("0x0aff"), category: .binary) == .blob(Data([0x0a, 0xff])))
        #expect(SQLParameter(.text("hi"), category: .binary) == .blob(Data("hi".utf8)))
        #expect(SQLParameter(.text("O'Hara"), category: .text) == .text("O'Hara"))
        #expect(SQLParameter(.null, category: .integer) == .null)
    }

    @Test func keepsTextFallbackForUnknownOrInvalidValues() {
        #expect(SQLParameter(.text("12.50"), category: .decimal) == .untyped("12.50"))
        #expect(SQLParameter(.text("{1,2}"), category: .other) == .untyped("{1,2}"))
        #expect(SQLParameter(.text("abc"), category: .integer) == .untyped("abc"), "the server reports the error")
        #expect(SQLParameter(.text("maybe"), category: .boolean) == .untyped("maybe"))
    }

    private let columns = [
        TableColumn(name: "id", dataType: "int4", nullable: false, isPrimaryKey: true, ordinal: 1),
        TableColumn(name: "qty", dataType: "int4", nullable: true, defaultValue: "0", ordinal: 2),
        TableColumn(name: "photo", dataType: "bytea", nullable: true, ordinal: 3),
        TableColumn(name: "note", dataType: "text", nullable: true, ordinal: 4),
    ]

    @Test func postgresUpdateUsesNumberedPlaceholders() {
        let change = RowChange.update(key: [ColumnValue("id", .integer(7))],
                                      values: [ColumnValue("qty", .text("42")), ColumnValue("photo", .blob(Data([1, 2]))), .defaultValue("note")])
        let bound = SQLDialect(kind: .postgresql).boundStatement(for: change, table: "items", schema: "public", columns: columns)
        #expect(bound.sql == #"UPDATE "public"."items" SET "qty" = $1, "photo" = $2, "note" = DEFAULT WHERE "id" = $3"#)
        #expect(bound.parameters == [.integer(42), .blob(Data([1, 2])), .integer(7)])
    }

    @Test func mysqlInsertUsesQuestionMarksAndSkipsDefaults() {
        let change = RowChange.insert(values: [ColumnValue("qty", .text("3")), .defaultValue("note"), ColumnValue("photo", .null)])
        let bound = SQLDialect(kind: .mysql).boundStatement(for: change, table: "items", schema: nil, columns: columns)
        #expect(bound.sql == "INSERT INTO `items` (`qty`, `photo`) VALUES (?, ?)")
        #expect(bound.parameters == [.integer(3), .null])
    }

    @Test func nullKeysStayIsNull() {
        let change = RowChange.delete(key: [ColumnValue("id", .integer(1)), ColumnValue("note", .null)])
        let bound = SQLDialect(kind: .sqlite).boundStatement(for: change, table: "items", schema: nil, columns: columns)
        #expect(bound.sql == #"DELETE FROM "items" WHERE "id" = ? AND "note" IS NULL"#)
        #expect(bound.parameters == [.integer(1)])
    }

    @Test func sqliteDefaultUsesTheColumnsExpression() {
        let change = RowChange.update(key: [ColumnValue("id", .integer(1))], values: [.defaultValue("qty"), .defaultValue("note")])
        let dialect = SQLDialect(kind: .sqlite)
        #expect(dialect.boundStatement(for: change, table: "items", schema: nil, columns: columns).sql
            == #"UPDATE "items" SET "qty" = (0), "note" = NULL WHERE "id" = ?"#)
        #expect(dialect.sql(for: change, table: "items", schema: nil, columns: columns)
            == #"UPDATE "items" SET "qty" = (0), "note" = NULL WHERE "id" = 1"#)
        #expect(SQLDialect(kind: .postgresql).sql(for: .insert(values: [.defaultValue("qty")]), table: "items", schema: nil)
            == #"INSERT INTO "items" DEFAULT VALUES"#)
    }
}

@Suite struct SQLiteBindingTests {
    private func makeDriver() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE files (id INTEGER PRIMARY KEY, size INTEGER, ratio REAL, data BLOB, label TEXT, misc, stamp DATETIME DEFAULT '2000-01-01 00:00:00');
            INSERT INTO files (id, size, label) VALUES (1, 10, 'a');
            """)
        return driver
    }

    @Test func bindsEachStorageClass() async throws {
        let driver = try await makeDriver()
        let result = try await driver.executeStatement("SELECT typeof(?), typeof(?), typeof(?), typeof(?), typeof(?), ?",
                                                       parameters: [.integer(42), .double(1.5), .blob(Data([0])), .null, .text("x"), .blob(Data())])
        #expect(result.rows == [[.text("integer"), .text("real"), .text("blob"), .text("null"), .text("text"), .blob(Data())]])
    }

    @Test func blobAndIntegerRoundTripThroughApplyChanges() async throws {
        let driver = try await makeDriver()
        let columns = try await driver.listColumns(table: "files", schema: nil)
        let bytes = Data([0x00, 0x27, 0x5c, 0xff, 0x0a])   // NUL, quote, backslash, 0xFF, newline
        try await driver.applyChanges([
            .update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("size", .text("123456789012")), ColumnValue("data", .blob(bytes))]),
            .insert(values: [ColumnValue("id", .text("2")), ColumnValue("size", .text("-7")), ColumnValue("data", .blob(Data())),
                             ColumnValue("ratio", .text("0.25")), ColumnValue("misc", .text("007"))]),
        ], table: "files", schema: nil, columns: columns)

        let rows = try await driver.executeStatement(
            "SELECT id, size, typeof(size), data, ratio, misc, typeof(misc), stamp FROM files ORDER BY id").rows
        #expect(rows == [
            [.integer(1), .integer(123_456_789_012), .text("integer"), .blob(bytes), .null, .null, .text("null"), .text("2000-01-01 00:00:00")],
            [.integer(2), .integer(-7), .text("integer"), .blob(Data()), .double(0.25), .text("007"), .text("text"), .text("2000-01-01 00:00:00")],
        ])
    }

    @Test func setDefaultOnUpdate() async throws {
        let driver = try await makeDriver()
        let columns = try await driver.listColumns(table: "files", schema: nil)
        _ = try await driver.executeStatement("UPDATE files SET stamp = '2026-10-17 09:30:00', label = 'b'")
        try await driver.applyChanges([.update(key: [ColumnValue("id", .integer(1))], values: [.defaultValue("stamp"), .defaultValue("label")])],
                                      table: "files", schema: nil, columns: columns)
        #expect(try await driver.executeStatement("SELECT stamp, label FROM files").rows == [[.text("2000-01-01 00:00:00"), .null]])
    }
}

@Suite struct ValueFormattingTests {
    @Test func prettyPrintsKeepingKeyOrder() throws {
        let pretty = try JSONFormatter.pretty(#"{"b":1,"a":[1,2,{}],"s":"x, \"y\": {z}","e":[]}"#)
        #expect(pretty == """
            {
              "b": 1,
              "a": [
                1,
                2,
                {}
              ],
              "s": "x, \\"y\\": {z}",
              "e": []
            }
            """)
        #expect(try JSONFormatter.minify(pretty) == #"{"b":1,"a":[1,2,{}],"s":"x, \"y\": {z}","e":[]}"#)
    }

    @Test func validatesJSON() {
        #expect(JSONFormatter.validate(#"{"a": 1}"#) == nil)
        #expect(JSONFormatter.validate("42") == nil, "fragments are valid JSON values")
        #expect(JSONFormatter.validate(#"{"a": }"#) != nil)
        #expect(throws: JSONFormatter.InvalidJSON.self) { try JSONFormatter.pretty("{") }
    }

    @Test func hexDumpAndParse() {
        let data = Data("Hello, World!\n\u{0}\u{1}".utf8)
        #expect(HexFormatter.dump(data) == """
            00000000  48 65 6c 6c 6f 2c 20 57  6f 72 6c 64 21 0a 00 01  |Hello, World!...|
            """)
        #expect(HexFormatter.dump(Data(repeating: 0x41, count: 20), limit: 16).hasSuffix("… 4 more bytes"))
        #expect(HexFormatter.parse("0x0A ff") == Data([0x0a, 0xff]))
        #expect(HexFormatter.parse(#"\xdeadbeef"#) == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(HexFormatter.parse("X'00'") == Data([0]))
        #expect(HexFormatter.parse("cafe") == nil)
        #expect(HexFormatter.parse("cafe", requirePrefix: false) == Data([0xca, 0xfe]))
        #expect(HexFormatter.parse("0xabc") == nil, "odd number of digits")
    }

    @Test func detectsBlobKinds() {
        #expect(BlobKind.detect(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])) == .png)
        #expect(BlobKind.detect(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(BlobKind.detect(Data("%PDF-1.7".utf8)) == .pdf)
        #expect(BlobKind.detect(Data("plain text\n".utf8)) == .utf8Text)
        #expect(BlobKind.detect(Data([0x00, 0x01, 0x02])) == .binary)
        #expect(BlobKind.png.isImage && !BlobKind.pdf.isImage)
        #expect(BlobKind.jpeg.fileExtension == "jpg")
    }

    @Test func temporalTextRoundTrips() throws {
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let utc = TimeZone(secondsFromGMT: 0)!
        let date = try #require(TemporalText.parse("2026-10-17", category: .date, timeZone: saoPaulo))
        #expect(TemporalText.format(date, category: .date, timeZone: saoPaulo) == "2026-10-17")

        let stamp = try #require(TemporalText.parse("2026-10-17 09:30:15.25", category: .dateTime, timeZone: utc))
        #expect(abs(stamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) - 0.25) < 0.001)
        #expect(TemporalText.format(stamp, category: .dateTime, timeZone: utc) == "2026-10-17 09:30:15")

        let zoned = try #require(TemporalText.parse("2026-10-16 19:57:39-03:00", category: .dateTimeWithTimeZone, timeZone: utc))
        #expect(TemporalText.format(zoned, category: .dateTimeWithTimeZone, timeZone: utc) == "2026-10-16 22:57:39+00:00")
        #expect(TemporalText.parse("2026-10-16T22:57:39Z", category: .dateTimeWithTimeZone) == zoned)

        let time = try #require(TemporalText.parse("23:05", category: .time, timeZone: utc))
        #expect(TemporalText.format(time, category: .time, timeZone: utc) == "23:05:00")

        #expect(TemporalText.parse("2026-02-30", category: .date) == nil)
        #expect(TemporalText.parse("yesterday", category: .date) == nil)
    }
}

@Suite struct RowCopyTests {
    let columns = ["id", "name", "photo", "note"]
    let rows: [[CellValue]] = [
        [.integer(1), .text("O'Hara | Co"), .blob(Data([0xab])), .null],
        [.integer(2), .text("tab\there"), .null, .text("line1\nline2")],
    ]

    @Test func insertStatements() throws {
        let sql = try #require(RowCopier.text(.insertStatements, columns: columns, rows: rows, table: "people", schema: "public", kind: .postgresql))
        #expect(sql == """
            INSERT INTO "public"."people" ("id", "name", "photo", "note") VALUES (1, 'O''Hara | Co', decode('ab', 'hex'), NULL);
            INSERT INTO "public"."people" ("id", "name", "photo", "note") VALUES (2, 'tab\there', NULL, 'line1
            line2');
            """)
        #expect(RowCopier.text(.insertStatements, columns: columns, rows: rows) == nil, "needs a table")
    }

    @Test func updateStatementsNeedAKey() {
        let sql = RowCopier.text(.updateStatements, columns: ["id", "name"], rows: [[.integer(1), .text("x")]],
                                 table: "people", kind: .mysql, keyColumns: ["id"])
        #expect(sql == "UPDATE `people` SET `name` = 'x' WHERE `id` = 1;")
        #expect(RowCopier.text(.updateStatements, columns: ["name"], rows: [[.text("x")]], table: "people", keyColumns: ["id"]) == nil)
    }

    @Test func tabSeparated() {
        #expect(RowCopier.tsv(columns: columns, rows: rows, includeNames: true) == """
            id\tname\tphoto\tnote
            1\tO'Hara | Co\t0xab\t
            2\t"tab\there"\t\t"line1
            line2"
            """)
        #expect(RowCopier.tsv(columns: columns, rows: [rows[0]], includeNames: false) == "1\tO'Hara | Co\t0xab\t")
    }

    @Test func jsonKeepsColumnOrder() {
        #expect(RowCopier.json(columns: columns, rows: [rows[0]]) == """
            [
              {
                "id": 1,
                "name": "O'Hara | Co",
                "photo": "qw==",
                "note": null
              }
            ]
            """)
        #expect(RowCopier.json(columns: columns, rows: []) == "[]")
    }

    @Test func markdownTable() {
        #expect(RowCopier.markdown(columns: columns, rows: rows) == """
            | id | name | photo | note |
            | --- | --- | --- | --- |
            | 1 | O'Hara \\| Co | 0xab | NULL |
            | 2 | tab\there | NULL | line1<br>line2 |
            """)
    }

    @Test func generatedColumnsAreSkippedWhenDuplicating() {
        let serial = TableColumn(name: "id", dataType: "int4", nullable: false, defaultValue: "nextval('t_id_seq'::regclass)", isPrimaryKey: true, ordinal: 1)
        let name = TableColumn(name: "name", dataType: "text", nullable: true, ordinal: 2)
        let created = TableColumn(name: "created", dataType: "timestamp", nullable: true, defaultValue: "now()", ordinal: 3)
        let pg = [serial, name, created]
        #expect(pg.filter { $0.isGeneratedOnInsert(among: pg, kind: .postgresql) }.map(\.name) == ["id"])

        let rowid = TableColumn(name: "id", dataType: "INTEGER", nullable: true, isPrimaryKey: true, ordinal: 1)
        #expect(rowid.isGeneratedOnInsert(among: [rowid, name], kind: .sqlite))

        let code = TableColumn(name: "code", dataType: "varchar(10)", nullable: false, isPrimaryKey: true, ordinal: 1)
        #expect(!code.isGeneratedOnInsert(among: [code, name], kind: .mysql), "natural keys are copied for the user to change")
        let a = TableColumn(name: "a", dataType: "int", nullable: false, isPrimaryKey: true, ordinal: 1)
        let b = TableColumn(name: "b", dataType: "int", nullable: false, isPrimaryKey: true, ordinal: 2)
        #expect(!a.isGeneratedOnInsert(among: [a, b], kind: .mysql), "composite keys are copied")
    }
}
