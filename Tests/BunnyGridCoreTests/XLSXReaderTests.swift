import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct XLSXReaderTests {
    @Test func deflateRoundTrip() throws {
        let text = Data(String(repeating: "<row><c r=\"A1\"><v>1</v></c></row>", count: 200).utf8)
        let packed = try #require(Deflate.compress(text))
        #expect(packed.count < text.count / 5)
        #expect(Deflate.decompress(packed, size: text.count) == text)
        #expect(Deflate.decompress(packed, size: text.count + 1) == nil, "a wrong size is refused")
    }

    @Test func zipWriterDeflatesAndUnzipReadsIt() throws {
        var zip = ZipWriter()
        let big = String(repeating: "abcabcabc ", count: 500)
        try zip.add("big.txt", text: big)
        try zip.add("tiny.txt", text: "x")
        let data = try zip.finish()
        #expect(data.count < big.utf8.count / 3, "deflated")
        let entries = try #require(ZipReader.entries(data))
        #expect(entries["big.txt"] == Data(big.utf8))
        #expect(entries["tiny.txt"] == Data("x".utf8), "stored when deflate does not help")
        // The system unzip agrees.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.zip")
        try data.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", file.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func readsZipMadeBySystemZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = String(repeating: "hello deflate ", count: 300)
        try content.write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-9", "out.zip", "a.txt"]
        try process.run()
        process.waitUntilExit()
        let entries = try #require(ZipReader.entries(try Data(contentsOf: dir.appendingPathComponent("out.zip"))))
        #expect(entries["a.txt"] == Data(content.utf8))
    }

    @Test func roundTripsWriterOutput() throws {
        let data = try XLSXWriter.workbook([
            XLSXSheet(name: "people", columns: ["id", "name", "ok", "score"],
                      rows: [[.integer(1), .text("Ana & Bo"), .bool(true), .double(2.5)],
                             [.integer(2), .null, .bool(false), .integer(-7)]]),
            XLSXSheet(name: "second", columns: ["x"], rows: [[.text("y")]]),
        ])
        let book = try XLSXWorkbook(data: data)
        #expect(book.sheetNames == ["people", "second"])
        let table = try book.table()
        #expect(table.columns == ["id", "name", "ok", "score"])
        #expect(table.rows == [[.integer(1), .text("Ana & Bo"), .bool(true), .double(2.5)],
                               [.integer(2), .null, .bool(false), .integer(-7)]])
        #expect(try book.table(sheet: 1).rows == [[.text("y")]])
        let raw = try book.table(firstRowIsHeader: false)
        #expect(raw.columns == ["Column 1", "Column 2", "Column 3", "Column 4"])
        #expect(raw.rows.count == 3)
    }

    @Test func sharedStringsDatesGapsAndRelationships() throws {
        var zip = ZipWriter()
        try zip.add("xl/workbook.xml", text: """
            <?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
            <sheet name="Data" sheetId="7" r:id="rId3"/></sheets></workbook>
            """)
        try zip.add("xl/_rels/workbook.xml.rels", text: """
            <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId3" Type="worksheet" Target="worksheets/data.xml"/></Relationships>
            """)
        try zip.add("xl/sharedStrings.xml", text: """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>name</t></si><si><t>when</t></si>\
            <si><r><t>Ri</t></r><r><rPr><b/></rPr><t>ch</t></r><rPh><t>skip</t></rPh></si><si><t>amount</t></si></sst>
            """)
        try zip.add("xl/styles.xml", text: """
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm"/></numFmts>\
            <cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="4"/></cellXfs></styleSheet>
            """)
        try zip.add("xl/worksheets/data.xml", text: """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="D1" t="s"><v>3</v></c></row>\
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="1"><v>45352</v></c><c r="D2" s="3"><v>1234.5</v></c></row>\
            <row r="4"><c r="A4" t="str"><f>A1&amp;"!"</f><v>name!</v></c><c r="B4" s="2"><v>45352.5729166667</v></c>\
            <c r="C4" t="inlineStr"><is><t>inline</t></is></c><c r="D4"><v>1E3</v></c></row>\
            </sheetData></worksheet>
            """)
        let book = try XLSXWorkbook(data: try zip.finish())
        #expect(book.sheetNames == ["Data"])
        let table = try book.table()
        #expect(table.columns == ["name", "when", "Column 3", "amount"])
        #expect(table.rows == [
            [.text("Rich"), .text("2024-03-01"), .null, .double(1234.5)],
            [.null, .null, .null, .null],
            [.text("name!"), .text("2024-03-01 13:45:00"), .text("inline"), .integer(1000)],
        ])
    }

    @Test func helpers() {
        #expect(XLSXWorkbook.columnIndex("A1") == 0)
        #expect(XLSXWorkbook.columnIndex("Z9") == 25)
        #expect(XLSXWorkbook.columnIndex("AB12") == 27)
        #expect(XLSXWorkbook.columnIndex("12") == nil)
        #expect(XLSXWorkbook.isDateFormat("dd/mm/yyyy"))
        #expect(XLSXWorkbook.isDateFormat("[h]:mm"))
        #expect(!XLSXWorkbook.isDateFormat("#,##0.00"))
        #expect(!XLSXWorkbook.isDateFormat("[Red]0.00;\"days\""))
        #expect(XLSXWorkbook.dateText(serial: 61, date1904: false) == "1900-03-01")
        #expect(XLSXWorkbook.dateText(serial: 0.5, date1904: false) == "12:00:00")
        #expect(XLSXWorkbook.dateText(serial: 0, date1904: true) == "1904-01-01")
    }

    @Test func rejectsNonWorkbooks() {
        #expect(throws: XLSXWorkbook.ReadError.notWorkbook) { _ = try XLSXWorkbook(data: Data("not a zip".utf8)) }
    }
}
