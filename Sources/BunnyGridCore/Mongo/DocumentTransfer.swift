import Foundation

/// Import / Export for collections: JSON (an array of relaxed Extended JSON documents, as Compass writes it),
/// JSON Lines (one per line, as `mongoexport` writes it) and CSV (the flattened grid columns).
public enum DocumentTransferFormat: String, CaseIterable, Identifiable, Sendable {
    case json = "JSON"
    case jsonLines = "JSON Lines"
    case csv = "CSV"

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .jsonLines: "jsonl"
        case .csv: "csv"
        }
    }
}

public enum DocumentTransfer {
    public static func export(_ documents: [BSONDocument], as format: DocumentTransferFormat) -> String {
        switch format {
        case .json:
            "[\n" + documents.map { "  " + BSONFormat.extendedJSON($0) }.joined(separator: ",\n") + "\n]\n"
        case .jsonLines:
            documents.map { BSONFormat.extendedJSON($0) }.joined(separator: "\n") + "\n"
        case .csv:
            csv(documents)
        }
    }

    static func csv(_ documents: [BSONDocument]) -> String {
        let flat = DocumentFlattener.flatten(documents)
        let rows = documents.map { document in
            flat.columns.map { column -> CellValue in
                guard let value = document[column] else { return .null }
                switch value {
                case .null, .undefined: return .null
                case .binary(let b) where b.uuid == nil: return .text(b.data.base64EncodedString())
                default: return .text(BSONFormat.display(value))
                }
            }
        }
        return ResultExporter.csv(columns: flat.columns, rows: rows)
    }

    /// Reads documents from an export file: a JSON array, one document, JSON Lines, or CSV with a header row.
    /// Extended JSON and shell syntax (`ObjectId("…")`) are both accepted.
    public static func read(_ text: String, format: DocumentTransferFormat? = nil) throws -> [BSONDocument] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let format = format ?? (trimmed.hasPrefix("[") || trimmed.hasPrefix("{") ? .json : .csv)
        switch format {
        case .csv:
            var rows = CSVParser.parse(text)
            guard !rows.isEmpty else { return [] }
            let header = rows.removeFirst()
            return rows.filter { !($0.count == 1 && $0[0].isEmpty) }.map { row in
                var document = BSONDocument()
                for (index, name) in header.enumerated() where index < row.count {
                    let field = row[index]
                    if field.isEmpty { continue }
                    document.append(name, csvValue(field, column: name))
                }
                return document
            }
        case .json, .jsonLines:
            if trimmed.hasPrefix("[") { return try MongoShellParser.parseDocuments(trimmed) }
            // One document, or one per line (JSON Lines).
            if let single = try? MongoShellParser.parseDocument(trimmed) { return [single] }
            var documents: [BSONDocument] = []
            for (number, line) in trimmed.split(whereSeparator: \.isNewline).enumerated() {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                do {
                    documents.append(try MongoShellParser.parseDocument(line))
                } catch {
                    throw DatabaseError.queryFailed("Line \(number + 1): \(error.localizedDescription)")
                }
            }
            return documents
        }
    }

    /// CSV fields: numbers, booleans, ObjectIds in `_id`, nested JSON; everything else stays a string.
    static func csvValue(_ field: String, column: String) -> BSON {
        if column == "_id", let id = ObjectId(field) { return .objectId(id) }
        if let v = Int64(field) { return MongoShellParserIntegers.integer(v) }
        if field.contains("."), let v = Double(field) { return .double(v) }
        if field == "true" { return .bool(true) }
        if field == "false" { return .bool(false) }
        if let first = field.first, first == "{" || first == "[", let value = try? MongoShellParser.parseValue(field) { return value }
        if field.count >= 20, field.hasSuffix("Z"), let ms = BSONFormat.parseISODate(field) { return .date(ms) }
        return .string(field)
    }
}
