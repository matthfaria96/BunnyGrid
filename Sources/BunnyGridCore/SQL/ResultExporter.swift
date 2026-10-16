import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv
    case json

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

/// Serializes grid results for the export menu.
public enum ResultExporter {
    public static func export(columns: [String], rows: [[CellValue]], as format: ExportFormat) throws -> Data {
        switch format {
        case .csv: Data(csv(columns: columns, rows: rows).utf8)
        case .json: try json(columns: columns, rows: rows)
        }
    }

    /// RFC 4180 CSV with a header row. NULL becomes an empty field; blobs are hex.
    public static func csv(columns: [String], rows: [[CellValue]]) -> String {
        var lines = [columns.map(csvField).joined(separator: ",")]
        for row in rows {
            lines.append(row.map { value -> String in
                switch value {
                case .null: ""
                case .blob(let data): data.map { String(format: "%02x", $0) }.joined()
                default: csvField(value.displayString)
                }
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// An array of objects keyed by column name. Blobs are base64 strings.
    public static func json(columns: [String], rows: [[CellValue]]) throws -> Data {
        let objects: [[String: Any]] = rows.map { row in
            var object: [String: Any] = [:]
            for (column, value) in zip(columns, row) {
                object[column] = switch value {
                case .null: NSNull()
                case .integer(let v): v
                case .double(let v): v.isFinite ? v as Any : String(v)
                case .text(let v): v
                case .bool(let v): v
                case .blob(let d): d.base64EncodedString()
                }
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
