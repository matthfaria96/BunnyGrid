import Foundation

/// A foreign key of a table (Table Design › Foreign Keys).
public struct TableForeignKey: Hashable, Identifiable, Sendable {
    public var name: String
    public var columns: [String]
    public var referencedSchema: String?
    public var referencedTable: String
    public var referencedColumns: [String]
    /// "NO ACTION", "CASCADE", "SET NULL", "RESTRICT", "SET DEFAULT".
    public var onDelete: String
    public var onUpdate: String

    public init(name: String, columns: [String], referencedSchema: String? = nil, referencedTable: String, referencedColumns: [String],
                onDelete: String = "NO ACTION", onUpdate: String = "NO ACTION") {
        self.name = name
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    public var id: String { name.isEmpty ? columns.joined(separator: ",") + "→" + referencedTable : name }

    public static let actions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]
}

/// A trigger on a table (Table Design › Triggers).
public struct TableTrigger: Hashable, Identifiable, Sendable {
    public var name: String
    /// "BEFORE", "AFTER" or "INSTEAD OF".
    public var timing: String
    /// "INSERT", "UPDATE", "DELETE" (several for PostgreSQL).
    public var events: [String]
    /// The full CREATE TRIGGER statement or body, as the engine reports it.
    public var definition: String

    public init(name: String, timing: String, events: [String], definition: String) {
        self.name = name
        self.timing = timing
        self.events = events
        self.definition = definition
    }

    public var id: String { name }
}

extension SQLDialect {
    /// ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY; SQLite can't add one to an existing table.
    public func addForeignKey(_ key: TableForeignKey, table: String, schema: String?) throws -> String {
        guard kind != .sqlite else {
            throw TableDesignError.invalid("SQLite can't add a foreign key to an existing table; recreate the table with the key in its CREATE TABLE.")
        }
        guard !key.columns.isEmpty, key.columns.count == key.referencedColumns.count, !key.referencedTable.isEmpty else {
            throw TableDesignError.invalid("Foreign key “\(key.name)” needs matching fields and referenced fields.")
        }
        let name = key.name.trimmingCharacters(in: .whitespaces)
        let constraint = name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(name)) "
        let columns = key.columns.map(quoteIdentifier).joined(separator: ", ")
        let references = key.referencedColumns.map(quoteIdentifier).joined(separator: ", ")
        var sql = "ALTER TABLE \(qualifiedName(table: table, schema: schema)) ADD \(constraint)FOREIGN KEY (\(columns)) REFERENCES \(qualifiedName(table: key.referencedTable, schema: key.referencedSchema ?? schema)) (\(references))"
        if key.onDelete != "NO ACTION" { sql += " ON DELETE \(key.onDelete)" }
        if key.onUpdate != "NO ACTION" { sql += " ON UPDATE \(key.onUpdate)" }
        return sql
    }

    public func dropForeignKey(named name: String, table: String, schema: String?) throws -> String {
        switch kind {
        case .sqlite: throw TableDesignError.invalid("SQLite can't drop a foreign key from an existing table.")
        case .mysql, .mariadb: return "ALTER TABLE \(qualifiedName(table: table, schema: schema)) DROP FOREIGN KEY \(quoteIdentifier(name))"
        case .postgresql: return "ALTER TABLE \(qualifiedName(table: table, schema: schema)) DROP CONSTRAINT \(quoteIdentifier(name))"
        }
    }

    public func dropTrigger(named name: String, table: String, schema: String?) -> String {
        switch kind {
        case .postgresql: "DROP TRIGGER \(quoteIdentifier(name)) ON \(qualifiedName(table: table, schema: schema))"
        case .mysql, .mariadb: "DROP TRIGGER \(qualifiedName(table: name, schema: schema))"
        case .sqlite: "DROP TRIGGER \(quoteIdentifier(name))"
        }
    }
}
