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

/// What a SQL dump contains.
public struct SQLDumpOptions: Sendable, Equatable {
    /// DROP … IF EXISTS before each CREATE.
    public var includeDrop: Bool
    /// The CREATE statement of each object.
    public var includeStructure: Bool
    /// INSERT statements for the rows of each table.
    public var includeData: Bool
    /// Rows per INSERT statement (1 = one statement per row).
    public var rowsPerInsert: Int

    public init(includeDrop: Bool = true, includeStructure: Bool = true, includeData: Bool = true, rowsPerInsert: Int = 1) {
        self.includeDrop = includeDrop
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.rowsPerInsert = rowsPerInsert
    }
}

extension SQLDialect {
    /// INSERT statements for rows, `rowsPerInsert` rows per statement, values as literals of this engine.
    public func insertStatements(into target: String, columns: [String], rows: [[CellValue]], rowsPerInsert: Int = 1) -> [String] {
        guard !rows.isEmpty else { return [] }
        let names = columns.isEmpty ? "" : " (" + columns.map(quoteIdentifier).joined(separator: ", ") + ")"
        let size = max(1, rowsPerInsert)
        return stride(from: 0, to: rows.count, by: size).map { start in
            let tuples = rows[start..<min(start + size, rows.count)].map { "(" + $0.map(literal).joined(separator: ", ") + ")" }
            return "INSERT INTO \(target)\(names) VALUES " + tuples.joined(separator: ",\n  ") + ";"
        }
    }

    /// How a dump names an object. MySQL dumps use bare names, as mysqldump does, so they restore into any database.
    public func dumpName(_ object: DatabaseObject) -> String {
        kind == .mysql || kind == .mariadb ? quoteIdentifier(object.name) : qualifiedName(object)
    }

    /// PostgreSQL serial columns default to `nextval('seq'::regclass)`, and the sequence is dropped with the table.
    /// A dump recreates each sequence before the table, gives it back to its column, and moves it past the
    /// restored rows (as pg_dump does with setval).
    public func sequenceStatements(forDDL ddl: String, table: String) -> (create: [String], own: [String], reset: [String]) {
        guard kind == .postgresql,
              let pattern = try? NSRegularExpression(pattern: #"("(?:[^"]|"")+") [^,\n]*?DEFAULT nextval\('((?:[^']|'')+)'::regclass\)"#) else {
            return ([], [], [])
        }
        var create: [String] = [], own: [String] = [], reset: [String] = []
        let text = ddl as NSString
        for match in pattern.matches(in: ddl, range: NSRange(location: 0, length: text.length)) {
            let column = text.substring(with: match.range(at: 1))
            let sequence = text.substring(with: match.range(at: 2)).replacingOccurrences(of: "''", with: "'")
            create.append("CREATE SEQUENCE IF NOT EXISTS \(sequence);")
            own.append("ALTER SEQUENCE \(sequence) OWNED BY \(table).\(column);")
            reset.append("SELECT setval(\(quoteLiteral(sequence)), MAX(\(column))) FROM \(table) HAVING MAX(\(column)) IS NOT NULL;")
        }
        return (create, own, reset)
    }

    func dropIfExists(_ object: DatabaseObject) -> String {
        let keyword = switch object.kind {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED VIEW"
        default: "TABLE"
        }
        return "DROP \(keyword) IF EXISTS \(dumpName(object));"
    }
}

/// Writes a table, view or whole database as a runnable SQL script (Navicat's "Dump SQL File").
public enum SQLDumper {
    public static let batchSize = 500

    public static func dump(_ objects: [DatabaseObject], from driver: any DatabaseDriver, includeData: Bool,
                            header: String? = nil) async throws -> String {
        try await dump(objects, from: driver, options: SQLDumpOptions(includeData: includeData), header: header)
    }

    public static func dump(_ objects: [DatabaseObject], from driver: any DatabaseDriver, options: SQLDumpOptions,
                            header: String? = nil) async throws -> String {
        let d = driver.dialect
        let isMySQL = d.kind == .mysql || d.kind == .mariadb
        var out: [String] = []
        if let header { out.append(header.split(separator: "\n", omittingEmptySubsequences: false).map { "-- " + $0 }.joined(separator: "\n")) }
        // Tables first, then views, so views find their tables.
        let ordered = objects.filter { $0.kind == .table } + objects.filter { $0.kind != .table && $0.kind != .routine }
        // Foreign keys must not depend on the order of the tables: MySQL turns the checks off for the script,
        // PostgreSQL's ALTER TABLE … ADD … FOREIGN KEY statements move to the end, after every table and its rows.
        if isMySQL && ordered.contains(where: { $0.kind == .table }) { out.append("SET FOREIGN_KEY_CHECKS = 0;") }
        var deferredKeys: [String] = []
        for object in ordered {
            try Task.checkCancellation()
            out.append("-- \(object.kind == .table ? "Table" : "View"): \(object.qualifiedName)")
            var resetSequences: [String] = []
            if options.includeStructure {
                if options.includeDrop { out.append(d.dropIfExists(object)) }
                var ddl = try await driver.objectDDL(name: object.name, kind: object.kind, schema: object.schema)
                if d.kind == .postgresql, object.kind == .table {
                    let statements = SQLSplitter.split(ddl)
                    let isKey = { (sql: String) in sql.hasPrefix("ALTER TABLE ") && sql.contains(" FOREIGN KEY ") }
                    deferredKeys += statements.filter(isKey).map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                    ddl = statements.filter { !isKey($0) }.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n")
                }
                let sequences = object.kind == .table
                    ? d.sequenceStatements(forDDL: ddl, table: d.dumpName(object))
                    : (create: [], own: [], reset: [])
                if !sequences.create.isEmpty { out.append(sequences.create.joined(separator: "\n")) }
                out.append(ddl.hasSuffix(";") ? ddl : ddl + ";")
                if !sequences.own.isEmpty { out.append(sequences.own.joined(separator: "\n")) }
                resetSequences = sequences.reset
            }
            guard options.includeData, object.kind == .table else { continue }
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema, batchSize: batchSize)
            let inserts = d.insertStatements(into: d.dumpName(object), columns: page.columns, rows: page.rows, rowsPerInsert: options.rowsPerInsert)
            if !inserts.isEmpty { out.append((inserts + resetSequences).joined(separator: "\n")) }
        }
        if !deferredKeys.isEmpty { out.append("-- Foreign keys"); out += deferredKeys }
        if isMySQL && ordered.contains(where: { $0.kind == .table }) { out.append("SET FOREIGN_KEY_CHECKS = 1;") }
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

/// Export Wizard formats: data files, a SQL script or an Excel workbook.
public enum TableExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, sql, xlsx
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sql: "SQL (INSERT statements)"
        case .xlsx: "Excel (.xlsx)"
        }
    }
}

/// Export Wizard options; each format reads the ones that apply to it.
public struct TableExportOptions: Sendable, Equatable {
    public var csvDelimiter: Character
    /// Field names as the first row (CSV and Excel).
    public var includeHeader: Bool
    public var sql: SQLDumpOptions

    public init(csvDelimiter: Character = ",", includeHeader: Bool = true, sql: SQLDumpOptions = SQLDumpOptions()) {
        self.csvDelimiter = csvDelimiter
        self.includeHeader = includeHeader
        self.sql = sql
    }
}

public enum TableExporter {
    public static func export(_ object: DatabaseObject, from driver: any DatabaseDriver, as format: TableExportFormat,
                              options: TableExportOptions = TableExportOptions()) async throws -> Data {
        switch format {
        case .sql:
            var sql = options.sql
            sql.includeData = sql.includeData && object.kind == .table
            return Data(try await SQLDumper.dump([object], from: driver, options: sql).utf8)
        case .csv:
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema)
            return Data(ResultExporter.csv(columns: page.columns, rows: page.rows, delimiter: options.csvDelimiter,
                                           includeHeader: options.includeHeader).utf8)
        case .json:
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema)
            return ResultExporter.json(columns: page.columns, rows: page.rows)
        case .xlsx:
            return try await workbook([object], from: driver, includeHeader: options.includeHeader)
        }
    }

    /// One workbook with a sheet per object. `progress` gets the index of the object being read.
    public static func workbook(_ objects: [DatabaseObject], from driver: any DatabaseDriver, includeHeader: Bool = true,
                                progress: @Sendable (Int) async -> Void = { _ in }) async throws -> Data {
        var sheets: [XLSXSheet] = []
        for (index, object) in objects.enumerated() {
            try Task.checkCancellation()
            await progress(index)
            let page = try await driver.fetchAllRows(table: object.name, schema: object.schema)
            sheets.append(XLSXSheet(name: object.name, columns: includeHeader ? page.columns : [], rows: page.rows))
        }
        return try XLSXWriter.workbook(sheets)
    }
}
