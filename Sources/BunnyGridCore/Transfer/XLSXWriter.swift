import Foundation

/// One worksheet of an Excel workbook: a header row and the data rows.
public struct XLSXSheet: Sendable {
    public var name: String
    public var columns: [String]
    public var rows: [[CellValue]]

    public init(name: String, columns: [String], rows: [[CellValue]]) {
        self.name = name
        self.columns = columns
        self.rows = rows
    }
}

/// Writes Office Open XML spreadsheets (.xlsx): a zip of XML parts, one worksheet per sheet.
/// Numbers and booleans stay typed, text uses inline strings, NULL leaves the cell empty,
/// the header row is bold and frozen.
public enum XLSXWriter {
    /// Excel refuses longer cell text.
    public static let maxCellCharacters = 32_767
    /// Integers beyond this lose digits as Excel numbers (15 significant digits), so they are written as text.
    static let maxExactInteger: Int64 = 999_999_999_999_999

    public static func workbook(_ sheets: [XLSXSheet], date: Date = Date()) throws -> Data {
        // A workbook needs at least one sheet.
        let sheets = sheets.isEmpty ? [XLSXSheet(name: "Sheet1", columns: [], rows: [])] : sheets
        let names = sheetNames(sheets.map(\.name))
        var zip = ZipWriter(date: date)
        try zip.add("[Content_Types].xml", text: contentTypes(sheetCount: sheets.count))
        try zip.add("_rels/.rels", text: """
            \(header)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
            </Relationships>
            """)
        try zip.add("docProps/core.xml", text: """
            \(header)<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>BunnyGrid</dc:creator>\
            <dcterms:created xsi:type="dcterms:W3CDTF">\(date.formatted(.iso8601))</dcterms:created></cp:coreProperties>
            """)
        try zip.add("docProps/app.xml", text: """
            \(header)<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>BunnyGrid</Application></Properties>
            """)
        try zip.add("xl/workbook.xml", text: workbookXML(names))
        try zip.add("xl/_rels/workbook.xml.rels", text: workbookRels(sheetCount: sheets.count))
        try zip.add("xl/styles.xml", text: styles)
        for (index, sheet) in sheets.enumerated() {
            try zip.add("xl/worksheets/sheet\(index + 1).xml", text: worksheetXML(sheet))
        }
        return try zip.finish()
    }

    /// Valid, unique sheet names: at most 31 characters, none of `[]:*?/\`, not empty.
    public static func sheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { raw in
            var name = String(raw.map { "[]:*?/\\".contains($0) ? "_" : $0 })
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if name.isEmpty { name = "Sheet" }
            name = String(name.prefix(31))
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// "A", "B", … "Z", "AA", … for a zero-based column index.
    public static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    // MARK: - Parts

    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1..<(sheetCount + 1)).map {
            #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        return header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
            + #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
            + #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#
            + sheets + "</Types>"
    }

    private static func workbookXML(_ names: [String]) -> String {
        let sheets = names.enumerated().map { index, name in
            #"<sheet name="\#(escape(name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined()
        return header + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" "#
            + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
            + sheets + "</sheets></workbook>"
    }

    private static func workbookRels(sheetCount: Int) -> String {
        var rels = (0..<sheetCount).map { i in
            #"<Relationship Id="rId\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i + 1).xml"/>"#
        }
        rels.append(#"<Relationship Id="rId\#(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#)
        return header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels.joined() + "</Relationships>"
    }

    /// Style 0 is the default; style 1 is the bold header.
    private static let styles = header + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        + #"<fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>"#
        + #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
        + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
        + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        + #"<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
        + #"<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>"#
        + #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#

    static func worksheetXML(_ sheet: XLSXSheet) -> String {
        var xml = header + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        let width = max(sheet.columns.count, sheet.rows.map(\.count).max() ?? 0)
        let firstDataRow = sheet.columns.isEmpty ? 1 : 2
        let lastRow = max(1, sheet.rows.count + firstDataRow - 1)
        if width > 0 { xml += #"<dimension ref="A1:\#(columnName(width - 1))\#(lastRow)"/>"# }
        xml += #"<sheetViews><sheetView workbookViewId="0">"#
        if !sheet.columns.isEmpty {
            xml += #"<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>"#
        }
        xml += "</sheetView></sheetViews><sheetData>"
        if !sheet.columns.isEmpty {
            xml += #"<row r="1">"#
            for (c, title) in sheet.columns.enumerated() {
                xml += #"<c r="\#(columnName(c))1" s="1" t="inlineStr"><is><t xml:space="preserve">\#(escape(title))</t></is></c>"#
            }
            xml += "</row>"
        }
        for (r, row) in sheet.rows.enumerated() {
            let rowNumber = r + firstDataRow
            xml += #"<row r="\#(rowNumber)">"#
            for (c, value) in row.enumerated() {
                xml += cell(value, ref: "\(columnName(c))\(rowNumber)")
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func cell(_ value: CellValue, ref: String) -> String {
        switch value {
        case .null:
            return ""
        case .integer(let v) where abs(v) <= maxExactInteger:
            return #"<c r="\#(ref)"><v>\#(v)</v></c>"#
        case .integer(let v):
            return inline(String(v), ref: ref)
        case .double(let v) where v.isFinite:
            return #"<c r="\#(ref)"><v>\#(v)</v></c>"#
        case .double(let v):
            return inline(String(v), ref: ref)
        case .bool(let v):
            return #"<c r="\#(ref)" t="b"><v>\#(v ? 1 : 0)</v></c>"#
        case .text(let v):
            return inline(v, ref: ref)
        case .blob(let data):
            return inline(data.map { String(format: "%02x", $0) }.joined(), ref: ref)
        }
    }

    private static func inline(_ text: String, ref: String) -> String {
        let clipped = text.count > maxCellCharacters ? String(text.prefix(maxCellCharacters)) : text
        return #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(clipped))</t></is></c>"#
    }

    /// XML text escaping that also drops characters XML 1.0 can't carry (most C0 controls).
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
