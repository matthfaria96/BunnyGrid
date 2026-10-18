import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct DocumentExportTests {
    let columns = ["id", "name", "note", "photo", "price"]
    let rows: [[CellValue]] = [
        [.integer(1), .text("Ana <b> & \"Bia\""), .text("line 1\nline | 2"), .blob(Data([0xCA, 0xFE])), .double(9.5)],
        [.integer(2), .text("Caio"), .null, .null, .null],
    ]

    @Test func xmlRoundTripsThroughTheReader() throws {
        let xml = ResultExporter.xml(columns: columns, rows: rows)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<RECORDS>\n  <RECORD>\n"))
        #expect(xml.contains("<name>Ana &lt;b&gt; &amp; \"Bia\"</name>"))
        #expect(xml.contains("<note null=\"true\"/>"))
        #expect(xml.contains("<photo encoding=\"base64\">yv4=</photo>"))
        let table = try XMLTableReader.read(Data(xml.utf8))
        #expect(table.columns == columns)
        #expect(table.rows[0][1] == .text("Ana <b> & \"Bia\""))
        #expect(table.rows[0][2] == .text("line 1\nline | 2"))
        #expect(table.rows[0][3] == .blob(Data([0xCA, 0xFE])))
        #expect(table.rows[0][4] == .text("9.5"))
        #expect(table.rows[1][2] == .null)
    }

    @Test func oddColumnNamesUseFieldElements() throws {
        let xml = ResultExporter.xml(columns: ["first name", "1st", "xmlish", "ok_name"], rows: [[.text("a"), .text("b"), .text("c"), .text("d")]])
        #expect(xml.contains("<field name=\"first name\">a</field>"))
        #expect(xml.contains("<field name=\"1st\">b</field>"))
        #expect(xml.contains("<field name=\"xmlish\">c</field>"))
        #expect(xml.contains("<ok_name>d</ok_name>"))
        let table = try XMLTableReader.read(Data(xml.utf8))
        #expect(table.columns == ["first name", "1st", "xmlish", "ok_name"])
    }

    @Test func readsNavicatExport() throws {
        let navicat = """
            <?xml version="1.0" encoding="UTF-8"?>
            <RECORDS>
            <RECORD>
            <id>1</id>
            <city>Lisboa</city>
            </RECORD>
            <RECORD>
            <id>2</id>
            <city><![CDATA[São Paulo & região]]></city>
            <extra>x</extra>
            </RECORD>
            </RECORDS>
            """
        let table = try XMLTableReader.read(Data(navicat.utf8))
        #expect(table.columns == ["id", "city", "extra"])
        #expect(table.rows == [[.text("1"), .text("Lisboa"), .null], [.text("2"), .text("São Paulo & região"), .text("x")]])
    }

    @Test func readsAttributeRecords() throws {
        let xml = #"<rows><row id="1" name="Ana"/><row id="2" name="Bia" xsi:nil="true"/></rows>"#
        let table = try XMLTableReader.read(Data(xml.utf8))
        #expect(Set(table.columns) == ["id", "name", "xsi:nil"])
        #expect(table.rows.count == 2)
    }

    @Test func xmlErrors() {
        #expect(throws: XMLTableReader.ReadError.notTabular) { try XMLTableReader.read(Data("<root/>".utf8)) }
        #expect(throws: XMLTableReader.ReadError.self) { try XMLTableReader.read(Data("<root><a></root>".utf8)) }
    }

    @Test func xmlDropsControlCharacters() throws {
        let xml = ResultExporter.xml(columns: ["t"], rows: [[.text("a\u{01}b\tc")]])
        #expect(xml.contains("<t>ab\tc</t>"))
        _ = try XMLTableReader.read(Data(xml.utf8))
    }

    @Test func markdownEscapesAndAlignsNumbers() {
        let md = ResultExporter.markdown(columns: columns, rows: rows)
        let lines = md.split(separator: "\n").map(String.init)
        #expect(lines[0] == "| id | name | note | photo | price |")
        #expect(lines[1] == "| ---: | --- | --- | --- | ---: |")
        #expect(lines[2] == #"| 1 | Ana <b> & "Bia" | line 1<br>line \| 2 | cafe | 9.5 |"#)
        #expect(lines[3] == "| 2 | Caio |  |  |  |")
    }

    @Test func htmlEscapesAndMarksNull() {
        let html = ResultExporter.html(columns: columns, rows: rows, title: "people <x>")
        #expect(html.contains("<title>people &lt;x&gt;</title>"))
        #expect(html.contains("<td>Ana &lt;b&gt; &amp; &quot;Bia&quot;</td>"))
        #expect(html.contains("<td class=\"null\">NULL</td>"))
        #expect(html.contains("<td class=\"number\">1</td>"))
        #expect(html.contains("<p>2 records</p>"))
        #expect(!html.contains("<b>"))
    }

    @Test func formatsKnowTheirExtensions() throws {
        #expect(ExportFormat.markdown.fileExtension == "md")
        #expect(TableExportFormat.markdown.fileExtension == "md")
        #expect(TableExportFormat.xml.summary?.contains("RECORDS") == true)
        let data = try ResultExporter.export(columns: ["a"], rows: [[.integer(1)]], as: .xml)
        #expect(String(decoding: data, as: UTF8.self).contains("<a>1</a>"))
    }

    @Test func exportsATableFromSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute("INSERT INTO t VALUES (1, 'Ana'), (2, NULL)")
        let object = DatabaseObject(schema: nil, name: "t", kind: .table)
        let md = String(decoding: try await TableExporter.export(object, from: driver, as: .markdown), as: UTF8.self)
        #expect(md.contains("| 1 | Ana |"))
        let xml = try await TableExporter.export(object, from: driver, as: .xml)
        let back = try XMLTableReader.read(xml)
        #expect(back.rows == [[CellValue.text("1"), .text("Ana")], [.text("2"), .null]])
    }
}
