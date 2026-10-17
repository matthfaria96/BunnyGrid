import Foundation

/// Reads Office Open XML workbooks (.xlsx) for the Import Wizard: the zip (stored or deflated),
/// `xl/workbook.xml` and its relationships for the sheet order, `xl/sharedStrings.xml`,
/// `xl/styles.xml` (only to tell dates from numbers) and each worksheet's cells.
/// Numbers come back as integers or doubles, booleans as bools, text as text; cells formatted
/// as dates become ISO text (`2024-03-01`, `2024-03-01 13:45:00`). Formulas give their cached value.
public struct XLSXWorkbook: Sendable {
    public enum ReadError: LocalizedError, Equatable {
        case notWorkbook
        case missingSheet(String)

        public var errorDescription: String? {
            switch self {
            case .notWorkbook: "The file is not an Excel workbook (.xlsx). Older .xls files must be saved as .xlsx first."
            case .missingSheet(let name): "The workbook has no readable sheet \(name)."
            }
        }
    }

    /// Sheet names in workbook order.
    public let sheetNames: [String]
    private let sheetPaths: [String]
    private let entries: [String: Data]
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let date1904: Bool

    public init(data: Data) throws {
        guard let entries = ZipReader.entries(data), let workbook = entries["xl/workbook.xml"] else { throw ReadError.notWorkbook }
        self.entries = entries
        let book = XMLElementCollector(data: workbook, names: ["sheet", "workbookPr"])
        date1904 = book.elements.contains { $0.name == "workbookPr" && ["1", "true"].contains($0.attributes["date1904"] ?? "") }
        var targets: [String: String] = [:]
        if let rels = entries["xl/_rels/workbook.xml.rels"] {
            for rel in XMLElementCollector(data: rels, names: ["Relationship"]).elements {
                guard let id = rel.attributes["Id"], let target = rel.attributes["Target"] else { continue }
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        var names: [String] = [], paths: [String] = []
        for (index, sheet) in book.elements.filter({ $0.name == "sheet" }).enumerated() {
            let id = sheet.attributes.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value
            names.append(sheet.attributes["name"] ?? "Sheet\(index + 1)")
            paths.append(id.flatMap { targets[$0] } ?? "xl/worksheets/sheet\(index + 1).xml")
        }
        sheetNames = names
        sheetPaths = paths
        sharedStrings = entries["xl/sharedStrings.xml"].map(Self.readSharedStrings) ?? []
        dateStyles = entries["xl/styles.xml"].map(Self.readDateStyles) ?? []
    }

    /// The cells of a sheet as rows (shorter rows are padded to the widest; gaps are NULL).
    public func rows(sheet index: Int = 0) throws -> [[CellValue]] {
        guard sheetPaths.indices.contains(index), let xml = entries[sheetPaths[index]] else {
            throw ReadError.missingSheet(sheetNames.indices.contains(index) ? sheetNames[index] : "\(index + 1)")
        }
        let reader = SheetReader(sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        let width = reader.rows.values.map(\.count).max() ?? 0
        guard let last = reader.rows.keys.max() else { return [] }
        let first = reader.rows.keys.min() ?? 0
        return (first...last).map { r in
            var row = reader.rows[r] ?? []
            if row.count < width { row += Array(repeating: .null, count: width - row.count) }
            return row
        }
    }

    /// A sheet as an import table: the first row as field names (or `Column n`), the rest as records.
    public func table(sheet index: Int = 0, firstRowIsHeader: Bool = true) throws -> ImportedTable {
        let all = try rows(sheet: index)
        guard let first = all.first else { return ImportedTable(columns: [], rows: []) }
        let columns = first.indices.map { i -> String in
            let name = firstRowIsHeader ? first[i].displayString.trimmingCharacters(in: .whitespaces) : ""
            return firstRowIsHeader && first[i] != .null && !name.isEmpty ? name : "Column \(i + 1)"
        }
        return ImportedTable(columns: columns, rows: firstRowIsHeader ? Array(all.dropFirst()) : all)
    }

    /// `A` → 0, `AB` → 27 from a cell reference such as `AB12`.
    static func columnIndex(_ reference: String) -> Int? {
        var index = 0, any = false
        for byte in reference.utf8 {
            let upper = byte & ~0x20
            guard (65...90).contains(upper) else { break }
            index = index * 26 + Int(upper - 64)
            any = true
        }
        return any ? index - 1 : nil
    }

    /// An Excel serial date (days since 1899-12-30, or 1904-01-01) as ISO text.
    static func dateText(serial: Double, date1904: Bool) -> String {
        let days = serial + (date1904 ? 1462 : 0)
        var seconds = (days * 86_400).rounded()
        let wholeDays = (seconds / 86_400).rounded(.down)
        seconds -= wholeDays * 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let date = calendar.date(byAdding: .day, value: Int(wholeDays), to: base)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let s = Int(seconds)
        if serial > 0 && serial < 1 { return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return s == 0 ? day : day + String(format: " %02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// Whether a number format code shows a date or time (y, m, d, h, s outside quotes and brackets).
    static func isDateFormat(_ code: String) -> Bool {
        var quoted = false, bracket = false, escape = false
        for ch in code.lowercased() {
            if escape { escape = false; continue }
            switch ch {
            case "\\": escape = true
            case "\"": quoted.toggle()
            case "[": bracket = true
            case "]": bracket = false
            default: if !quoted && !bracket && "ymdhs".contains(ch) { return true }
            }
        }
        return false
    }

    private static func readSharedStrings(_ data: Data) -> [String] {
        let reader = SharedStringsReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.strings
    }

    private static func readDateStyles(_ data: Data) -> Set<Int> {
        let collected = XMLElementCollector(data: data, names: ["numFmt", "cellXfs", "xf"], trackParent: true)
        var customDates = Set<Int>()
        for format in collected.elements where format.name == "numFmt" {
            if let id = format.attributes["numFmtId"].flatMap(Int.init), isDateFormat(format.attributes["formatCode"] ?? "") {
                customDates.insert(id)
            }
        }
        let builtinDates: Set<Int> = Set(14...22).union(45...47).union(27...36).union(50...58)
        var result = Set<Int>()
        for (index, xf) in collected.elements.filter({ $0.name == "xf" && $0.parent == "cellXfs" }).enumerated() {
            let id = xf.attributes["numFmtId"].flatMap(Int.init) ?? 0
            if builtinDates.contains(id) || customDates.contains(id) { result.insert(index) }
        }
        return result
    }
}

/// Collects the attributes of the named elements of an XML document.
private final class XMLElementCollector: NSObject, XMLParserDelegate {
    struct Element {
        var name: String
        var attributes: [String: String]
        var parent: String?
    }

    private let names: Set<String>
    private let trackParent: Bool
    private var stack: [String] = []
    var elements: [Element] = []

    init(data: Data, names: Set<String>, trackParent: Bool = false) {
        self.names = names
        self.trackParent = trackParent
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if names.contains(local) { elements.append(Element(name: local, attributes: attributeDict, parent: stack.last)) }
        if trackParent { stack.append(local) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if trackParent { _ = stack.popLast() }
    }
}

/// `<si>` items of the shared strings table; rich text runs (`<r><t>`) are joined, phonetic hints (`<rPh>`) skipped.
private final class SharedStringsReader: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inText = false
    private var phonetic = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si": current = ""
        case "t": inText = phonetic == 0
        case "rPh": phonetic += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "si": strings.append(current)
        case "t": inText = false
        case "rPh": phonetic -= 1
        default: break
        }
    }
}

/// Cells of one worksheet, keyed by row number.
private final class SheetReader: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    let dateStyles: Set<Int>
    let date1904: Bool
    var rows: [Int: [CellValue]] = [:]

    private var rowNumber = 0
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType = "n"
    private var cellStyle = 0
    private var text = ""
    private var collecting = false
    private var inCell = false
    private var phonetic = 0

    init(sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            rowNumber = attributeDict["r"].flatMap(Int.init) ?? rowNumber + 1
            nextColumn = 0
        case "c":
            inCell = true
            cellColumn = attributeDict["r"].flatMap(XLSXWorkbook.columnIndex) ?? nextColumn
            nextColumn = cellColumn + 1
            cellType = attributeDict["t"] ?? "n"
            cellStyle = attributeDict["s"].flatMap(Int.init) ?? 0
            text = ""
        case "v" where inCell, "t" where inCell && phonetic == 0:
            collecting = true
        case "rPh":
            phonetic += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t": collecting = false
        case "rPh": phonetic -= 1
        case "c":
            inCell = false
            let value = cellValue()
            guard value != .null else { return }
            var row = rows[rowNumber] ?? []
            if row.count <= cellColumn { row += Array(repeating: .null, count: cellColumn + 1 - row.count) }
            row[cellColumn] = value
            rows[rowNumber] = row
        default: break
        }
    }

    private func cellValue() -> CellValue {
        switch cellType {
        case "s":
            guard let index = Int(text.trimmingCharacters(in: .whitespaces)), sharedStrings.indices.contains(index) else { return .null }
            return .text(sharedStrings[index])
        case "inlineStr", "str":
            return .text(text)
        case "b":
            return .bool(text.trimmingCharacters(in: .whitespaces) == "1")
        case "e":
            return .text(text)
        default:
            let raw = text.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return .null }
            guard let number = Double(raw) else { return .text(raw) }
            if dateStyles.contains(cellStyle) { return .text(XLSXWorkbook.dateText(serial: number, date1904: date1904)) }
            if !raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let integer = Int64(raw) { return .integer(integer) }
            if number == number.rounded(), abs(number) < 1e15 { return .integer(Int64(number)) }
            return .double(number)
        }
    }
}
