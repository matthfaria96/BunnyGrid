import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv
    case json
    case xlsx

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String { self == .xlsx ? "Excel" : rawValue.uppercased() }
}

/// Serializes grid results for the export menu and the Export Wizard.
public enum ResultExporter {
    public static func export(columns: [String], rows: [[CellValue]], as format: ExportFormat, sheetName: String = "Sheet1") throws -> Data {
        switch format {
        case .csv: Data(csv(columns: columns, rows: rows).utf8)
        case .json: json(columns: columns, rows: rows)
        case .xlsx: try XLSXWriter.workbook([XLSXSheet(name: sheetName, columns: columns, rows: rows)])
        }
    }

    /// RFC 4180 CSV. NULL becomes an empty field; blobs are hex. Fields are quoted when they hold the
    /// delimiter, a quote, a line break, or leading/trailing spaces (which spreadsheet apps would trim).
    public static func csv(columns: [String], rows: [[CellValue]], delimiter: Character = ",", includeHeader: Bool = true) -> String {
        var lines: [String] = []
        let separator = String(delimiter)
        if includeHeader { lines.append(columns.map { csvField($0, delimiter: delimiter) }.joined(separator: separator)) }
        for row in rows {
            lines.append(row.map { value -> String in
                switch value {
                case .null: ""
                case .blob(let data): data.map { String(format: "%02x", $0) }.joined()
                default: csvField(value.displayString, delimiter: delimiter)
                }
            }.joined(separator: separator))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    static func csvField(_ text: String, delimiter: Character = ",") -> String {
        let needsQuotes = text.contains { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            || text.first == " " || text.last == " "
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// An array of objects keyed by column name, keys in column order. Integers, doubles, booleans
    /// and NULL keep their JSON types; non-finite doubles and blobs (base64) are strings.
    public static func json(columns: [String], rows: [[CellValue]]) -> Data {
        guard !rows.isEmpty else { return Data("[]\n".utf8) }
        var out = "[\n"
        for (r, row) in rows.enumerated() {
            out += "  {\n"
            let pairs = zip(columns, row).map { column, value in "    \(jsonString(column)): \(jsonValue(value))" }
            out += pairs.joined(separator: ",\n")
            out += r == rows.count - 1 ? "\n  }\n" : "\n  },\n"
        }
        return Data((out + "]\n").utf8)
    }

    static func jsonValue(_ value: CellValue) -> String {
        switch value {
        case .null: "null"
        case .integer(let v): String(v)
        case .double(let v) where v.isFinite:
            // Whole doubles keep a fraction so they read back as floating point.
            v == v.rounded() && abs(v) < 1e15 ? String(format: "%.1f", v) : String(v)
        case .double(let v): jsonString(String(v))
        case .text(let v): jsonString(v)
        case .bool(let v): v ? "true" : "false"
        case .blob(let d): jsonString(d.base64EncodedString())
        }
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
