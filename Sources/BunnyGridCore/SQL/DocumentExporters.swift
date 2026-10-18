import Foundation

/// HTML, Markdown and XML exports of a result or table (Export Wizard, grid Export menu, Automation).
extension ResultExporter {
    /// A standalone page with one table; NULL cells are empty and marked, blobs are hex.
    public static func html(columns: [String], rows: [[CellValue]], title: String) -> String {
        var out = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="BunnyGrid">
            <title>\(htmlEscape(title))</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; }
            h1 { font-size: 18px; font-weight: 600; }
            p { color: GrayText; }
            table { border-collapse: collapse; }
            th, td { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 4px 8px; text-align: left; vertical-align: top; white-space: pre-wrap; }
            th { background: color-mix(in srgb, CanvasText 7%, transparent); font-weight: 600; position: sticky; top: 0; }
            td.number { text-align: right; font-variant-numeric: tabular-nums; }
            td.null { color: GrayText; font-style: italic; }
            </style>
            </head>
            <body>
            <h1>\(htmlEscape(title))</h1>
            <p>\(rows.count == 1 ? "1 record" : "\(rows.count) records")</p>
            <table>
            <thead><tr>
            """
        out += columns.map { "<th>\(htmlEscape($0))</th>" }.joined()
        out += "</tr></thead>\n<tbody>\n"
        for row in rows {
            out += "<tr>"
            for value in row {
                switch value {
                case .null: out += "<td class=\"null\">NULL</td>"
                case .integer, .double: out += "<td class=\"number\">\(htmlEscape(value.displayString))</td>"
                case .blob(let data): out += "<td>\(hex(data))</td>"
                default: out += "<td>\(htmlEscape(value.displayString))</td>"
                }
            }
            out += "</tr>\n"
        }
        return out + "</tbody>\n</table>\n</body>\n</html>\n"
    }

    /// A GitHub-flavoured Markdown table. Pipes are escaped, line breaks become `<br>`, NULL is empty.
    public static func markdown(columns: [String], rows: [[CellValue]]) -> String {
        guard !columns.isEmpty else { return "" }
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\r", with: "<br>")
        }
        var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |"]
        let numeric = columns.indices.map { index in
            !rows.isEmpty && rows.allSatisfy { row in
                guard index < row.count else { return true }
                switch row[index] {
                case .integer, .double, .null: return true
                default: return false
                }
            }
        }
        lines.append("|" + numeric.map { $0 ? " ---: |" : " --- |" }.joined())
        for row in rows {
            let cells = row.map { value -> String in
                switch value {
                case .null: ""
                case .blob(let data): hex(data)
                default: cell(value.displayString)
                }
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Navicat's XML layout (`<RECORDS><RECORD><column>value</column>…`), so files move between the two apps.
    /// A column whose name isn't a valid element name is written as `<field name="…">`; NULL is `null="true"`;
    /// blobs are base64 with `encoding="base64"`.
    public static func xml(columns: [String], rows: [[CellValue]]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<RECORDS>\n"
        for row in rows {
            out += "  <RECORD>\n"
            for (column, value) in zip(columns, row) {
                let valid = isXMLName(column)
                let open = valid ? column : "field name=\"\(xmlEscape(column, attribute: true))\""
                let close = valid ? column : "field"
                switch value {
                case .null: out += "    <\(open) null=\"true\"/>\n"
                case .blob(let data): out += "    <\(open) encoding=\"base64\">\(data.base64EncodedString())</\(close)>\n"
                default: out += "    <\(open)>\(xmlEscape(value.displayString, attribute: false))</\(close)>\n"
                }
            }
            out += "  </RECORD>\n"
        }
        return out + "</RECORDS>\n"
    }

    static func htmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// XML 1.0 can't carry most control characters even escaped; they are dropped.
    static func xmlEscape(_ text: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Letters, digits, `_`, `-` and `.`, not starting with a digit, `-`, `.` or "xml".
    static func isXMLName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.lowercased().hasPrefix("xml") else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads XML for import: a root holding repeated record elements. Each record's child elements are its fields
/// (`<name>value</name>`, or `<field name="…">` as BunnyGrid writes odd names); a record with no child elements
/// uses its attributes (`<row id="1" name="Ana"/>`). `null="true"` (or `xsi:nil`) is NULL and
/// `encoding="base64"` a blob. Navicat's `<RECORDS><RECORD>` files read as-is.
public enum XMLTableReader {
    public enum ReadError: LocalizedError, Equatable {
        case invalid(String)
        case notTabular

        public var errorDescription: String? {
            switch self {
            case .invalid(let message): "The file is not valid XML: \(message)"
            case .notTabular: "The XML needs a root element holding repeated records, like <RECORDS><RECORD>…</RECORD></RECORDS>."
            }
        }
    }

    public static func read(_ data: Data) throws -> ImportedTable {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw ReadError.invalid(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard !delegate.records.isEmpty else { throw ReadError.notTabular }
        var columns: [String] = []
        var seen = Set<String>()
        for record in delegate.records {
            for (name, _) in record where seen.insert(name).inserted { columns.append(name) }
        }
        let rows = delegate.records.map { record -> [CellValue] in
            let values = Dictionary(record, uniquingKeysWith: { first, _ in first })
            return columns.map { values[$0] ?? .null }
        }
        return ImportedTable(columns: columns, rows: rows)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        /// Fields in document order per record.
        var records: [[(String, CellValue)]] = []
        private var depth = 0
        private var current: [(String, CellValue)]?
        private var recordAttributes: [String: String] = [:]
        private var recordHasChildren = false
        private var field: (name: String, attributes: [String: String])?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            switch depth {
            case 2:
                current = []
                recordAttributes = attributes
                recordHasChildren = false
            case 3:
                recordHasChildren = true
                let fieldName = name == "field" ? (attributes["name"] ?? name) : name
                field = (fieldName, attributes)
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if field != nil { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if field != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch depth {
            case 3:
                if let field {
                    current?.append((field.name, Self.value(text, attributes: field.attributes)))
                }
                field = nil
            case 2:
                if var record = current {
                    if !recordHasChildren {
                        record = recordAttributes.sorted { $0.key < $1.key }.map { ($0.key, CellValue.text($0.value)) }
                    }
                    if !record.isEmpty { records.append(record) }
                }
                current = nil
            default:
                break
            }
            depth -= 1
        }

        static func value(_ text: String, attributes: [String: String]) -> CellValue {
            if attributes["null"] == "true" || attributes["xsi:nil"] == "true" || attributes["nil"] == "true" { return .null }
            if attributes["encoding"] == "base64",
               let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .blob(data)
            }
            return .text(text)
        }
    }
}
