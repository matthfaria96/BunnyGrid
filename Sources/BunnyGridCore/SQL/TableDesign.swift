import Foundation

/// One row of the table designer. `originalName` is nil for a column the user added.
public struct ColumnDesign: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var originalName: String?
    public var name: String
    public var type: String
    public var nullable: Bool
    /// Raw SQL expression, empty for no default (e.g. `0`, `'n/a'`, `now()`).
    public var defaultValue: String
    public var isPrimaryKey: Bool

    public init(originalName: String? = nil, name: String, type: String, nullable: Bool = true, defaultValue: String = "", isPrimaryKey: Bool = false) {
        self.originalName = originalName
        self.name = name
        self.type = type
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
    }

    public init(_ column: TableColumn) {
        self.init(
            originalName: column.name,
            name: column.name,
            type: column.dataType,
            nullable: column.nullable,
            defaultValue: column.defaultValue ?? "",
            isPrimaryKey: column.isPrimaryKey
        )
    }
}

/// One row of the designer's Indexes tab. `originalName` is nil for an index the user added.
public struct IndexDesign: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var originalName: String?
    public var name: String
    public var columns: [String]
    public var unique: Bool

    public init(originalName: String? = nil, name: String, columns: [String], unique: Bool = false) {
        self.originalName = originalName
        self.name = name
        self.columns = columns
        self.unique = unique
    }

    public init(_ index: TableIndex) {
        self.init(originalName: index.name, name: index.name, columns: index.columns, unique: index.unique)
    }
}

public enum TableDesignError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unsupported(let message): message
        }
    }
}

extension SQLDialect {
    /// Common column types offered by the designer's type menu.
    public var suggestedTypes: [String] {
        switch kind {
        case .postgresql:
            ["int4", "int8", "int2", "serial", "bigserial", "numeric(10,2)", "float8", "bool", "varchar(255)", "text",
             "date", "timestamp(6)", "timestamptz(6)", "uuid", "jsonb", "bytea"]
        case .mysql, .mariadb:
            ["int", "bigint", "smallint", "tinyint(1)", "decimal(10,2)", "double", "varchar(255)", "text", "longtext",
             "date", "datetime", "timestamp", "json", "blob"]
        case .sqlite:
            ["INTEGER", "REAL", "NUMERIC", "TEXT", "BLOB"]
        }
    }

    public func columnDefinition(_ column: ColumnDesign) -> String {
        var sql = "\(quoteIdentifier(column.name)) \(column.type.trimmingCharacters(in: .whitespaces))"
        if !column.nullable { sql += " NOT NULL" }
        let defaultValue = column.defaultValue.trimmingCharacters(in: .whitespaces)
        if !defaultValue.isEmpty { sql += " DEFAULT \(defaultValue)" }
        return sql
    }

    func validate(_ columns: [ColumnDesign]) throws {
        guard !columns.isEmpty else { throw TableDesignError.invalid("Add at least one field.") }
        var seen = Set<String>()
        for column in columns {
            let name = column.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw TableDesignError.invalid("Every field needs a name.") }
            guard !column.type.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TableDesignError.invalid("Field “\(name)” needs a type.")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw TableDesignError.invalid("There are two fields named “\(name)”.")
            }
        }
    }

    public func createTable(name: String, schema: String?, columns: [ColumnDesign], foreignKeys: [TableForeignKey] = []) throws -> String {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw TableDesignError.invalid("The table needs a name.") }
        try validate(columns)
        var parts = columns.map { "  " + columnDefinition($0) }
        let keys = columns.filter(\.isPrimaryKey).map { quoteIdentifier($0.name) }
        if !keys.isEmpty { parts.append("  PRIMARY KEY (\(keys.joined(separator: ", ")))") }
        for key in foreignKeys { parts.append("  " + (try foreignKeyClause(key, schema: schema))) }
        return "CREATE TABLE \(qualifiedName(table: name, schema: schema)) (\n\(parts.joined(separator: ",\n"))\n)"
    }

    public func createIndex(_ index: IndexDesign, table: String, schema: String?) throws -> String {
        guard !index.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw TableDesignError.invalid("Every index needs a name.") }
        guard !index.columns.isEmpty else { throw TableDesignError.invalid("Index “\(index.name)” needs at least one field.") }
        let columns = index.columns.map(quoteIdentifier).joined(separator: ", ")
        // PostgreSQL and SQLite put indexes in the table's schema; only the table is qualified.
        return "CREATE \(index.unique ? "UNIQUE " : "")INDEX \(quoteIdentifier(index.name)) ON \(qualifiedName(table: table, schema: schema)) (\(columns))"
    }

    public func dropIndex(named name: String, table: String, schema: String?) -> String {
        switch kind {
        case .mysql, .mariadb: "DROP INDEX \(quoteIdentifier(name)) ON \(qualifiedName(table: table, schema: schema))"
        case .postgresql: "DROP INDEX \(qualifiedName(table: name, schema: schema))"
        case .sqlite: "DROP INDEX \(quoteIdentifier(name))"
        }
    }

    /// Drops removed or changed indexes, then creates new or changed ones. Primary-key indexes are left alone.
    public func alterIndexes(table: String, schema: String?, original: [TableIndex], design: [IndexDesign]) throws -> [String] {
        let originalsByName = Dictionary(original.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var drops: [String] = []
        var creates: [String] = []
        let kept = Set(design.compactMap(\.originalName))
        for index in original where !index.primary && !kept.contains(index.name) {
            drops.append(dropIndex(named: index.name, table: table, schema: schema))
        }
        for index in design {
            if let originalName = index.originalName, let before = originalsByName[originalName] {
                guard !before.primary else { continue }
                let changed = before.name != index.name || before.columns != index.columns || before.unique != index.unique
                guard changed else { continue }
                drops.append(dropIndex(named: originalName, table: table, schema: schema))
            }
            creates.append(try createIndex(index, table: table, schema: schema))
        }
        return drops + creates
    }

    /// Statements that turn `original` into `design`: drops, renames, changes, then additions.
    public func alterTable(name: String, schema: String?, original: [TableColumn], design: [ColumnDesign]) throws -> [String] {
        try validate(design)
        let table = qualifiedName(table: name, schema: schema)
        let originalsByName = Dictionary(original.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        let originalKeys = Set(original.filter(\.isPrimaryKey).map(\.name))
        let designKeys = Set(design.filter(\.isPrimaryKey).map { $0.originalName ?? "\u{0}new:\($0.name)" })
        if originalKeys != designKeys {
            throw TableDesignError.unsupported("Changing the primary key isn't supported yet. Run ALTER TABLE in a query.")
        }

        var statements: [String] = []
        let kept = Set(design.compactMap(\.originalName))
        for column in original where !kept.contains(column.name) {
            statements.append("ALTER TABLE \(table) DROP COLUMN \(quoteIdentifier(column.name))")
        }

        for column in design {
            guard let originalName = column.originalName, let before = originalsByName[originalName] else { continue }
            if originalName != column.name {
                statements.append("ALTER TABLE \(table) RENAME COLUMN \(quoteIdentifier(originalName)) TO \(quoteIdentifier(column.name))")
            }
            let typeChanged = before.dataType.lowercased() != column.type.trimmingCharacters(in: .whitespaces).lowercased()
            let nullChanged = before.nullable != column.nullable
            let newDefault = column.defaultValue.trimmingCharacters(in: .whitespaces)
            let defaultChanged = (before.defaultValue ?? "") != newDefault
            guard typeChanged || nullChanged || defaultChanged else { continue }

            let target = quoteIdentifier(column.name)
            switch kind {
            case .postgresql:
                if typeChanged { statements.append("ALTER TABLE \(table) ALTER COLUMN \(target) TYPE \(column.type)") }
                if nullChanged { statements.append("ALTER TABLE \(table) ALTER COLUMN \(target) \(column.nullable ? "DROP" : "SET") NOT NULL") }
                if defaultChanged {
                    statements.append(newDefault.isEmpty
                        ? "ALTER TABLE \(table) ALTER COLUMN \(target) DROP DEFAULT"
                        : "ALTER TABLE \(table) ALTER COLUMN \(target) SET DEFAULT \(newDefault)")
                }
            case .mysql, .mariadb:
                statements.append("ALTER TABLE \(table) MODIFY COLUMN \(columnDefinition(column))")
            case .sqlite:
                throw TableDesignError.unsupported("SQLite can't change the type, NOT NULL or default of “\(column.name)”. Recreate the table to change it.")
            }
        }

        for column in design where column.originalName == nil {
            if kind == .sqlite && !column.nullable && column.defaultValue.trimmingCharacters(in: .whitespaces).isEmpty {
                throw TableDesignError.unsupported("SQLite needs a default value to add the NOT NULL field “\(column.name)”.")
            }
            statements.append("ALTER TABLE \(table) ADD COLUMN \(columnDefinition(column))")
        }
        return statements
    }
}
