import Foundation
import NIOCore
import Testing
@testable import BunnyGridCore

@Suite struct CSVWriterTests {
    @Test func quotesOnlyWhatNeedsIt() {
        let csv = ResultExporter.csv(columns: ["a", "b;c"], rows: [[.text("x;y"), .text(" padded")], [.text("plain"), .null]], delimiter: ";")
        #expect(csv == "a;\"b;c\"\r\n\"x;y\";\" padded\"\r\nplain;\r\n")
    }

    @Test func headerIsOptionalAndValuesKeepTheirText() {
        let csv = ResultExporter.csv(columns: ["n", "f", "b"], rows: [[.integer(-3), .double(1.5), .bool(true)]], includeHeader: false)
        #expect(csv == "-3,1.5,true\r\n")
        #expect(ResultExporter.csv(columns: [], rows: [], includeHeader: false) == "")
    }

    @Test func roundTripsThroughTheParser() {
        let rows: [[CellValue]] = [[.text("a,b"), .text("say \"hi\""), .text("two\nlines")]]
        let csv = ResultExporter.csv(columns: ["x", "y", "z"], rows: rows)
        #expect(CSVParser.parse(csv) == [["x", "y", "z"], ["a,b", "say \"hi\"", "two\nlines"]])
    }
}

@Suite struct JSONWriterTests {
    @Test func keepsColumnOrderAndTypes() throws {
        let data = ResultExporter.json(columns: ["z", "a", "m"], rows: [[.integer(1), .double(2), .bool(false)], [.null, .double(.infinity), .text("x")]])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.range(of: "\"z\"")!.lowerBound < text.range(of: "\"a\"")!.lowerBound)
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"m\"")!.lowerBound)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded[0]["z"] as? Int == 1)
        #expect((decoded[0]["a"] as? NSNumber).map { CFNumberIsFloatType($0) } == true, "a whole double stays floating point")
        #expect((decoded[0]["m"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
        #expect(decoded[1]["z"] is NSNull)
        #expect(decoded[1]["a"] as? String == "inf")
    }

    @Test func escapesStrings() throws {
        let tricky = "quote \" backslash \\ newline \n tab \t bell \u{07} / é 🐰"
        let data = ResultExporter.json(columns: ["s"], rows: [[.text(tricky)]])
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded[0]["s"] as? String == tricky)
        #expect(String(decoding: ResultExporter.json(columns: ["s"], rows: []), as: UTF8.self) == "[]\n")
    }
}

@Suite struct JSONReaderTests {
    @Test func arrayOfObjectsInKeyOrder() throws {
        let json = #"[{"id": 1, "name": "Ana", "score": 9.5, "active": true, "tags": ["a", "b"], "meta": {"k": 1}, "gone": null}, {"name": "Bo", "id": 2, "extra": "x"}]"#
        let table = try JSONTableReader.read(Data(json.utf8))
        #expect(table.columns == ["id", "name", "score", "active", "tags", "meta", "gone", "extra"])
        #expect(table.rows[0] == [.integer(1), .text("Ana"), .double(9.5), .bool(true), .text(#"["a","b"]"#), .text(#"{"k":1}"#), .null, .null])
        #expect(table.rows[1][0] == .integer(2))
        #expect(table.rows[1][7] == .text("x"))
        #expect(table.rows[1][2] == .null, "a key missing from a row is NULL")
    }

    @Test func wrappedArraySingleObjectAndJSONLines() throws {
        let wrapped = try JSONTableReader.read(Data(#"{"count": 2, "rows": [{"a": 1}, {"a": 2}]}"#.utf8))
        #expect(wrapped.columns == ["a"])
        #expect(wrapped.rows == [[.integer(1)], [.integer(2)]])

        let single = try JSONTableReader.read(Data(#"{"a": "x", "b": 0}"#.utf8))
        #expect(single.rows == [[.text("x"), .integer(0)]])

        let lines = try JSONTableReader.read(Data("{\"a\": 1}\n{\"a\": 2, \"b\": false}\n".utf8))
        #expect(lines.columns == ["a", "b"])
        #expect(lines.rows == [[.integer(1), .null], [.integer(2), .bool(false)]])
    }

    @Test func rejectsNonTabularAndInvalidJSON() {
        #expect(throws: JSONTableReader.ReadError.notTabular) { try JSONTableReader.read(Data("[1, 2]".utf8)) }
        #expect(throws: JSONTableReader.ReadError.self) { try JSONTableReader.read(Data("{oops".utf8)) }
    }

    @Test func roundTripsTheWriter() throws {
        let rows: [[CellValue]] = [[.integer(7), .text("ok"), .double(0.25), .bool(true), .null]]
        let columns = ["id", "label", "ratio", "flag", "nothing"]
        let table = try JSONTableReader.read(ResultExporter.json(columns: columns, rows: rows))
        #expect(table.columns == columns)
        #expect(table.rows == rows)
    }
}

@Suite struct SQLInsertTests {
    let rows: [[CellValue]] = [[.integer(1), .text("O'Brien \\ path"), .null, .bool(true), .blob(Data([0x00, 0xff]))]]
    let columns = ["id", "name", "note", "ok", "raw"]

    @Test func escapesPerDialect() {
        let mysql = SQLDialect(kind: .mysql).insertStatements(into: "`t`", columns: columns, rows: rows)
        #expect(mysql == [#"INSERT INTO `t` (`id`, `name`, `note`, `ok`, `raw`) VALUES (1, 'O''Brien \\ path', NULL, TRUE, X'00ff');"#])
        let pg = SQLDialect(kind: .postgresql).insertStatements(into: #""s"."t""#, columns: columns, rows: rows)
        #expect(pg == [#"INSERT INTO "s"."t" ("id", "name", "note", "ok", "raw") VALUES (1, 'O''Brien \ path', NULL, TRUE, decode('00ff', 'hex'));"#])
        let sqlite = SQLDialect(kind: .sqlite).insertStatements(into: #""t""#, columns: columns, rows: rows)
        #expect(sqlite == [#"INSERT INTO "t" ("id", "name", "note", "ok", "raw") VALUES (1, 'O''Brien \ path', NULL, 1, X'00ff');"#])
    }

    @Test func batchesRows() {
        let many = (1...5).map { [CellValue.integer(Int64($0))] }
        let statements = SQLDialect(kind: .postgresql).insertStatements(into: "t", columns: ["n"], rows: many, rowsPerInsert: 2)
        #expect(statements.count == 3)
        #expect(statements[0] == "INSERT INTO t (\"n\") VALUES (1),\n  (2);")
        #expect(statements[2] == "INSERT INTO t (\"n\") VALUES (5);")
        #expect(SQLDialect(kind: .mysql).insertStatements(into: "t", columns: ["n"], rows: []).isEmpty)
    }

    @Test func mysqlDumpsUseBareNames() {
        let object = DatabaseObject(schema: "shop", name: "orders", kind: .table)
        #expect(SQLDialect(kind: .mysql).dumpName(object) == "`orders`")
        #expect(SQLDialect(kind: .postgresql).dumpName(object) == #""shop"."orders""#)
        #expect(SQLDialect(kind: .mariadb).dropIfExists(DatabaseObject(schema: "shop", name: "v", kind: .view)) == "DROP VIEW IF EXISTS `v`;")
    }

    @Test func postgresSerialSequencesAreRecreated() {
        let ddl = """
            CREATE TABLE "s"."t" (
              "id" int4 NOT NULL DEFAULT nextval('s.t_id_seq'::regclass),
              "price" numeric(6,2) DEFAULT 0,
              "Odd" int8 DEFAULT nextval('"S"."it''s_seq"'::regclass)
            );
            """
        let pg = SQLDialect(kind: .postgresql).sequenceStatements(forDDL: ddl, table: #""s"."t""#)
        #expect(pg.create == [#"CREATE SEQUENCE IF NOT EXISTS s.t_id_seq;"#, #"CREATE SEQUENCE IF NOT EXISTS "S"."it's_seq";"#])
        #expect(pg.own.first == #"ALTER SEQUENCE s.t_id_seq OWNED BY "s"."t"."id";"#)
        #expect(pg.reset.first == #"SELECT setval('s.t_id_seq', MAX("id")) FROM "s"."t" HAVING MAX("id") IS NOT NULL;"#)
        #expect(pg.reset.last?.contains(#"MAX("Odd")"#) == true)
        #expect(SQLDialect(kind: .mysql).sequenceStatements(forDDL: ddl, table: "t").create.isEmpty)
    }

    @Test func dumpOptionsAndRestoreRoundTrip() async throws {
        let source = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await source.connect()
        _ = try await source.execute("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, photo BLOB);
            INSERT INTO people VALUES (1, 'Ana; "the first"', 9.5, X'0102'), (2, 'Bo''s', NULL, NULL), (3, 'Cy', -1, NULL);
            CREATE VIEW high AS SELECT * FROM people WHERE score > 0;
            """)
        let objects = try await source.listObjects(schema: nil)
        let dataOnly = try await SQLDumper.dump(objects, from: source, options: SQLDumpOptions(includeStructure: false, rowsPerInsert: 2))
        #expect(!dataOnly.contains("CREATE"))
        #expect(dataOnly.components(separatedBy: "INSERT INTO").count == 3, "3 rows in batches of 2")

        let script = try await SQLDumper.dump(objects, from: source, options: SQLDumpOptions(rowsPerInsert: 2))
        let target = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await target.connect()
        let report = await target.runScript(SQLSplitter.split(script))
        #expect(report.errors.isEmpty)
        let restored = try await target.fetchAllRows(table: "people", schema: nil)
        let original = try await source.fetchAllRows(table: "people", schema: nil)
        #expect(restored.rows == original.rows)
        #expect(try await target.countRows(table: "high", schema: nil) == 1)
    }
}

@Suite struct ZipAndXLSXTests {
    @Test func crc32KnownValues() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func zipRoundTripsAndPassesUnzip() throws {
        var zip = ZipWriter()
        try zip.add("a.txt", text: "hello")
        try zip.add("dir/b.bin", data: Data([0, 1, 2, 255]))
        let data = try zip.finish()
        let entries = try #require(ZipReader.entries(data))
        #expect(entries["a.txt"] == Data("hello".utf8))
        #expect(entries["dir/b.bin"] == Data([0, 1, 2, 255]))
        #expect(try unzip(["-t"], data).contains("No errors detected"))
    }

    @Test func columnAndSheetNames() {
        #expect(XLSXWriter.columnName(0) == "A")
        #expect(XLSXWriter.columnName(25) == "Z")
        #expect(XLSXWriter.columnName(26) == "AA")
        #expect(XLSXWriter.columnName(701) == "ZZ")
        #expect(XLSXWriter.columnName(702) == "AAA")
        let names = XLSXWriter.sheetNames(["orders", "Orders", "a/b:c", "", String(repeating: "x", count: 40), String(repeating: "x", count: 40)])
        #expect(names[0] == "orders")
        #expect(names[1] == "Orders (2)", "sheet names are unique ignoring case")
        #expect(names[2] == "a_b_c")
        #expect(names[3] == "Sheet")
        #expect(names[4].count == 31)
        #expect(names[5].count == 31 && names[5].hasSuffix(" (2)"))
    }

    @Test func workbookStructure() throws {
        let data = try XLSXWriter.workbook([
            XLSXSheet(name: "people", columns: ["id", "name", "ok", "big"],
                      rows: [[.integer(1), .text("Ana & <Bo>\u{01}"), .bool(true), .integer(1_234_567_890_123_456_789)],
                             [.double(2.5), .null, .bool(false), .blob(Data([0xab]))]]),
            XLSXSheet(name: "empty", columns: [], rows: []),
        ])
        let entries = try #require(ZipReader.entries(data))
        for part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
                     "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "docProps/core.xml", "docProps/app.xml"] {
            #expect(entries[part] != nil, "\(part) is in the package")
        }
        // Every part is well-formed XML.
        for (name, content) in entries {
            #expect(throws: Never.self, "\(name) parses") { _ = try XMLDocument(data: content) }
        }
        let workbook = String(decoding: entries["xl/workbook.xml"]!, as: UTF8.self)
        #expect(workbook.contains(#"<sheet name="people" sheetId="1" r:id="rId1"/>"#))
        #expect(workbook.contains(#"<sheet name="empty" sheetId="2" r:id="rId2"/>"#))
        let sheet = String(decoding: entries["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(sheet.contains(#"<dimension ref="A1:D3"/>"#))
        #expect(sheet.contains(#"<c r="A1" s="1" t="inlineStr"><is><t xml:space="preserve">id</t></is></c>"#))
        #expect(sheet.contains(#"<c r="A2"><v>1</v></c>"#))
        #expect(sheet.contains("Ana &amp; &lt;Bo&gt;</t>"), "escaped, control character dropped")
        #expect(sheet.contains(#"<c r="C2" t="b"><v>1</v></c>"#))
        #expect(sheet.contains(#"<c r="D2" t="inlineStr"><is><t xml:space="preserve">1234567890123456789</t>"#), "too many digits for an Excel number")
        #expect(sheet.contains(#"<c r="A3"><v>2.5</v></c>"#))
        #expect(!sheet.contains(#"r="B3""#), "NULL leaves the cell out")
        #expect(sheet.contains(#"<pane ySplit="1""#))
        let listing = try unzip(["-l"], data)
        #expect(listing.contains("xl/worksheets/sheet2.xml"))
    }

    @Test func headerlessSheetStartsAtRowOne() throws {
        let xml = XLSXWriter.worksheetXML(XLSXSheet(name: "s", columns: [], rows: [[.integer(5)]]))
        #expect(xml.contains(#"<row r="1"><c r="A1"><v>5</v></c></row>"#))
        #expect(!xml.contains("pane"))
    }

    @Test func exportsTablesAsWorkbook() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO a (v) VALUES ('x'), ('y'); CREATE TABLE b (n REAL)")
        let objects = [DatabaseObject(schema: nil, name: "a", kind: .table), DatabaseObject(schema: nil, name: "b", kind: .table)]
        let data = try await TableExporter.workbook(objects, from: driver)
        let entries = try #require(ZipReader.entries(data))
        #expect(String(decoding: entries["xl/workbook.xml"]!, as: UTF8.self).contains(#"name="b""#))
        #expect(String(decoding: entries["xl/worksheets/sheet1.xml"]!, as: UTF8.self).contains(#"<c r="A3"><v>2</v></c>"#))
        let single = try await TableExporter.export(objects[0], from: driver, as: .xlsx)
        #expect(ZipReader.entries(single)?["xl/worksheets/sheet1.xml"] != nil)
        let tsv = String(decoding: try await TableExporter.export(objects[0], from: driver, as: .csv,
                                                                 options: TableExportOptions(csvDelimiter: "\t", includeHeader: false)), as: UTF8.self)
        #expect(tsv == "1\tx\r\n2\ty\r\n")
    }

    /// Runs /usr/bin/unzip on the archive, as an independent check of the zip format.
    private func unzip(_ arguments: [String], _ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-\(UUID().uuidString).zip")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments + [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self)
    }
}

@Suite struct SQLScriptTests {
    @Test func splitterHonorsMySQLDelimiter() {
        let script = """
            SET NAMES utf8mb4;
            DELIMITER ;;
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END ;;
            DELIMITER ;
            INSERT INTO t VALUES ('DELIMITER ;;');
            delimiter $$
            CREATE FUNCTION f() RETURNS INT RETURN 1$$
            DELIMITER ;
            SELECT 3;
            """
        #expect(SQLSplitter.split(script) == [
            "SET NAMES utf8mb4",
            "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
            "INSERT INTO t VALUES ('DELIMITER ;;')",
            "CREATE FUNCTION f() RETURNS INT RETURN 1",
            "SELECT 3",
        ])
        // A column called delimiter is not a command.
        #expect(SQLSplitter.split("SELECT 1;\ndelimiter_col FROM x;") == ["SELECT 1", "delimiter_col FROM x"])
    }

    private func driver() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
        return driver
    }

    @Test func stopsOnErrorOrContinues() async throws {
        let statements = ["INSERT INTO t (v) VALUES ('a')", "INSERT INTO missing VALUES (1)", "INSERT INTO t (v) VALUES ('b')"]
        let stopping = try await driver()
        let stopped = await stopping.runScript(statements)
        #expect(stopped.stopped)
        #expect(stopped.executed == 2)
        #expect(stopped.succeeded == 1)
        #expect(stopped.errors.map(\.index) == [1])
        #expect(try await stopping.countRows(table: "t", schema: nil) == 1)

        let continuing = try await driver()
        let all = await continuing.runScript(statements, options: ScriptRunOptions(stopOnError: false))
        #expect(!all.stopped)
        #expect(all.executed == 3)
        #expect(all.succeeded == 2)
        #expect(all.affectedRows == 2)
        #expect(all.fractionDone == 1)
        #expect(try await continuing.countRows(table: "t", schema: nil) == 2)
    }

    @Test func transactionRollsBackOnError() async throws {
        let driver = try await driver()
        let report = await driver.runScript(["INSERT INTO t (v) VALUES ('a')", "INSERT INTO t (v) VALUES (NULL)"],
                                            options: ScriptRunOptions(stopOnError: true, useTransaction: true))
        #expect(report.rolledBack)
        #expect(try await driver.countRows(table: "t", schema: nil) == 0)

        let ok = await driver.runScript(["INSERT INTO t (v) VALUES ('a')"], options: ScriptRunOptions(useTransaction: true))
        #expect(!ok.rolledBack && ok.errors.isEmpty)
        #expect(try await driver.countRows(table: "t", schema: nil) == 1)
    }

    @Test func reportsProgress() async throws {
        let driver = try await driver()
        let seen = Counter()
        let statements = (1...20).map { "INSERT INTO t (v) VALUES ('\($0)')" }
        let report = await driver.runScript(statements, progressInterval: .zero) { progress in await seen.record(progress.executed) }
        #expect(report.succeeded == 20)
        let values = await seen.values
        #expect(values.last == 20)
        #expect(values == values.sorted())
    }

    @Test func readOnlyConnectionsRunNothing() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: "", readOnly: true))
        try await driver.connect()
        let report = await driver.runScript(["SELECT 1", "CREATE TABLE x (a)"])
        #expect(report.stopped)
        #expect(report.executed == 0)
        #expect(report.errors.first?.index == 1)
    }
}

private actor Counter {
    var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

@Suite struct TableProfileListTests {
    let connection = UUID()

    private func profile(_ name: String, table: String = "orders", isDefault: Bool = false, filter: String = "") -> TableProfile {
        TableProfile(connectionID: connection, database: "shop", schema: nil, table: table, name: name, filter: filter, isDefault: isDefault)
    }

    @Test func savingReplacesByNameAndKeepsDefault() {
        var list = [TableProfile]().saving(profile("Paid", isDefault: true, filter: "paid = 1"))
        let id = list[0].id
        list = list.saving(profile("Paid", filter: "paid = 1 AND total > 10"))
        #expect(list.count == 1)
        #expect(list[0].id == id)
        #expect(list[0].isDefault)
        #expect(list[0].filter == "paid = 1 AND total > 10")
    }

    @Test func oneDefaultPerTable() {
        var list = [TableProfile]()
            .saving(profile("A", isDefault: true))
            .saving(profile("Other table", table: "customers", isDefault: true))
            .saving(profile("B", isDefault: true))
        #expect(list.filter(\.isDefault).map(\.name).sorted() == ["B", "Other table"])
        let a = list.first { $0.name == "A" }!.id
        list = list.togglingDefault(a)
        #expect(list.filter { $0.table == "orders" && $0.isDefault }.map(\.name) == ["A"])
        list = list.togglingDefault(a)
        #expect(!list.contains { $0.table == "orders" && $0.isDefault })
        #expect(list.contains { $0.table == "customers" && $0.isDefault })
    }

    @Test func decodesProfilesSavedBeforeDefaults() throws {
        let json = """
            [{"id": "\(UUID().uuidString)", "connectionID": "\(connection.uuidString)", "database": "main", "table": "t",
              "name": "Old", "filter": "x > 1", "sortColumn": "x", "sortDescending": true, "hiddenColumns": ["y"], "masks": {}}]
            """
        let profiles = try JSONDecoder().decode([TableProfile].self, from: Data(json.utf8))
        #expect(profiles[0].name == "Old")
        #expect(profiles[0].sortDescending)
        #expect(!profiles[0].isDefault)
        let again = try JSONDecoder().decode([TableProfile].self, from: JSONEncoder().encode(profiles.map { var p = $0; p.isDefault = true; return p }))
        #expect(again[0].isDefault)
    }
}

@Suite struct MySQLDecodingTests {
    private func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    @Test func binaryTimeKeepsDaysSignAndFraction() {
        // -838:59:59 is 34 days and 22 hours.
        var long = buffer([1, 34, 0, 0, 0, 22, 59, 59])
        #expect(MySQLDriver.binaryTime(&long) == "-838:59:59")
        var fractional = buffer([0, 0, 0, 0, 0, 1, 2, 3, 0x40, 0xE2, 0x01, 0x00])  // 123456 µs
        #expect(MySQLDriver.binaryTime(&fractional, decimals: 3) == "01:02:03.123")
        var zero = buffer([])
        #expect(MySQLDriver.binaryTime(&zero) == "00:00:00")
    }

    @Test func fractionFollowsColumnPrecision() {
        #expect(MySQLDriver.fraction(120_000, decimals: 6) == ".120000")
        #expect(MySQLDriver.fraction(120_000, decimals: 2) == ".12")
        #expect(MySQLDriver.fraction(0, decimals: 0) == "")
        #expect(MySQLDriver.fraction(5, decimals: 0x1F) == ".000005")
    }
}
