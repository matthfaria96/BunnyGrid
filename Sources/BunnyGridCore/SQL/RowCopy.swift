import Foundation

/// The grid's "Copy As" formats.
public enum RowCopyFormat: String, CaseIterable, Sendable, Identifiable {
    case insertStatements
    case updateStatements
    case tsv
    case tsvWithNames
    case csv
    case json
    case markdown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .insertStatements: "Insert Statements"
        case .updateStatements: "Update Statements"
        case .tsv: "Tab Separated Values (Data Only)"
        case .tsvWithNames: "Tab Separated Values (Field Names and Data)"
        case .csv: "CSV"
        case .json: "JSON"
        case .markdown: "Markdown Table"
        }
    }

    /// Statements need a table to target.
    public var needsTable: Bool { self == .insertStatements || self == .updateStatements }
}

/// Serializes selected grid rows for the clipboard.
public enum RowCopier {
    /// `table` (and `keyColumns` for UPDATE) are needed by the statement formats; returns nil when
    /// the format can't be produced (no table, or no key for UPDATE).
    public static func text(_ format: RowCopyFormat, columns: [String], rows: [[CellValue]],
                            table: String? = nil, schema: String? = nil, kind: DatabaseKind = .postgresql,
                            keyColumns: [String] = []) -> String? {
        switch format {
        case .insertStatements:
            guard let table else { return nil }
            return insertStatements(columns: columns, rows: rows, table: table, schema: schema, kind: kind)
        case .updateStatements:
            guard let table else { return nil }
            return updateStatements(columns: columns, rows: rows, table: table, schema: schema, kind: kind, keyColumns: keyColumns)
        case .tsv: return tsv(columns: columns, rows: rows, includeNames: false)
        case .tsvWithNames: return tsv(columns: columns, rows: rows, includeNames: true)
        case .csv: return ResultExporter.csv(columns: columns, rows: rows).replacingOccurrences(of: "\r\n", with: "\n")
        case .json: return json(columns: columns, rows: rows)
        case .markdown: return markdown(columns: columns, rows: rows)
        }
    }

    /// One `INSERT INTO … (…) VALUES (…);` per row, with this engine's quoting and literals.
    public static func insertStatements(columns: [String], rows: [[CellValue]], table: String, schema: String?, kind: DatabaseKind) -> String {
        let dialect = SQLDialect(kind: kind)
        return rows.map { row in
            dialect.sql(for: .insert(values: zip(columns, row).map { ColumnValue($0, $1) }), table: table, schema: schema) + ";"
        }
        .joined(separator: "\n")
    }

    /// One `UPDATE … SET … WHERE key = …;` per row. Nil without key columns among `columns`.
    public static func updateStatements(columns: [String], rows: [[CellValue]], table: String, schema: String?, kind: DatabaseKind,
                                        keyColumns: [String]) -> String? {
        guard !keyColumns.isEmpty, keyColumns.allSatisfy(columns.contains) else { return nil }
        let dialect = SQLDialect(kind: kind)
        return rows.map { row in
            let pairs = zip(columns, row).map { ColumnValue($0, $1) }
            let key = keyColumns.compactMap { name in pairs.first { $0.column == name } }
            let values = pairs.filter { !keyColumns.contains($0.column) }
            guard !values.isEmpty else { return "" }
            return dialect.sql(for: .update(key: key, values: values), table: table, schema: schema) + ";"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Tab-separated, ready to paste into a spreadsheet. NULL is an empty field; fields with tabs,
    /// line breaks or quotes are quoted as spreadsheets expect.
    public static func tsv(columns: [String], rows: [[CellValue]], includeNames: Bool) -> String {
        func field(_ text: String) -> String {
            guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines: [String] = []
        if includeNames { lines.append(columns.map(field).joined(separator: "\t")) }
        for row in rows {
            lines.append(row.map { value in
                switch value {
                case .null: ""
                case .blob(let data): "0x" + HexFormatter.hexString(data)
                default: field(value.displayString)
                }
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// An array of objects with keys in column order. Blobs are base64 strings, as in the JSON export.
    public static func json(columns: [String], rows: [[CellValue]]) -> String {
        func encode(_ string: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        func encode(_ value: CellValue) -> String {
            switch value {
            case .null: return "null"
            case .integer(let v): return String(v)
            case .double(let v): return v.isFinite ? String(v) : encode(String(v))
            case .bool(let v): return v ? "true" : "false"
            case .text(let v): return encode(v)
            case .blob(let d): return encode(d.base64EncodedString())
            }
        }
        guard !rows.isEmpty else { return "[]" }
        let objects = rows.map { row in
            let fields = zip(columns, row).map { "    \(encode($0)): \(encode($1))" }
            return "  {\n" + fields.joined(separator: ",\n") + "\n  }"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    /// A GitHub-flavored Markdown table. Pipes are escaped and line breaks become `<br>`.
    public static func markdown(columns: [String], rows: [[CellValue]]) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        var lines = [
            "| " + columns.map(cell).joined(separator: " | ") + " |",
            "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|",
        ]
        for row in rows {
            lines.append("| " + row.map { value in
                switch value {
                case .null: "NULL"
                case .blob(let data): "0x" + HexFormatter.hexString(data.prefix(32)) + (data.count > 32 ? "…" : "")
                default: cell(value.displayString)
                }
            }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

extension TableColumn {
    /// Whether the database fills this column when an INSERT leaves it out and a copy would clash:
    /// serial/identity/auto-increment keys and keys with a generated default (`gen_random_uuid()`).
    /// Duplicating a row skips these columns.
    public func isGeneratedOnInsert(among columns: [TableColumn], kind: DatabaseKind) -> Bool {
        let defaultExpression = defaultValue?.lowercased() ?? ""
        if defaultExpression.contains("nextval(") { return true }
        guard isPrimaryKey else { return false }
        if !defaultExpression.isEmpty { return true }
        // A single integer key is a rowid alias (SQLite), AUTO_INCREMENT (MySQL) or IDENTITY (PostgreSQL) in practice.
        let keyCount = columns.filter(\.isPrimaryKey).count
        return keyCount == 1 && ColumnTypeCategory.classify(dataType, kind: kind) == .integer
    }
}
