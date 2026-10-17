import Foundation

/// One table as Data Transfer and Structure Synchronization see it: columns, primary key, indexes, foreign keys
/// and which columns generate their own values (serial / AUTO_INCREMENT / SQLite's INTEGER PRIMARY KEY).
public struct TableSchema: Hashable, Sendable, Identifiable {
    public var name: String
    public var columns: [TableColumn]
    /// Primary-key columns in key order.
    public var primaryKey: [String]
    /// The primary key's constraint or index name (PostgreSQL `x_pkey`, MySQL `PRIMARY`), when the engine has one.
    public var primaryKeyName: String?
    /// Secondary indexes (the primary key's index is left out).
    public var indexes: [TableIndex]
    public var foreignKeys: [TableForeignKey]
    public var autoIncrement: Set<String>
    /// Triggers' definitions (kept by the SQLite rebuild).
    public var triggers: [String]

    public init(name: String, columns: [TableColumn], primaryKey: [String]? = nil, primaryKeyName: String? = nil,
                indexes: [TableIndex] = [], foreignKeys: [TableForeignKey] = [], autoIncrement: Set<String> = [], triggers: [String] = []) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey ?? columns.filter(\.isPrimaryKey).sorted { $0.ordinal < $1.ordinal }.map(\.name)
        self.primaryKeyName = primaryKeyName
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.autoIncrement = autoIncrement
        self.triggers = triggers
    }

    public var id: String { name }

    public func column(_ name: String) -> TableColumn? {
        columns.first { $0.name == name } ?? columns.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Columns used by an index or a foreign key: MySQL needs a length for them, so text becomes varchar.
    public var keyColumns: Set<String> {
        Set(primaryKey + indexes.flatMap(\.columns) + foreignKeys.flatMap(\.columns))
    }
}

/// A view and its CREATE statement as the engine prints it.
public struct ViewSchema: Hashable, Sendable, Identifiable {
    public var name: String
    public var definition: String

    public init(name: String, definition: String) {
        self.name = name
        self.definition = definition
    }

    public var id: String { name }
}

/// The tables and views of one schema (PostgreSQL), database (MySQL) or file (SQLite).
public struct SchemaSnapshot: Hashable, Sendable {
    public var kind: DatabaseKind
    /// The schema argument the driver takes: the PostgreSQL schema, the MySQL database, nil on SQLite.
    public var schema: String?
    public var tables: [TableSchema]
    public var views: [ViewSchema]

    public init(kind: DatabaseKind, schema: String?, tables: [TableSchema], views: [ViewSchema] = []) {
        self.kind = kind
        self.schema = schema
        self.tables = tables
        self.views = views
    }

    public func table(_ name: String) -> TableSchema? {
        tables.first { $0.name == name } ?? tables.first { $0.name.lowercased() == name.lowercased() }
    }

    public func view(_ name: String) -> ViewSchema? {
        views.first { $0.name == name } ?? views.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Reads the structure of `schema`. `tables` limits it to those names (views are read only when `includeViews`).
    public static func read(from driver: any DatabaseDriver, schema: String?, tables names: Set<String>? = nil,
                            includeViews: Bool = true) async throws -> SchemaSnapshot {
        let objects = try await driver.listObjects(schema: schema)
        var tables: [TableSchema] = []
        for object in objects where object.kind == .table && (names?.contains(object.name) ?? true) {
            try Task.checkCancellation()
            tables.append(try await readTable(object.name, from: driver, schema: schema))
        }
        var views: [ViewSchema] = []
        if includeViews {
            for object in objects where object.kind == .view && (names?.contains(object.name) ?? true) {
                let ddl = (try? await driver.objectDDL(name: object.name, kind: .view, schema: schema)) ?? ""
                views.append(ViewSchema(name: object.name, definition: ddl))
            }
        }
        return SchemaSnapshot(kind: driver.config.kind, schema: schema, tables: tables, views: views)
    }

    public static func readTable(_ name: String, from driver: any DatabaseDriver, schema: String?) async throws -> TableSchema {
        let dialect = driver.dialect
        let columns = try await driver.listColumns(table: name, schema: schema)
        let allIndexes = try await driver.listIndexes(table: name, schema: schema)
        let keys = (try? await driver.listForeignKeys(table: name, schema: schema)) ?? []
        let triggers = ((try? await driver.listTriggers(table: name, schema: schema)) ?? []).map(\.definition)
        let primaryIndex = allIndexes.first(where: \.primary)
        var primaryKey = columns.filter(\.isPrimaryKey).sorted { $0.ordinal < $1.ordinal }.map(\.name)
        if let primaryIndex, Set(primaryIndex.columns) == Set(primaryKey) { primaryKey = primaryIndex.columns }

        var auto = Set<String>()
        switch dialect.kind {
        case .postgresql:
            for column in columns where column.defaultValue?.lowercased().hasPrefix("nextval(") == true { auto.insert(column.name) }
        case .sqlite:
            // A single INTEGER PRIMARY KEY is the rowid: it numbers new rows by itself.
            if primaryKey.count == 1, let key = columns.first(where: { $0.name == primaryKey[0] }),
               key.dataType.trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER" {
                auto.insert(key.name)
            }
        case .mysql, .mariadb, .mongodb:
            if let sql = dialect.autoIncrementColumnsQuery(table: name, schema: schema ?? driver.config.database),
               let result = try? await driver.executeStatement(sql) {
                auto.formUnion(result.rows.compactMap { $0.first?.displayString })
            }
        }
        return TableSchema(name: name, columns: columns, primaryKey: primaryKey,
                           primaryKeyName: dialect.kind == .sqlite ? nil : primaryIndex?.name,
                           indexes: allIndexes.filter { !$0.primary }, foreignKeys: keys, autoIncrement: auto, triggers: triggers)
    }
}

extension SQLDialect {
    /// MySQL / MariaDB: the table's AUTO_INCREMENT columns (information_schema.COLUMNS.EXTRA). Nil elsewhere.
    public func autoIncrementColumnsQuery(table: String, schema: String) -> String? {
        guard kind == .mysql || kind == .mariadb else { return nil }
        return """
            SELECT COLUMN_NAME FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = \(quoteLiteral(schema)) AND TABLE_NAME = \(quoteLiteral(table)) AND EXTRA LIKE '%auto_increment%'
            """
    }

    /// DROP TABLE IF EXISTS, with CASCADE on PostgreSQL so views and keys on it go too.
    public func dropTableIfExists(_ table: String, schema: String?) -> String {
        "DROP TABLE IF EXISTS \(qualifiedName(table: table, schema: schema))\(kind == .postgresql ? " CASCADE" : "")"
    }

    public func dropViewIfExists(_ view: String, schema: String?) -> String {
        "DROP VIEW IF EXISTS \(qualifiedName(table: view, schema: schema))\(kind == .postgresql ? " CASCADE" : "")"
    }

    /// The largest number of placeholders one statement may carry.
    public var maxParameters: Int {
        switch kind {
        case .sqlite: 32_000
        case .postgresql, .mysql, .mariadb, .mongodb: 65_000
        }
    }

    /// `INSERT INTO t (a, b) VALUES ($1, $2), ($3, $4)` for `rowCount` rows of `columns`.
    public func multiRowInsert(into table: String, schema: String?, columns: [String], rowCount: Int) -> String {
        let names = columns.map(quoteIdentifier).joined(separator: ", ")
        var index = 0
        let tuples = (0..<rowCount).map { _ in
            "(" + columns.map { _ in index += 1; return placeholder(index) }.joined(separator: ", ") + ")"
        }
        return "INSERT INTO \(qualifiedName(table: table, schema: schema)) (\(names)) VALUES " + tuples.joined(separator: ", ")
    }

    /// PostgreSQL: moves a serial column's sequence past the copied rows (as pg_dump's setval does).
    public func resetSequence(table: String, column: String, schema: String?) -> String? {
        guard kind == .postgresql else { return nil }
        let qualified = qualifiedName(table: table, schema: schema)
        return "SELECT setval(pg_get_serial_sequence(\(quoteLiteral(qualified)), \(quoteLiteral(column))), MAX(\(quoteIdentifier(column)))) FROM \(qualified) HAVING MAX(\(quoteIdentifier(column))) IS NOT NULL"
    }
}
