import Foundation

/// One object that differs between source and target (Navicat Structure Synchronization's comparison list).
public struct SchemaDifference: Identifiable, Hashable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        case create, alter, drop

        public var title: String {
            switch self {
            case .create: "Objects to Create"
            case .alter: "Objects to Modify"
            case .drop: "Objects to Drop"
            }
        }
    }

    public enum ObjectKind: String, Sendable {
        case table, view
    }

    public var kind: ObjectKind
    public var action: Action
    public var name: String
    /// What changes, one line each ("Add column email varchar(255)").
    public var details: [String]
    var tableDiff: TableDiff?

    public var id: String { "\(kind.rawValue):\(name)" }
}

/// How a target table differs from what the source says it should be.
struct TableDiff: Hashable, Sendable {
    var desired: TableDefinition
    var current: TableSchema
    var addedColumns: [ColumnDesign] = []
    var droppedColumns: [String] = []
    /// Desired column and the target's current one.
    var changedColumns: [ColumnChange] = []
    var primaryKeyChanged = false
    var indexesToCreate: [IndexDesign] = []
    var indexesToDrop: [TableIndex] = []
    var keysToAdd: [TableForeignKey] = []
    var keysToDrop: [TableForeignKey] = []

    struct ColumnChange: Hashable, Sendable {
        var desired: ColumnDesign
        var current: TableColumn
        var type = false
        var nullability = false
        var defaultValue = false
        var autoIncrement = false
    }

    var isEmpty: Bool {
        addedColumns.isEmpty && droppedColumns.isEmpty && changedColumns.isEmpty && !primaryKeyChanged
            && indexesToCreate.isEmpty && indexesToDrop.isEmpty && keysToAdd.isEmpty && keysToDrop.isEmpty
    }
}

/// Source and target structures compared, and the script that makes the target like the source.
public struct StructureComparison: Sendable {
    public var source: SchemaSnapshot
    public var target: SchemaSnapshot
    public var differences: [SchemaDifference]
    /// Things the comparison left out (views between different engines).
    public var notes: [String]

    public var isEmpty: Bool { differences.isEmpty }

    /// The deploy script for the chosen differences (all of them when nil), in an order that runs:
    /// view drops, table drops, creates (parents first), alters, foreign keys, then views.
    public func deployScript(for selection: Set<String>? = nil) throws -> [String] {
        let chosen = differences.filter { selection?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { return [] }
        let kind = target.kind
        let schema = target.schema
        let d = SQLDialect(kind: kind)
        let isMySQL = kind == .mysql || kind == .mariadb
        var head: [String] = []
        var drops: [String] = []
        var creates: [String] = []
        var alters: [String] = []
        var keys: [String] = []
        var views: [String] = []

        if kind == .sqlite { head.append(SQLiteTableRebuild.disableForeignKeys) }
        if isMySQL { head.append("SET FOREIGN_KEY_CHECKS = 0") }

        for item in chosen where item.kind == .view && item.action != .create {
            drops.append("DROP VIEW IF EXISTS \(d.qualifiedName(table: item.name, schema: schema))")
        }
        for item in chosen where item.kind == .table && item.action == .drop {
            drops.append(d.dropTableIfExists(item.name, schema: schema))
        }
        let sourceNames = Set(source.tables.map(\.name))
        let createdTables = DataTransfer.creationOrder(source.tables.filter { table in
            chosen.contains { $0.kind == .table && $0.action == .create && $0.name == table.name }
        })
        for table in createdTables {
            let definition = mapped(table, sourceNames: sourceNames)
            creates.append(try d.createTable(definition, schema: schema, includeForeignKeys: kind == .sqlite))
            for index in definition.indexes { creates.append(try d.createIndex(index, table: table.name, schema: schema)) }
            if kind != .sqlite {
                for key in definition.foreignKeys { keys.append(try d.addForeignKey(key, table: table.name, schema: schema)) }
            }
        }
        for item in chosen where item.kind == .table && item.action == .alter {
            guard let diff = item.tableDiff else { continue }
            let statements = try alterStatements(diff)
            alters += statements.alters
            keys += statements.keys
            drops.insert(contentsOf: statements.keyDrops, at: 0)
        }
        for item in chosen where item.kind == .view && item.action != .drop {
            guard let view = source.view(item.name) else { continue }
            views.append(viewDDL(view))
        }
        var tail: [String] = []
        if isMySQL { tail.append("SET FOREIGN_KEY_CHECKS = 1") }
        return head + drops + creates + alters + keys + views + tail
    }

    /// The script as text, statements ending in `;`.
    public func deployScriptText(for selection: Set<String>? = nil) throws -> String {
        let statements = try deployScript(for: selection)
        guard !statements.isEmpty else { return "-- The target already matches the source.\n" }
        return statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n") + "\n"
    }

    func mapped(_ table: TableSchema, sourceNames: Set<String>) -> TableDefinition {
        SchemaMapper.definition(of: table, from: source.kind, to: target.kind, targetSchema: target.schema,
                                primaryKeyOf: { source.table($0)?.primaryKey }, include: { sourceNames.contains($0) })
    }

    // MARK: - ALTER

    private func alterStatements(_ diff: TableDiff) throws -> (keyDrops: [String], alters: [String], keys: [String]) {
        let d = SQLDialect(kind: target.kind)
        let schema = target.schema
        let name = diff.current.name
        let table = d.qualifiedName(table: name, schema: schema)
        var keyDrops: [String] = []
        var alters: [String] = []
        var keys: [String] = []

        switch target.kind {
        case .redis:
            throw DatabaseError.unsupported("Structure synchronization")
        case .sqlite:
            let addable = diff.addedColumns.allSatisfy { !$0.isPrimaryKey && ($0.nullable || !$0.defaultValue.trimmingCharacters(in: .whitespaces).isEmpty) }
            let needsRebuild = !diff.droppedColumns.isEmpty || !diff.changedColumns.isEmpty || diff.primaryKeyChanged || !addable
                || !diff.keysToAdd.isEmpty || !diff.keysToDrop.isEmpty || diff.indexesToDrop.contains { $0.name.hasPrefix("sqlite_autoindex_") }
            if needsRebuild {
                let currentNames = Dictionary(diff.current.columns.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
                let columns = diff.desired.columns.map { column -> ColumnDesign in
                    var column = column
                    column.originalName = currentNames[column.name.lowercased()]
                    return column
                }
                let rebuild = SQLiteTableRebuild(table: name, originalSQL: nil, originalColumns: diff.current.columns, columns: columns,
                                                 originalIndexes: [], indexes: diff.desired.indexes, foreignKeys: diff.desired.foreignKeys,
                                                 triggers: diff.current.triggers, checkForeignKeys: !diff.desired.foreignKeys.isEmpty)
                alters += try rebuild.statements().filter { $0 != SQLiteTableRebuild.disableForeignKeys }
                return ([], alters, [])
            }
            for index in diff.indexesToDrop { alters.append(d.dropIndex(named: index.name, table: name, schema: schema)) }
            for column in diff.addedColumns { alters.append("ALTER TABLE \(table) ADD COLUMN \(d.columnDefinition(column))") }
            for index in diff.indexesToCreate { alters.append(try d.createIndex(index, table: name, schema: schema)) }

        case .postgresql:
            for key in diff.keysToDrop where !key.name.isEmpty { keyDrops.append(try d.dropForeignKey(named: key.name, table: name, schema: schema)) }
            for index in diff.indexesToDrop {
                // A UNIQUE constraint's index can only go with its constraint.
                alters.append("ALTER TABLE \(table) DROP CONSTRAINT IF EXISTS \(d.quoteIdentifier(index.name))")
                alters.append("DROP INDEX IF EXISTS \(d.qualifiedName(table: index.name, schema: schema))")
            }
            if diff.primaryKeyChanged, let pkName = diff.current.primaryKeyName {
                alters.append("ALTER TABLE \(table) DROP CONSTRAINT \(d.quoteIdentifier(pkName))")
            }
            for column in diff.droppedColumns { alters.append("ALTER TABLE \(table) DROP COLUMN \(d.quoteIdentifier(column))") }
            for column in diff.addedColumns { alters.append("ALTER TABLE \(table) ADD COLUMN \(d.columnDefinition(column))") }
            for change in diff.changedColumns {
                let column = d.quoteIdentifier(change.desired.name)
                let auto = diff.desired.autoIncrement.contains(change.desired.name)
                if change.type {
                    let type = auto ? SchemaMapper.serialBaseType(change.desired.type) : change.desired.type
                    alters.append("ALTER TABLE \(table) ALTER COLUMN \(column) TYPE \(type) USING \(column)::\(type)")
                }
                if change.nullability {
                    alters.append("ALTER TABLE \(table) ALTER COLUMN \(column) \(change.desired.nullable ? "DROP" : "SET") NOT NULL")
                }
                if change.autoIncrement && auto {
                    let sequence = d.qualifiedName(table: "\(name)_\(change.desired.name)_seq", schema: schema)
                    alters.append("CREATE SEQUENCE IF NOT EXISTS \(sequence) OWNED BY \(table).\(column)")
                    alters.append("ALTER TABLE \(table) ALTER COLUMN \(column) SET DEFAULT nextval(\(d.quoteLiteral(sequence)))")
                    alters.append("SELECT setval(\(d.quoteLiteral(sequence)), COALESCE(MAX(\(column)), 0) + 1, false) FROM \(table)")
                } else if change.defaultValue || change.autoIncrement {
                    let value = change.desired.defaultValue.trimmingCharacters(in: .whitespaces)
                    alters.append(value.isEmpty
                        ? "ALTER TABLE \(table) ALTER COLUMN \(column) DROP DEFAULT"
                        : "ALTER TABLE \(table) ALTER COLUMN \(column) SET DEFAULT \(value)")
                }
            }
            if diff.primaryKeyChanged, !diff.desired.primaryKey.isEmpty {
                alters.append("ALTER TABLE \(table) ADD PRIMARY KEY (\(diff.desired.primaryKey.map(d.quoteIdentifier).joined(separator: ", ")))")
            }
            for index in diff.indexesToCreate { alters.append(try d.createIndex(index, table: name, schema: schema)) }
            for key in diff.keysToAdd { keys.append(try d.addForeignKey(key, table: name, schema: schema)) }

        case .mysql, .mariadb:
            for key in diff.keysToDrop where !key.name.isEmpty { keyDrops.append(try d.dropForeignKey(named: key.name, table: name, schema: schema)) }
            for index in diff.indexesToDrop { alters.append(d.dropIndex(named: index.name, table: name, schema: schema)) }
            func definition(_ column: ColumnDesign) -> String {
                d.columnDefinition(column) + (diff.desired.autoIncrement.contains(column.name) ? " AUTO_INCREMENT" : "")
            }
            if diff.primaryKeyChanged {
                // An AUTO_INCREMENT column must stay a key, so it loses the attribute while the key changes.
                for change in diff.changedColumns where diff.current.autoIncrement.contains(change.current.name) {
                    var plain = change.desired
                    plain.defaultValue = ""
                    alters.append("ALTER TABLE \(table) MODIFY COLUMN \(d.columnDefinition(plain))")
                }
                if !diff.current.primaryKey.isEmpty { alters.append("ALTER TABLE \(table) DROP PRIMARY KEY") }
            }
            for column in diff.droppedColumns { alters.append("ALTER TABLE \(table) DROP COLUMN \(d.quoteIdentifier(column))") }
            let newKey = diff.primaryKeyChanged && !diff.desired.primaryKey.isEmpty
                ? ", ADD PRIMARY KEY (\(diff.desired.primaryKey.map(d.quoteIdentifier).joined(separator: ", ")))" : ""
            var parts = diff.addedColumns.map { "ADD COLUMN \(definition($0))" }
            parts += diff.changedColumns.map { "MODIFY COLUMN \(definition($0.desired))" }
            if !parts.isEmpty || !newKey.isEmpty {
                alters.append("ALTER TABLE \(table) " + (parts.isEmpty ? String(newKey.dropFirst(2)) : parts.joined(separator: ", ") + newKey))
            }
            for index in diff.indexesToCreate { alters.append(try d.createIndex(index, table: name, schema: schema)) }
            for key in diff.keysToAdd { keys.append(try d.addForeignKey(key, table: name, schema: schema)) }
        }
        return (keyDrops, alters, keys)
    }

    // MARK: - Views

    /// The source view's CREATE VIEW, renamed into the target schema.
    func viewDDL(_ view: ViewSchema) -> String {
        let d = SQLDialect(kind: target.kind)
        guard let body = StructureSync.viewBody(view.definition) else { return view.definition }
        let rewritten = StructureSync.replaceQualifier(in: body, from: source.schema, to: target.kind == .postgresql ? target.schema : nil, kind: target.kind)
        return "CREATE VIEW \(d.qualifiedName(table: view.name, schema: target.schema)) AS\n\(rewritten)"
    }
}

/// Navicat's Structure Synchronization: compare two schemas and build the script that makes the target match.
public enum StructureSync {
    /// Compares every table (and, between the same engines, every view) of `source` with `target`.
    public static func compare(source: SchemaSnapshot, target: SchemaSnapshot) -> StructureComparison {
        var comparison = StructureComparison(source: source, target: target, differences: [], notes: [])
        let sourceNames = Set(source.tables.map(\.name))
        for table in source.tables.sorted(by: { $0.name < $1.name }) {
            let desired = comparison.mapped(table, sourceNames: sourceNames)
            guard let current = target.table(table.name) else {
                let details = desired.columns.map { "Column \($0.name) \($0.type)" }
                comparison.differences.append(SchemaDifference(kind: .table, action: .create, name: table.name, details: details))
                continue
            }
            let diff = diffTable(desired: desired, current: current, kind: target.kind)
            if !diff.isEmpty {
                comparison.differences.append(SchemaDifference(kind: .table, action: .alter, name: current.name,
                                                               details: describe(diff), tableDiff: diff))
            }
        }
        for table in target.tables.sorted(by: { $0.name < $1.name }) where source.table(table.name) == nil {
            comparison.differences.append(SchemaDifference(kind: .table, action: .drop, name: table.name,
                                                           details: ["\(table.columns.count) column(s)"]))
        }

        if source.kind.dialectFamily == target.kind.dialectFamily {
            for view in source.views.sorted(by: { $0.name < $1.name }) {
                if let current = target.view(view.name) {
                    if normalizedView(view.definition, schemas: [source.schema, target.schema], kind: source.kind)
                        != normalizedView(current.definition, schemas: [source.schema, target.schema], kind: target.kind) {
                        comparison.differences.append(SchemaDifference(kind: .view, action: .alter, name: view.name, details: ["Definition changed"]))
                    }
                } else {
                    comparison.differences.append(SchemaDifference(kind: .view, action: .create, name: view.name, details: []))
                }
            }
            for view in target.views.sorted(by: { $0.name < $1.name }) where source.view(view.name) == nil {
                comparison.differences.append(SchemaDifference(kind: .view, action: .drop, name: view.name, details: []))
            }
        } else if !source.views.isEmpty || !target.views.isEmpty {
            comparison.notes.append("Views are compared only between the same engine; \(source.kind.displayName) and \(target.kind.displayName) views were left out.")
        }
        return comparison
    }

    static func diffTable(desired: TableDefinition, current: TableSchema, kind: DatabaseKind) -> TableDiff {
        var diff = TableDiff(desired: desired, current: current)
        let lower = { (s: String) in s.lowercased() }
        let currentByName = Dictionary(current.columns.map { (lower($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let desiredNames = Set(desired.columns.map { lower($0.name) })
        let currentKey = Set(current.primaryKey.map(lower))
        for column in desired.columns {
            guard let existing = currentByName[lower(column.name)] else { diff.addedColumns.append(column); continue }
            var change = TableDiff.ColumnChange(desired: column, current: existing)
            change.type = SchemaMapper.canonicalType(column.type, kind: kind) != SchemaMapper.canonicalType(existing.dataType, kind: kind)
            change.nullability = column.nullable != (existing.nullable && !currentKey.contains(lower(existing.name)))
            let wantsAuto = desired.autoIncrement.contains(column.name)
            let hasAuto = current.autoIncrement.contains(existing.name)
            change.autoIncrement = wantsAuto != hasAuto && kind != .sqlite
            if !wantsAuto && !hasAuto {
                change.defaultValue = SchemaMapper.canonicalDefault(column.defaultValue, kind: kind, type: column.type)
                    != SchemaMapper.canonicalDefault(existing.defaultValue ?? "", kind: kind, type: existing.dataType)
            }
            if change.type || change.nullability || change.defaultValue || change.autoIncrement { diff.changedColumns.append(change) }
        }
        diff.droppedColumns = current.columns.filter { !desiredNames.contains(lower($0.name)) }.map(\.name)
        diff.primaryKeyChanged = desired.primaryKey.map(lower) != current.primaryKey.map(lower)

        let primary = Set(current.primaryKey.map(lower))
        func signature(_ columns: [String], _ unique: Bool) -> String { columns.map(lower).joined(separator: ",") + (unique ? "!" : "") }
        let currentIndexes = current.indexes.filter { !($0.unique && Set($0.columns.map(lower)) == primary) }
        let desiredSignatures = Set(desired.indexes.map { signature($0.columns, $0.unique) })
        let currentSignatures = Set(currentIndexes.map { signature($0.columns, $0.unique) })
        diff.indexesToCreate = desired.indexes.filter { !currentSignatures.contains(signature($0.columns, $0.unique)) }
        diff.indexesToDrop = currentIndexes.filter { !desiredSignatures.contains(signature($0.columns, $0.unique)) }

        func keySignature(_ key: TableForeignKey) -> String {
            let action = { (a: String) -> String in let n = SchemaMapper.normalizedAction(a); return n == "RESTRICT" ? "NO ACTION" : n }
            var referenced = key.referencedColumns
            if referenced.allSatisfy(\.isEmpty) { referenced = [] }
            return [key.columns.map(lower).joined(separator: ","), lower(key.referencedTable), referenced.map(lower).joined(separator: ","),
                    action(key.onDelete), action(key.onUpdate)].joined(separator: "|")
        }
        // SQLite keys naming no referenced columns point at the parent's key: compare them with it filled in.
        func resolved(_ key: TableForeignKey) -> TableForeignKey {
            guard key.referencedColumns.allSatisfy(\.isEmpty) else { return key }
            var key = key
            if key.referencedTable.lowercased() == current.name.lowercased() { key.referencedColumns = current.primaryKey }
            return key
        }
        let desiredKeys = Set(desired.foreignKeys.map { keySignature(resolved($0)) })
        let currentKeys = Set(current.foreignKeys.map { keySignature(resolved($0)) })
        diff.keysToAdd = desired.foreignKeys.filter { !currentKeys.contains(keySignature(resolved($0))) }
        diff.keysToDrop = current.foreignKeys.filter { !desiredKeys.contains(keySignature(resolved($0))) }
        return diff
    }

    static func describe(_ diff: TableDiff) -> [String] {
        var lines: [String] = []
        lines += diff.addedColumns.map { "Add column \($0.name) \($0.type)" }
        lines += diff.droppedColumns.map { "Drop column \($0)" }
        for change in diff.changedColumns {
            var parts: [String] = []
            if change.type { parts.append("type \(change.current.dataType) → \(change.desired.type)") }
            if change.nullability { parts.append(change.desired.nullable ? "allow NULL" : "NOT NULL") }
            if change.defaultValue {
                parts.append("default \(change.current.defaultValue ?? "none") → \(change.desired.defaultValue.isEmpty ? "none" : change.desired.defaultValue)")
            }
            if change.autoIncrement { parts.append(diff.desired.autoIncrement.contains(change.desired.name) ? "auto increment" : "no auto increment") }
            lines.append("Change column \(change.desired.name): " + parts.joined(separator: ", "))
        }
        if diff.primaryKeyChanged {
            lines.append("Primary key (\(diff.current.primaryKey.joined(separator: ", "))) → (\(diff.desired.primaryKey.joined(separator: ", ")))")
        }
        lines += diff.indexesToDrop.map { "Drop index \($0.name)" }
        lines += diff.indexesToCreate.map { "Create \($0.unique ? "unique " : "")index \($0.name) (\($0.columns.joined(separator: ", ")))" }
        lines += diff.keysToDrop.map { "Drop foreign key \($0.name.isEmpty ? $0.columns.joined(separator: ", ") : $0.name)" }
        lines += diff.keysToAdd.map { "Add foreign key (\($0.columns.joined(separator: ", "))) → \($0.referencedTable)" }
        return lines
    }

    // MARK: - Running

    /// Runs the deploy script on the target: in one transaction on PostgreSQL and SQLite (MySQL commits DDL as it goes).
    public static func deploy(_ statements: [String], on driver: any DatabaseDriver) async throws {
        try await driver.applyDesign(statements)
    }

    // MARK: - View text

    /// The SELECT after `CREATE … VIEW name AS`.
    static func viewBody(_ ddl: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\bVIEW\s+.+?\s+AS\s+"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let text = ddl as NSString
        guard let match = regex.firstMatch(in: ddl, range: NSRange(location: 0, length: text.length)) else { return nil }
        var body = text.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return body
    }

    /// Replaces `schema.` qualifiers (quoted or not) in a view body; nil `to` removes them.
    static func replaceQualifier(in body: String, from schema: String?, to target: String?, kind: DatabaseKind) -> String {
        guard let schema, !schema.isEmpty, schema != target else { return body }
        let d = SQLDialect(kind: kind)
        let replacement = target.map { d.quoteIdentifier($0) + "." } ?? ""
        var result = body.replacingOccurrences(of: d.quoteIdentifier(schema) + ".", with: replacement)
        if kind == .postgresql || kind == .sqlite {
            result = result.replacingOccurrences(of: SQLDialect(kind: .mysql).quoteIdentifier(schema) + ".", with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: "(?<![\\w\"`.])" + NSRegularExpression.escapedPattern(for: schema) + "\\.(?=[\\w\"`])") {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return result
    }

    static func normalizedView(_ ddl: String, schemas: [String?], kind: DatabaseKind) -> String {
        var body = viewBody(ddl) ?? ddl
        for schema in schemas { body = replaceQualifier(in: body, from: schema, to: nil, kind: kind) }
        return body.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

extension SchemaMapper {
    /// The integer type behind a serial type, for ALTER COLUMN … TYPE.
    static func serialBaseType(_ type: String) -> String {
        switch type.lowercased() {
        case "bigserial": "bigint"
        case "smallserial": "smallint"
        case "serial": "integer"
        default: type
        }
    }
}
