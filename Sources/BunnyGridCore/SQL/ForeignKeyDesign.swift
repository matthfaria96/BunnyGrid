import Foundation

/// One row of the designer's Foreign Keys tab. `original` is the key as read from the database,
/// nil for a key the user added. SQLite keys have no name, so the whole key is kept rather than its name.
public struct ForeignKeyDesign: Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var original: TableForeignKey?
    public var key: TableForeignKey

    public init(original: TableForeignKey? = nil, key: TableForeignKey) {
        self.original = original
        self.key = key
    }

    public init(_ key: TableForeignKey) {
        self.init(original: key, key: key)
    }

    public var isNew: Bool { original == nil }
    public var isChanged: Bool { original != nil && original != key }
}

extension SQLDialect {
    /// `CONSTRAINT … FOREIGN KEY (…) REFERENCES … (…) ON DELETE … ON UPDATE …`, for CREATE TABLE and ADD.
    /// SQLite references are never schema-qualified, and an empty referenced-field list means the parent's primary key.
    public func foreignKeyClause(_ key: TableForeignKey, schema: String?) throws -> String {
        try validate(key)
        let name = key.name.trimmingCharacters(in: .whitespaces)
        let constraint = name.isEmpty ? "" : "CONSTRAINT \(quoteIdentifier(name)) "
        let columns = key.columns.map(quoteIdentifier).joined(separator: ", ")
        let parent = kind == .sqlite
            ? quoteIdentifier(key.referencedTable)
            : qualifiedName(table: key.referencedTable, schema: key.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? schema)
        let referenced = key.referencedColumns.allSatisfy(\.isEmpty)
            ? ""
            : " (" + key.referencedColumns.map(quoteIdentifier).joined(separator: ", ") + ")"
        var sql = "\(constraint)FOREIGN KEY (\(columns)) REFERENCES \(parent)\(referenced)"
        // SQL Server has no RESTRICT; NO ACTION checks the same thing.
        func action(_ text: String) -> String { kind == .sqlserver && text.uppercased() == "RESTRICT" ? "NO ACTION" : text.uppercased() }
        if action(key.onDelete) != "NO ACTION" { sql += " ON DELETE \(action(key.onDelete))" }
        if action(key.onUpdate) != "NO ACTION" { sql += " ON UPDATE \(action(key.onUpdate))" }
        return sql
    }

    func validate(_ key: TableForeignKey) throws {
        let label = key.name.isEmpty ? "on \(key.columns.joined(separator: ", "))" : "“\(key.name)”"
        guard !key.columns.isEmpty, !key.columns.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw TableDesignError.invalid("Foreign key \(label) needs at least one field.")
        }
        guard !key.referencedTable.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TableDesignError.invalid("Foreign key \(label) needs a referenced table.")
        }
        let implicit = kind == .sqlite && key.referencedColumns.allSatisfy(\.isEmpty)
        guard implicit || key.columns.count == key.referencedColumns.count, !key.referencedColumns.contains(where: \.isEmpty) || implicit else {
            throw TableDesignError.invalid("Foreign key \(label) needs as many referenced fields as fields.")
        }
        for action in [key.onDelete, key.onUpdate] where !TableForeignKey.actions.contains(action.uppercased()) {
            throw TableDesignError.invalid("Foreign key \(label) has an unknown action “\(action)”.")
        }
    }

    /// PostgreSQL and MySQL: DROP for removed or changed keys, ADD for new or changed ones (changing = drop + add).
    /// The drops run on `table` before any column change, the adds on `newTable` after them.
    public func alterForeignKeys(table: String, newTable: String? = nil, schema: String?,
                                 original: [TableForeignKey], design: [ForeignKeyDesign]) throws -> (drops: [String], adds: [String]) {
        var drops: [String] = []
        var adds: [String] = []
        let kept = design.compactMap(\.original)
        for key in original where !kept.contains(key) || design.contains(where: { $0.original == key && $0.isChanged }) {
            guard !key.name.isEmpty else { throw TableDesignError.unsupported("The foreign key on \(key.columns.joined(separator: ", ")) has no name to drop.") }
            drops.append(try dropForeignKey(named: key.name, table: table, schema: schema))
        }
        for row in design where row.isNew || row.isChanged {
            adds.append(try addForeignKey(row.key, table: newTable ?? table, schema: schema))
        }
        return (drops, adds)
    }

    /// Whether the designed keys differ from the table's keys.
    public static func foreignKeysChanged(original: [TableForeignKey], design: [ForeignKeyDesign]) -> Bool {
        design.contains { $0.isNew || $0.isChanged } || original.count != design.count(where: { $0.original != nil })
    }
}

/// SQLite can't change a column's type, NOT NULL or default, the primary key or the foreign keys with ALTER TABLE.
/// The designer then rebuilds the table the way https://sqlite.org/lang_altertable.html#otheralter describes:
/// create the new table, copy the rows, drop the old one, rename, and recreate its indexes and triggers.
public struct SQLiteTableRebuild: Sendable {
    public var table: String
    /// The table's CREATE TABLE as stored in sqlite_master, to keep AUTOINCREMENT and refuse what the designer can't model.
    public var originalSQL: String?
    public var originalColumns: [TableColumn]
    public var columns: [ColumnDesign]
    public var originalIndexes: [TableIndex]
    public var indexes: [IndexDesign]
    public var foreignKeys: [TableForeignKey]
    /// CREATE TRIGGER statements to run again after the rebuild (DROP TABLE drops them).
    public var triggers: [String]
    /// Run `PRAGMA foreign_key_check` before committing, when the keys changed.
    public var checkForeignKeys: Bool
    /// The table options to rebuild with; nil keeps the ones in `originalSQL`.
    public var options: SQLiteTableOptions?
    /// An attached database's alias; nil (or "main") for the main database.
    public var schema: String?

    public init(table: String, originalSQL: String?, originalColumns: [TableColumn], columns: [ColumnDesign],
                originalIndexes: [TableIndex], indexes: [IndexDesign], foreignKeys: [TableForeignKey],
                triggers: [String], checkForeignKeys: Bool, options: SQLiteTableOptions? = nil) {
        self.options = options
        self.table = table
        self.originalSQL = originalSQL
        self.originalColumns = originalColumns
        self.columns = columns
        self.originalIndexes = originalIndexes
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.triggers = triggers
        self.checkForeignKeys = checkForeignKeys
    }

    static let dialect = SQLDialect(kind: .sqlite)
    public static let disableForeignKeys = "PRAGMA foreign_keys = OFF"

    /// True when the change can't be done with SQLite's own ALTER TABLE: a column's type, NOT NULL, default or the
    /// primary key changed, the foreign keys changed, or a dropped column is still used by an index or a key.
    public static func isNeeded(originalColumns: [TableColumn], columns: [ColumnDesign], originalIndexes: [TableIndex],
                                originalForeignKeys: [TableForeignKey], foreignKeys: [ForeignKeyDesign]) -> Bool {
        if SQLDialect.foreignKeysChanged(original: originalForeignKeys, design: foreignKeys) { return true }
        do {
            _ = try dialect.alterTable(name: "t", schema: nil, original: originalColumns, design: columns)
        } catch TableDesignError.unsupported {
            return true
        } catch {
            return false
        }
        let kept = Set(columns.compactMap(\.originalName))
        let dropped = Set(originalColumns.map(\.name)).subtracting(kept)
        guard !dropped.isEmpty else { return false }
        return originalIndexes.contains { !Set($0.columns).isDisjoint(with: dropped) }
            || originalForeignKeys.contains { !Set($0.columns).isDisjoint(with: dropped) }
    }

    /// Constructs CREATE TABLE can hold that the designer would lose; the rebuild refuses them instead.
    static func unsupportedFeatures(in sql: String) -> [String] {
        // Blank out string literals and quoted names so a column called "check" doesn't count.
        let bare = SQLiteTableOptions.removingPrimaryKeyConflict(sql).replacing(/'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]/, with: "''").uppercased()
        let checks: [(String, Regex<Substring>)] = [
            ("CHECK constraints", /\bCHECK\s*\(/),
            ("COLLATE", /\bCOLLATE\b/),
            ("generated columns", /\bGENERATED\b|\bAS\s*\(/),
            ("STRICT", /\)\s*STRICT\b|,\s*STRICT\b/),
            ("ON CONFLICT clauses", /\bON\s+CONFLICT\b/),
            ("DEFERRABLE keys", /\bDEFERRABLE\b/),
        ]
        return checks.compactMap { name, regex in bare.contains(regex) ? name : nil }
    }

    /// The new name of each kept column, by its old name.
    private var renames: [String: String] {
        Dictionary(columns.compactMap { column in column.originalName.map { ($0, column.name) } }, uniquingKeysWith: { first, _ in first })
    }

    var temporaryName: String { "_bunnygrid_new_\(table)" }

    /// PRAGMA foreign_keys = OFF goes first: the caller runs it outside the transaction (SQLite ignores it inside one).
    public func statements() throws -> [String] {
        let d = Self.dialect
        let features = originalSQL.map(Self.unsupportedFeatures) ?? []
        if !features.isEmpty {
            throw TableDesignError.unsupported(
                "“\(table)” uses \(features.joined(separator: ", ")), which the designer can't rebuild. Change it with a query (ALTER TABLE or a new CREATE TABLE).")
        }
        try d.validate(columns)
        let names = Set(columns.map { $0.name.lowercased() })
        let renames = renames
        // Indexes and keys read from the table still name renamed fields by their old names.
        let current = { (name: String) in names.contains(name.lowercased()) ? name : (renames[name] ?? name) }
        let foreignKeys = foreignKeys.map { key in
            var key = key
            key.columns = key.columns.map(current)
            if key.referencedTable == table { key.referencedColumns = key.referencedColumns.map { $0.isEmpty ? $0 : current($0) } }
            return key
        }
        for key in foreignKeys { try d.validate(key) }
        for key in foreignKeys {
            if let missing = key.columns.first(where: { !names.contains($0.lowercased()) }) {
                throw TableDesignError.invalid("Foreign key field “\(missing)” isn't a field of the table.")
            }
        }

        // In an attached database every statement names `alias.table`, except the RENAME target (always unqualified).
        let attached = schema.flatMap { $0.isEmpty || $0 == "main" ? nil : $0 }
        let quotedTable = d.qualifiedName(table: table, schema: attached)
        let temporary = d.qualifiedName(table: temporaryName, schema: attached)

        // Columns and key with the table options (AUTOINCREMENT, ON CONFLICT, WITHOUT ROWID), kept from the stored SQL by default.
        let tableOptions = options ?? originalSQL.map(SQLiteTableOptions.init(sql:)) ?? SQLiteTableOptions()
        try tableOptions.validate(columns)
        let layout = tableOptions.tableParts(columns: columns, dialect: d)
        var parts = layout.columns + (layout.primaryKey.map { [$0] } ?? [])
        // UNIQUE constraints come back as sqlite_autoindex_* indexes; they can't be created by name, so they stay constraints.
        let liveIndexes = indexes.compactMap { index -> IndexDesign? in
            guard !isPrimary(index) else { return nil }
            var index = index
            let mapped = index.columns.map(current)
            // An index on a dropped column goes with it, as in PostgreSQL.
            guard mapped.allSatisfy({ names.contains($0.lowercased()) }) else { return nil }
            index.columns = mapped
            return index
        }
        for index in liveIndexes where index.name.hasPrefix("sqlite_autoindex_") {
            parts.append("  UNIQUE (\(index.columns.map(d.quoteIdentifier).joined(separator: ", ")))")
        }
        for key in foreignKeys {
            parts.append("  " + (try d.foreignKeyClause(key, schema: nil)))
        }

        var statements = [
            Self.disableForeignKeys,
            // Keeps the RENAME below from rewriting other tables' REFERENCES, views and triggers: they name the old table, which is what we want.
            "PRAGMA legacy_alter_table = ON",
            "CREATE TABLE \(temporary) (\n\(parts.joined(separator: ",\n"))\n)\(layout.suffix)",
        ]
        let copied = columns.filter { column in column.originalName.map { name in originalColumns.contains { $0.name == name } } ?? false }
        if !copied.isEmpty {
            let targets = copied.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")
            let sources = copied.map { d.quoteIdentifier($0.originalName ?? $0.name) }.joined(separator: ", ")
            statements.append("INSERT INTO \(temporary) (\(targets)) SELECT \(sources) FROM \(quotedTable)")
        }
        statements += [
            "DROP TABLE \(quotedTable)",
            "ALTER TABLE \(temporary) RENAME TO \(d.quoteIdentifier(table))",
            "PRAGMA legacy_alter_table = OFF",
        ]
        for index in liveIndexes where !index.name.hasPrefix("sqlite_autoindex_") {
            statements.append(try d.createIndex(index, table: table, schema: attached))
        }
        statements += triggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { trigger in
            // An unqualified CREATE TRIGGER lands in main; name the attached database so it stays with its table.
            guard let attached else { return trigger }
            return trigger.replacing(/^(?i)(CREATE\s+(?:TEMP\s+|TEMPORARY\s+)?TRIGGER\s+(?:IF\s+NOT\s+EXISTS\s+)?)/, maxReplacements: 1) { match in
                String(match.output.1) + d.quoteIdentifier(attached) + "."
            }
        }
        if checkForeignKeys {
            let prefix = attached.map { d.quoteIdentifier($0) + "." } ?? ""
            statements.append("PRAGMA \(prefix)foreign_key_check(\(d.quoteIdentifier(table)))")
        }
        return statements
    }

    private func isPrimary(_ index: IndexDesign) -> Bool {
        guard let name = index.originalName else { return false }
        return originalIndexes.contains { $0.name == name && $0.primary }
    }
}

extension DatabaseDriver {
    /// SQLite: the table's CREATE TABLE as stored in sqlite_master (nil on other engines).
    public func storedTableSQL(_ table: String, schema: String? = nil) async throws -> String? {
        guard config.kind == .sqlite else { return nil }
        let master = schema.map { $0.isEmpty || $0 == "main" ? "sqlite_master" : dialect.quoteIdentifier($0) + ".sqlite_master" } ?? "sqlite_master"
        let result = try await executeStatement(
            "SELECT sql FROM \(master) WHERE type = 'table' AND name = \(dialect.quoteLiteral(table))")
        guard let value = result.rows.first?.first, !value.isNull else { return nil }
        return value.displayString
    }

    /// Runs the designer's statements. PostgreSQL and SQLite run them in one transaction and roll back on failure;
    /// MySQL commits DDL as it goes. Leading `PRAGMA foreign_keys` statements run before BEGIN (SQLite ignores them
    /// inside a transaction) and the setting is put back afterwards. A `PRAGMA foreign_key_check` that returns rows
    /// fails the save.
    public func applyDesign(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        let isPragma = { (sql: String, name: String) in
            sql.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "").hasPrefix("PRAGMA" + name)
        }
        let leading = Array(statements.prefix { isPragma($0, "FOREIGN_KEYS") })
        let body = Array(statements.dropFirst(leading.count))
        var restore: [String] = []
        if config.kind == .sqlite, !leading.isEmpty {
            let current = try await executeStatement("PRAGMA foreign_keys").rows.first?.first
            restore.append("PRAGMA foreign_keys = \(current == .integer(1) ? "ON" : "OFF")")
        }
        if body.contains(where: { isPragma($0, "LEGACY_ALTER_TABLE") }) { restore.insert("PRAGMA legacy_alter_table = OFF", at: 0) }
        for statement in leading { _ = try await executeTimed(statement) }
        let transactional = config.kind != .mysql && config.kind != .mariadb
        do {
            if transactional { _ = try await executeTimed(dialect.beginTransaction) }
            for statement in body {
                let result = try await executeTimed(statement)
                if isPragma(statement, "FOREIGN_KEY_CHECK"), !result.rows.isEmpty {
                    let parents = Set(result.rows.compactMap { $0.count > 2 ? $0[2].displayString : nil }).sorted()
                    throw DatabaseError.queryFailed(
                        "\(result.rows.count) \(result.rows.count == 1 ? "row doesn't" : "rows don't") match the foreign key to \(parents.joined(separator: ", ")). Nothing was saved.")
                }
            }
            if transactional { _ = try await executeTimed("COMMIT") }
        } catch {
            if transactional { _ = try? await executeStatement("ROLLBACK") }
            for statement in restore { _ = try? await executeStatement(statement) }
            throw error
        }
        for statement in restore { _ = try? await executeStatement(statement) }
    }
}
