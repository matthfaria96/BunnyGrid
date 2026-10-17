import Foundation

/// The everyday object actions of the navigator and Objects tab: drop, empty, truncate, rename, duplicate.
extension SQLDialect {
    public func dropObject(_ object: DatabaseObject) -> String {
        let keyword = switch object.kind {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED VIEW"
        default: "TABLE"
        }
        return "DROP \(keyword) \(qualifiedName(object))"
    }

    /// Deletes every row; keeps auto-increment counters (Navicat's "Empty Table").
    public func emptyTable(_ object: DatabaseObject) -> String {
        "DELETE FROM \(qualifiedName(object))"
    }

    /// Deletes every row and resets counters. SQLite has no TRUNCATE: DELETE without WHERE uses its truncate
    /// optimization, and the AUTOINCREMENT counter lives in sqlite_sequence (cleared by the second statement).
    public func truncateTable(_ object: DatabaseObject) -> [String] {
        switch kind {
        case .sqlite:
            ["DELETE FROM \(qualifiedName(object))",
             "DELETE FROM sqlite_sequence WHERE name = \(quoteLiteral(object.name))"]
        case .postgresql: ["TRUNCATE TABLE \(qualifiedName(object)) RESTART IDENTITY"]
        case .mysql, .mariadb: ["TRUNCATE TABLE \(qualifiedName(object))"]
        }
    }

    public func renameObject(_ object: DatabaseObject, to newName: String) -> String {
        switch kind {
        case .mysql, .mariadb:
            "RENAME TABLE \(qualifiedName(object)) TO \(qualifiedName(table: newName, schema: object.schema))"
        case .postgresql:
            // PostgreSQL keeps the schema; the new name is unqualified.
            "ALTER \(object.kind == .view ? "VIEW" : object.kind == .materializedView ? "MATERIALIZED VIEW" : "TABLE") \(qualifiedName(object)) RENAME TO \(quoteIdentifier(newName))"
        case .sqlite:
            "ALTER TABLE \(qualifiedName(object)) RENAME TO \(quoteIdentifier(newName))"
        }
    }

    /// Copies rows between two tables with the same columns.
    public func copyRows(from source: DatabaseObject, to target: String) -> String {
        "INSERT INTO \(qualifiedName(table: target, schema: source.schema)) SELECT * FROM \(qualifiedName(source))"
    }

    /// A free name for a copy: "orders_copy", "orders_copy2", …
    public static func copyName(for name: String, existing: Set<String>) -> String {
        var candidate = name + "_copy"
        var n = 2
        while existing.contains(candidate) { candidate = "\(name)_copy\(n)"; n += 1 }
        return candidate
    }
}

extension DatabaseDriver {
    /// Navicat's "Duplicate Table": the structure (columns, keys, indexes) and optionally the rows.
    public func duplicateTable(_ source: DatabaseObject, as newName: String, withData: Bool) async throws {
        if config.readOnly { throw DatabaseError.readOnly }
        let d = dialect
        var statements: [String]
        switch config.kind {
        case .postgresql:
            statements = ["CREATE TABLE \(d.qualifiedName(table: newName, schema: source.schema)) (LIKE \(d.qualifiedName(source)) INCLUDING ALL)"]
        case .mysql, .mariadb:
            statements = ["CREATE TABLE \(d.qualifiedName(table: newName, schema: source.schema)) LIKE \(d.qualifiedName(source))"]
        case .sqlite:
            // Rebuilt from the catalog; SQLite index names are global, so they get the new table's prefix.
            let columns = try await listColumns(table: source.name, schema: source.schema).map(ColumnDesign.init)
            statements = [try d.createTable(name: newName, schema: source.schema, columns: columns)]
            for index in try await listIndexes(table: source.name, schema: source.schema) where !index.primary {
                var design = IndexDesign(index)
                design.name = newName + "_" + index.name
                statements.append(try d.createIndex(design, table: newName, schema: source.schema))
            }
        }
        if withData { statements.append(d.copyRows(from: source, to: newName)) }
        for statement in statements { _ = try await executeStatement(statement) }
    }
}

/// Writes a table, view or whole database as a runnable SQL script (Navicat's "Dump SQL File").
public enum SQLDumper {
    public static let batchSize = 500

    public static func dump(_ objects: [DatabaseObject], from driver: any DatabaseDriver, includeData: Bool,
                            header: String? = nil) async throws -> String {
        let d = driver.dialect
        var out: [String] = []
        if let header { out.append(header.split(separator: "\n", omittingEmptySubsequences: false).map { "-- " + $0 }.joined(separator: "\n")) }
        // Tables first, then views, so views find their tables.
        let ordered = objects.filter { $0.kind == .table } + objects.filter { $0.kind != .table && $0.kind != .routine }
        // Foreign keys must not depend on the order of the tables: MySQL turns the checks off for the script,
        // PostgreSQL's ALTER TABLE … ADD … FOREIGN KEY statements move to the end, after every table and its rows.
        let mysql = d.kind == .mysql || d.kind == .mariadb
        if mysql && ordered.contains(where: { $0.kind == .table }) { out.append("SET FOREIGN_KEY_CHECKS = 0;") }
        var deferredKeys: [String] = []
        for object in ordered {
            try Task.checkCancellation()
            out.append("-- \(object.kind == .table ? "Table" : "View"): \(object.qualifiedName)")
            out.append(d.dropObject(object).replacingOccurrences(of: "DROP TABLE ", with: "DROP TABLE IF EXISTS ")
                .replacingOccurrences(of: "DROP VIEW ", with: "DROP VIEW IF EXISTS ")
                .replacingOccurrences(of: "DROP MATERIALIZED VIEW ", with: "DROP MATERIALIZED VIEW IF EXISTS ") + ";")
            var ddl = try await driver.objectDDL(name: object.name, kind: object.kind, schema: object.schema)
            if d.kind == .postgresql, object.kind == .table {
                let statements = SQLSplitter.split(ddl)
                let isKey = { (sql: String) in sql.hasPrefix("ALTER TABLE ") && sql.contains(" FOREIGN KEY ") }
                deferredKeys += statements.filter(isKey).map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                ddl = statements.filter { !isKey($0) }.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
            }
            out.append(ddl.hasSuffix(";") ? ddl : ddl + ";")
            guard includeData, object.kind == .table else { continue }
            let target = d.qualifiedName(object)
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema, batchSize: batchSize)
            let columns = page.columns.map(d.quoteIdentifier).joined(separator: ", ")
            for row in page.rows {
                out.append("INSERT INTO \(target) (\(columns)) VALUES (\(row.map(d.literal).joined(separator: ", ")));")
            }
        }
        if !deferredKeys.isEmpty { out.append("-- Foreign keys"); out += deferredKeys }
        if mysql && ordered.contains(where: { $0.kind == .table }) { out.append("SET FOREIGN_KEY_CHECKS = 1;") }
        return out.joined(separator: "\n\n") + "\n"
    }
}

extension DatabaseDriver {
    /// Every row of a table or view, fetched in pages ordered by the primary key when there is one.
    public func fetchAllRows(table: String, schema: String?, batchSize: Int = 1000) async throws -> TablePage {
        let order = try await listColumns(table: table, schema: schema)
            .filter(\.isPrimaryKey).map { OrderBy(column: $0.name, direction: .ascending) }
        var all = TablePage(columns: [], rows: [], offset: 0, limit: 0)
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(table: table, schema: schema, offset: offset, limit: batchSize, orderBy: order)
            if all.columns.isEmpty { all.columns = page.columns }
            all.rows += page.rows
            if page.rows.count < batchSize { break }
            offset += batchSize
        }
        all.limit = all.rows.count
        return all
    }
}

/// Export Wizard formats: data files, or a SQL script per object.
public enum TableExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, sql
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sql: "SQL (structure and INSERTs)"
        }
    }
}

public enum TableExporter {
    public static func export(_ object: DatabaseObject, from driver: any DatabaseDriver, as format: TableExportFormat) async throws -> Data {
        switch format {
        case .sql:
            return Data(try await SQLDumper.dump([object], from: driver, includeData: object.kind == .table).utf8)
        case .csv, .json:
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema)
            return try ResultExporter.export(columns: page.columns, rows: page.rows, as: format == .csv ? .csv : .json)
        }
    }
}
