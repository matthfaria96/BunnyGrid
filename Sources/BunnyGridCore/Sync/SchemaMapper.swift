import Foundation

/// A table as it should be created on the target engine: types translated, auto-numbered columns marked,
/// indexes and foreign keys renamed where the target needs it.
public struct TableDefinition: Hashable, Sendable, Identifiable {
    public var name: String
    public var columns: [ColumnDesign]
    public var primaryKey: [String]
    public var autoIncrement: Set<String>
    public var indexes: [IndexDesign]
    public var foreignKeys: [TableForeignKey]

    public init(name: String, columns: [ColumnDesign], primaryKey: [String], autoIncrement: Set<String> = [],
                indexes: [IndexDesign] = [], foreignKeys: [TableForeignKey] = []) {
        self.name = name
        self.columns = columns
        self.primaryKey = primaryKey
        self.autoIncrement = autoIncrement
        self.indexes = indexes
        self.foreignKeys = foreignKeys
    }

    public var id: String { name }
}

/// Type and default translation between engines for Data Transfer and Structure Synchronization.
/// Builds on the Model's forward engineering (`ERModel.translateType` / `portableDefault`) and falls back on the
/// column's value category for types the target doesn't have (arrays, enums, geometry, intervals, money…).
public enum SchemaMapper {
    /// The type `type` (declared on `source`) becomes on `target`. `isKey`: the column is in a key or index.
    public static func columnType(_ type: String, from source: DatabaseKind, to target: DatabaseKind, isKey: Bool = false) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        if source.dialectFamily == target.dialectFamily { return trimmed.isEmpty ? (target == .sqlite ? "TEXT" : "text") : trimmed }
        var input = trimmed
        // SQLite's FLOAT and DOUBLE are both 8-byte reals.
        if source == .sqlite, input.lowercased().hasPrefix("float") { input = "DOUBLE" }
        let category = ColumnTypeCategory.classify(input.isEmpty ? "TEXT" : input, kind: source)
        if category == .other && !(source == .sqlite) { return fallbackType(category, to: target, isKey: isKey) }
        let translated = ERModel.translateType(input, from: source, to: target, isKey: isKey)
        if target == .sqlite { return translated }
        let changed = translated.lowercased() != input.lowercased()
        if changed || isNative(translated, on: target) { return translated }
        return fallbackType(category, to: target, isKey: isKey)
    }

    /// Words every target accepts as a base type, so an untranslated type is kept only when the target knows it.
    private static func isNative(_ type: String, on kind: DatabaseKind) -> Bool {
        let base = type.lowercased().prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .postgresql:
            return ["integer", "bigint", "smallint", "boolean", "real", "double precision", "numeric", "varchar", "char", "text",
                    "bytea", "date", "time", "timestamp", "timestamptz", "uuid", "json", "jsonb", "bit", "inet", "cidr",
                    "macaddr", "interval", "xml"].contains(base)
        case .mysql, .mariadb, .mongodb:
            return ["int", "bigint", "smallint", "mediumint", "tinyint", "double", "float", "decimal", "varchar", "char", "text",
                    "longtext", "mediumtext", "longblob", "blob", "date", "time", "datetime", "timestamp", "json", "bit", "year"].contains(base)
        case .sqlite:
            return true
        }
    }

    private static func fallbackType(_ category: ColumnTypeCategory, to target: DatabaseKind, isKey: Bool) -> String {
        let pg = target == .postgresql
        switch target {
        case .sqlite:
            switch category {
            case .integer, .boolean: return "INTEGER"
            case .real: return "REAL"
            case .decimal: return "NUMERIC"
            case .binary: return "BLOB"
            default: return "TEXT"
            }
        case .postgresql, .mysql, .mariadb, .mongodb:
            switch category {
            case .integer: return "bigint"
            case .real: return pg ? "double precision" : "double"
            case .decimal: return pg ? "numeric" : "decimal(38,10)"
            case .boolean: return pg ? "boolean" : "tinyint(1)"
            case .binary: return pg ? "bytea" : "longblob"
            case .json: return "json"
            case .date: return "date"
            case .time, .timeWithTimeZone: return "time"
            case .dateTime: return pg ? "timestamp" : "datetime"
            case .dateTimeWithTimeZone: return pg ? "timestamptz" : "datetime"
            case .uuid: return pg ? "uuid" : "char(36)"
            case .text, .other: return !pg && isKey ? "varchar(255)" : "text"
            }
        }
    }

    /// The default expression on `target`: the same engine keeps it; another engine keeps only defaults every
    /// engine reads the same way. Auto-numbered columns get none (the target numbers them itself).
    public static func columnDefault(_ value: String?, type: String, from source: DatabaseKind, to target: DatabaseKind) -> String {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
        if source.dialectFamily == target.dialectFamily {
            return source == .mysql || source == .mariadb ? quotedMySQLDefault(raw, type: type, kind: source) : raw
        }
        let input = source == .mysql || source == .mariadb ? quotedMySQLDefault(raw, type: type, kind: source) : raw
        var portable = ERModel.portableDefault(input)
        if ColumnTypeCategory.classify(type, kind: source) == .boolean || ColumnTypeCategory.classify(type, kind: target) == .boolean {
            switch portable.uppercased() {
            case "1", "TRUE", "'1'", "'T'", "'TRUE'": portable = target == .sqlite ? "1" : "TRUE"
            case "0", "FALSE", "'0'", "'F'", "'FALSE'": portable = target == .sqlite ? "0" : "FALSE"
            default: break
            }
            if target == .mysql || target == .mariadb { portable = portable == "TRUE" ? "1" : portable == "FALSE" ? "0" : portable }
        }
        return portable
    }

    /// MySQL 8 reports string defaults without quotes (`n/a`); expressions and numbers stay as they are.
    static func quotedMySQLDefault(_ value: String, type: String, kind: DatabaseKind) -> String {
        if value.hasPrefix("'") || value.uppercased() == "NULL" || Double(value) != nil { return value }
        let upper = value.uppercased()
        if upper.hasPrefix("CURRENT_") || upper.hasPrefix("NOW(") || value.contains("(") && value.hasSuffix(")") { return value }
        let category = ColumnTypeCategory.classify(type, kind: kind)
        if category.isNumeric || category == .boolean { return value }
        return SQLDialect(kind: kind).quoteLiteral(value)
    }

    /// `table` as it should be created on `target`. `primaryKeyOf` resolves the parent key of a foreign key that names
    /// no referenced columns (SQLite's implicit reference); `include` keeps only keys to tables that will exist.
    public static func definition(of table: TableSchema, from source: DatabaseKind, to target: DatabaseKind, targetSchema: String?,
                                  primaryKeyOf: (String) -> [String]? = { _ in nil },
                                  include: (String) -> Bool = { _ in true }) -> TableDefinition {
        let keyColumns = table.keyColumns
        let primary = Set(table.primaryKey)
        // Only a single key column can number itself everywhere (SQLite's rowid, MySQL's AUTO_INCREMENT key).
        let auto = table.primaryKey.count == 1 ? table.autoIncrement.intersection(primary) : (target == .postgresql ? table.autoIncrement : [])
        let columns = table.columns.sorted { $0.ordinal < $1.ordinal }.map { column -> ColumnDesign in
            let type = columnType(column.dataType, from: source, to: target, isKey: keyColumns.contains(column.name))
            let isAuto = auto.contains(column.name)
            return ColumnDesign(name: column.name, type: isAuto ? autoType(type, target: target) : type,
                                nullable: column.nullable && !primary.contains(column.name),
                                defaultValue: isAuto ? "" : columnDefault(column.defaultValue, type: column.dataType, from: source, to: target),
                                isPrimaryKey: primary.contains(column.name))
        }
        var indexes: [IndexDesign] = []
        var seen = Set<String>()
        // A unique index on exactly the primary key repeats it.
        for index in table.indexes where !index.columns.isEmpty && !(index.unique && Set(index.columns) == primary) {
            var name = index.name
            if name.hasPrefix("sqlite_autoindex_") || name.isEmpty { name = "\(table.name)_\(index.columns.joined(separator: "_"))_key" }
            guard seen.insert(name.lowercased()).inserted else { continue }
            indexes.append(IndexDesign(name: name, columns: index.columns, unique: index.unique))
        }
        let keys = table.foreignKeys.compactMap { key -> TableForeignKey? in
            guard include(key.referencedTable) else { return nil }
            var key = key
            if key.referencedColumns.allSatisfy(\.isEmpty) {
                guard let parentKey = primaryKeyOf(key.referencedTable), parentKey.count == key.columns.count else {
                    return target == .sqlite ? key : nil
                }
                key.referencedColumns = parentKey
            }
            key.referencedSchema = target == .postgresql ? targetSchema : nil
            if target != .sqlite && key.name.isEmpty { key.name = "fk_\(table.name)_\(key.columns.joined(separator: "_"))" }
            if target == .sqlite { key.name = source == .sqlite ? key.name : "" }
            key.onDelete = normalizedAction(key.onDelete)
            key.onUpdate = normalizedAction(key.onUpdate)
            return key
        }
        return TableDefinition(name: table.name, columns: columns, primaryKey: table.primaryKey, autoIncrement: auto,
                               indexes: indexes, foreignKeys: keys)
    }

    static func normalizedAction(_ action: String) -> String {
        let upper = action.uppercased().trimmingCharacters(in: .whitespaces)
        return TableForeignKey.actions.contains(upper) ? upper : "NO ACTION"
    }

    /// serial types on PostgreSQL; INTEGER on SQLite (an INTEGER PRIMARY KEY is the rowid); the type itself on MySQL.
    static func autoType(_ type: String, target: DatabaseKind) -> String {
        let lower = type.lowercased()
        switch target {
        case .postgresql:
            if lower.contains("serial") { return lower }
            if lower.hasPrefix("bigint") || lower.hasPrefix("int8") { return "bigserial" }
            if lower.hasPrefix("smallint") || lower.hasPrefix("int2") { return "smallserial" }
            return "serial"
        case .sqlite:
            return "INTEGER"
        case .mysql, .mariadb, .mongodb:
            return type
        }
    }

    // MARK: - Comparison

    /// A type in a form both sides of a comparison agree on: `int4` and `integer`, `float8` and `double precision`,
    /// `timestamp(6)` and `timestamp` (6 is PostgreSQL's default precision).
    public static func canonicalType(_ type: String, kind: DatabaseKind) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        if kind == .sqlite { return trimmed.uppercased().replacingOccurrences(of: " ", with: "") }
        var lower = trimmed.lowercased()
        if kind == .postgresql {
            switch lower {
            case "serial", "serial4": lower = "int4"
            case "bigserial", "serial8": lower = "int8"
            case "smallserial", "serial2": lower = "int2"
            default: break
            }
        }
        var result = ERModel.translateType(lower, from: kind, to: kind, isKey: false).lowercased()
        if kind == .postgresql {
            for suffix in ["(6)"] where result.hasSuffix(suffix) && (result.hasPrefix("timestamp") || result.hasPrefix("time")) {
                result.removeLast(suffix.count)
            }
        }
        if kind == .mysql || kind == .mariadb {
            // Display widths (int(11)) mean nothing since MySQL 8.0.17.
            result = result.replacing(/^(int|bigint|smallint|mediumint)\(\d+\)/, with: { $0.output.1 })
        }
        return result.replacingOccurrences(of: " ", with: "")
    }

    /// A default in a form both sides agree on (casts and parentheses dropped, keywords uppercased).
    public static func canonicalDefault(_ value: String, kind: DatabaseKind, type: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.uppercased() != "NULL" else { return "" }
        let portable = ERModel.portableDefault(trimmed)
        var result = portable.isEmpty ? trimmed : portable
        if ColumnTypeCategory.classify(type, kind: kind) == .boolean {
            switch result.uppercased() {
            case "1", "TRUE", "'1'", "'T'", "'TRUE'": result = "TRUE"
            case "0", "FALSE", "'0'", "'F'", "'FALSE'": result = "FALSE"
            default: break
            }
        }
        if let number = Double(result) { return String(number) }
        return result
    }
}

extension DatabaseKind {
    /// MySQL and MariaDB share a dialect.
    var dialectFamily: DatabaseKind { self == .mariadb ? .mysql : self }
}

extension SQLDialect {
    /// CREATE TABLE for a mapped definition: auto-numbered columns as serial / AUTO_INCREMENT / INTEGER PRIMARY KEY,
    /// the primary key in key order and, when asked (SQLite always needs them here), the foreign keys.
    public func createTable(_ table: TableDefinition, schema: String?, includeForeignKeys: Bool) throws -> String {
        try validate(table.columns)
        var parts = table.columns.map { column in
            "  " + columnDefinition(column) + (table.autoIncrement.contains(column.name) && (kind == .mysql || kind == .mariadb) ? " AUTO_INCREMENT" : "")
        }
        if !table.primaryKey.isEmpty { parts.append("  PRIMARY KEY (\(table.primaryKey.map(quoteIdentifier).joined(separator: ", ")))") }
        if includeForeignKeys {
            for key in table.foreignKeys { parts.append("  " + (try foreignKeyClause(key, schema: schema))) }
        }
        return "CREATE TABLE \(qualifiedName(table: table.name, schema: schema)) (\n\(parts.joined(separator: ",\n"))\n)"
    }
}
