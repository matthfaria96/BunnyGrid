import BunnyGridCore
import Foundation
import Observation

/// Design Table / New Table: edits a table's fields and saves them as CREATE or ALTER TABLE.
@MainActor
@Observable
final class TableDesignModel: Identifiable {
    /// Navicat's Table Design tabs.
    enum Section: String, CaseIterable {
        case fields = "Fields"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
        case uniques = "Uniques"
        case triggers = "Triggers"
        case options = "Options"
        case sqlPreview = "SQL Preview"
    }

    let id = UUID()
    let connectionID: UUID?
    let databaseName: String
    let schema: String?
    let location: String
    @ObservationIgnored private weak var context: DatabaseContext?
    private let driver: any DatabaseDriver

    var tableName: String
    /// The saved table being designed (nil for a new table), for the DDL pane.
    var tableObject: DatabaseObject? {
        originalName.map { DatabaseObject(schema: schema, name: $0, kind: .table) }
    }
    /// nil until the table exists in the database.
    private(set) var originalName: String?
    var columns: [ColumnDesign] = []
    private(set) var originalColumns: [TableColumn] = []
    private(set) var indexes: [TableIndex] = []
    var indexDesigns: [IndexDesign] = []
    var indexSelection: IndexDesign.ID?
    var selection: ColumnDesign.ID?
    var section: Section = .fields
    private(set) var foreignKeys: [TableForeignKey] = []
    /// Foreign keys as edited: originals that weren't removed, plus new ones.
    var foreignKeyDesigns: [ForeignKeyDesign] = []
    var foreignKeySelection: ForeignKeyDesign.ID?
    /// Where a foreign key can point: schemas (PostgreSQL) or databases (MySQL), their tables, and those tables' fields.
    private(set) var referenceSchemas: [String] = []
    private(set) var referenceTables: [String: [String]] = [:]
    private(set) var referenceColumns: [String: [String]] = [:]
    /// SQLite: the stored CREATE TABLE, for the table rebuild.
    @ObservationIgnored private var originalSQL: String?
    private(set) var triggers: [TableTrigger] = []
    /// Triggers marked for deletion, and new CREATE TRIGGER statements written in the Definition box.
    var droppedTriggers: Set<String> = []
    var newTriggers: [String] = []
    var triggerSelection: TableTrigger.ID?
    /// Options tab: table comment (PostgreSQL, MySQL) and storage engine (MySQL).
    private(set) var originalComment = ""
    var comment = ""
    private(set) var originalEngine = ""
    var engine = ""
    /// SQLite Options tab: Primary Key ON CONFLICT, AUTOINCREMENT, WITHOUT ROWID (read from the stored CREATE TABLE).
    private(set) var originalSQLiteOptions = SQLiteTableOptions()
    var sqliteOptions = SQLiteTableOptions()
    private(set) var isLoading = false
    private(set) var isSaving = false
    var saveError: String?
    /// Bumped by every successful save, so the DDL pane reloads.
    private(set) var revision = 0

    init(context: DatabaseContext, schema: String?, table: String?) {
        self.context = context
        self.driver = context.driver
        self.connectionID = context.session?.id
        self.databaseName = context.name
        self.schema = schema
        self.location = context.location(schema: schema)
        self.tableName = table ?? ""
        self.originalName = table
        if table == nil {
            let idType = switch context.kind {
            case .sqlite: "INTEGER"
            case .postgresql: "serial"
            case .redis: ""
            case .mysql, .mariadb, .mongodb: "int"
            case .sqlserver: "int IDENTITY(1,1)"
            }
            columns = [ColumnDesign(name: "id", type: idType, nullable: false, isPrimaryKey: true)]
        }
    }

    var isNew: Bool { originalName == nil }
    var kind: DatabaseKind { driver.config.kind }
    var dialect: SQLDialect { driver.dialect }
    var displayName: String { isNew ? (tableName.isEmpty ? "Untitled" : tableName) : (originalName ?? tableName) }

    private var driverSchema: String? {
        switch kind {
        case .postgresql, .sqlserver: schema
        case .mysql, .mariadb, .mongodb: databaseName
        // An attached SQLite database is addressed as `alias.table`; main stays unqualified.
        case .sqlite: databaseName == "main" ? nil : databaseName
        case .redis: nil
        }
    }

    func load() async {
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--design-section"), CommandLine.arguments.indices.contains(flag + 1),
           let section = Section(rawValue: CommandLine.arguments[flag + 1]) {
            self.section = section
        }
        #endif
        await loadReferenceCatalog()
        guard let originalName else { return }
        isLoading = true
        defer { isLoading = false }
        originalColumns = (try? await driver.listColumns(table: originalName, schema: driverSchema)) ?? []
        indexes = (try? await driver.listIndexes(table: originalName, schema: driverSchema)) ?? []
        columns = originalColumns.map(ColumnDesign.init)
        indexDesigns = indexes.map(IndexDesign.init)
        foreignKeys = (try? await driver.listForeignKeys(table: originalName, schema: driverSchema)) ?? []
        foreignKeyDesigns = foreignKeys.map(ForeignKeyDesign.init)
        originalSQL = kind == .sqlite ? try? await driver.storedTableSQL(originalName, schema: driverSchema) : nil
        originalSQLiteOptions = originalSQL.map(SQLiteTableOptions.init(sql:)) ?? SQLiteTableOptions()
        sqliteOptions = originalSQLiteOptions
        #if DEBUG
        // --demo-fk: a pending foreign key change, to see the Foreign Keys tab and SQL Preview with an edit.
        if CommandLine.arguments.contains("--demo-fk"), !foreignKeyDesigns.isEmpty {
            foreignKeyDesigns[0].key.onDelete = "CASCADE"
            foreignKeySelection = foreignKeyDesigns[0].id
        }
        #endif
        triggers = (try? await driver.listTriggers(table: originalName, schema: driverSchema)) ?? []
        droppedTriggers = []
        newTriggers = []
        let stats = try? await driver.tableStatistics(schema: driverSchema, table: originalName)
        originalComment = stats?.comment ?? ""
        comment = originalComment
        originalEngine = stats?.engine ?? ""
        engine = originalEngine
    }

    var foreignKeysChanged: Bool { SQLDialect.foreignKeysChanged(original: foreignKeys, design: foreignKeyDesigns) }

    /// SQLite keys have no name of their own (PRAGMA foreign_key_list doesn't report one).
    var foreignKeysHaveNames: Bool { kind != .sqlite }
    /// The schema (PostgreSQL) or database (MySQL) a new key points into by default.
    var defaultReferenceSchema: String? { driverSchema }

    func addForeignKey() {
        let column = selection.flatMap { id in columns.first { $0.id == id }?.name } ?? columns.first?.name ?? ""
        let base = "fk_\(tableName.isEmpty ? "table" : tableName)"
        var name = base
        var n = 1
        while foreignKeyDesigns.contains(where: { $0.key.name == name }) { n += 1; name = "\(base)_\(n)" }
        let key = TableForeignKey(name: foreignKeysHaveNames ? name : "", columns: column.isEmpty ? [] : [column],
                                  referencedSchema: defaultReferenceSchema, referencedTable: "", referencedColumns: [])
        let design = ForeignKeyDesign(key: key)
        foreignKeyDesigns.append(design)
        foreignKeySelection = design.id
    }

    func deleteForeignKey() {
        guard let id = foreignKeySelection, let index = foreignKeyDesigns.firstIndex(where: { $0.id == id }) else { return }
        foreignKeyDesigns.remove(at: index)
        foreignKeySelection = foreignKeyDesigns.indices.contains(index) ? foreignKeyDesigns[index].id : foreignKeyDesigns.last?.id
    }

    private func referenceKey(_ schema: String?) -> String { schema ?? "" }

    func tables(in schema: String?) -> [String] { referenceTables[referenceKey(schema)] ?? [] }

    func columns(of table: String, in schema: String?) -> [String] {
        // The table being designed points at itself with the fields as edited.
        if table == (originalName ?? tableName), schema == nil || schema == defaultReferenceSchema { return columns.map(\.name) }
        return referenceColumns[referenceKey(schema) + "\u{1F}" + table] ?? []
    }

    /// Schemas and the default schema's tables, for the Foreign Keys menus.
    private func loadReferenceCatalog() async {
        switch kind {
        case .postgresql, .sqlserver:
            referenceSchemas = ((try? await driver.listSchemas()) ?? [])
                .filter { !$0.hasPrefix("pg_") && $0.lowercased() != "information_schema" && $0 != "sys" }
        case .mysql, .mariadb, .mongodb:
            referenceSchemas = ((try? await driver.listDatabases()) ?? [])
                .filter { !["information_schema", "performance_schema", "mysql", "sys"].contains($0) }
        case .sqlite:
            referenceSchemas = []
        case .redis: referenceSchemas = []
        }
        await loadReferenceTables(schema: defaultReferenceSchema)
    }

    func loadReferenceTables(schema: String?) async {
        guard referenceTables[referenceKey(schema)] == nil else { return }
        let objects = (try? await driver.listObjects(schema: schema)) ?? []
        referenceTables[referenceKey(schema)] = objects.filter { $0.kind == .table }.map(\.name)
    }

    func loadReferenceColumns(table: String, schema: String?) async {
        let key = referenceKey(schema) + "\u{1F}" + table
        guard !table.isEmpty, referenceColumns[key] == nil else { return }
        referenceColumns[key] = ((try? await driver.listColumns(table: table, schema: schema)) ?? []).map(\.name)
    }

    /// Template for Add Trigger, in the engine's syntax.
    func addTrigger() {
        let table = dialect.qualifiedName(table: tableName.isEmpty ? (originalName ?? "table_name") : tableName, schema: driverSchema)
        let name = "\(tableName.isEmpty ? "table" : tableName)_trigger\(triggers.count + newTriggers.count + 1)"
        let template: String = switch kind {
        case .sqlite: "CREATE TRIGGER \(name) AFTER UPDATE ON \(table)\nBEGIN\n  -- statements\n  SELECT 1;\nEND"
        case .mysql, .mariadb, .mongodb: "CREATE TRIGGER \(name) BEFORE INSERT ON \(table)\nFOR EACH ROW\nSET NEW.created_at = NOW()"
        case .postgresql: "CREATE TRIGGER \(name) BEFORE UPDATE ON \(table)\nFOR EACH ROW EXECUTE FUNCTION function_name()"
        case .sqlserver: "CREATE TRIGGER \(dialect.qualifiedName(table: name, schema: driverSchema)) ON \(table)\nAFTER UPDATE\nAS\nBEGIN\n  SET NOCOUNT ON;\n  -- statements\nEND"
        case .redis: ""
        }
        newTriggers.append(template)
    }

    /// The statements Save would run, or why the design can't be saved.
    var plan: Result<[String], any Error> {
        Result {
            if isNew {
                return [try dialect.createTable(name: tableName, schema: driverSchema, columns: columns, foreignKeys: foreignKeyDesigns.map(\.key),
                                                sqliteOptions: kind == .sqlite ? sqliteOptions : nil)]
                    + (try dialect.alterIndexes(table: tableName, schema: driverSchema, original: [], design: indexDesigns))
            }
            let currentName = originalName ?? tableName
            let finalName = tableName.isEmpty ? currentName : tableName
            let rename: String? = {
                guard let originalName, tableName != originalName, !tableName.isEmpty else { return nil }
                if kind == .sqlserver {
                    return dialect.renameObject(DatabaseObject(schema: driverSchema, name: originalName, kind: .table), to: tableName)
                }
                return kind == .mysql || kind == .mariadb
                    ? "RENAME TABLE \(dialect.qualifiedName(table: originalName, schema: driverSchema)) TO \(dialect.qualifiedName(table: tableName, schema: driverSchema))"
                    : "ALTER TABLE \(dialect.qualifiedName(table: originalName, schema: driverSchema)) RENAME TO \(dialect.quoteIdentifier(tableName))"
            }()
            var statements: [String]
            if kind == .sqlite, sqliteOptions != originalSQLiteOptions
                || SQLiteTableRebuild.isNeeded(originalColumns: originalColumns, columns: columns, originalIndexes: indexes,
                                               originalForeignKeys: foreignKeys, foreignKeys: foreignKeyDesigns) {
                // SQLite: rebuild under the current name (indexes, kept triggers and keys included), then rename natively.
                var rebuild = SQLiteTableRebuild(
                    table: currentName, originalSQL: originalSQL, originalColumns: originalColumns, columns: columns,
                    originalIndexes: indexes, indexes: indexDesigns, foreignKeys: foreignKeyDesigns.map(\.key),
                    triggers: triggers.filter { !droppedTriggers.contains($0.name) }.map(\.definition),
                    checkForeignKeys: SQLDialect.foreignKeysChanged(original: foreignKeys, design: foreignKeyDesigns),
                    options: sqliteOptions)
                rebuild.schema = driverSchema
                statements = try rebuild.statements()
                if let rename { statements.append(rename) }
            } else {
                // Foreign keys: drop removed or changed ones first (a key can hold a column or index the changes remove),
                // add new or changed ones last (they can use new fields and indexes).
                let keys = kind == .sqlite
                    ? (drops: [String](), adds: [String]())
                    : try dialect.alterForeignKeys(table: currentName, newTable: finalName, schema: driverSchema, original: foreignKeys, design: foreignKeyDesigns)
                statements = keys.drops
                statements += try dialect.alterTable(name: currentName, schema: driverSchema, original: originalColumns, design: columns)
                if let rename { statements.append(rename) }
                statements += try dialect.alterIndexes(table: finalName, schema: driverSchema, original: indexes, design: indexDesigns)
                statements += keys.adds
                for name in droppedTriggers.sorted() { statements.append(dialect.dropTrigger(named: name, table: finalName, schema: driverSchema)) }
            }
            // Triggers.
            statements += newTriggers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // Options.
            if comment != originalComment {
                switch kind {
                case .postgresql: statements.append("COMMENT ON TABLE \(dialect.qualifiedName(table: finalName, schema: driverSchema)) IS \(dialect.quoteLiteral(comment))")
                case .mysql, .mariadb, .mongodb: statements.append("ALTER TABLE \(dialect.qualifiedName(table: finalName, schema: driverSchema)) COMMENT = \(dialect.quoteLiteral(comment))")
                case .sqlite: break
                case .sqlserver:
                    // The description SSMS shows lives in an extended property.
                    let level = "N'SCHEMA', \(dialect.quoteLiteral(driverSchema ?? "dbo")), N'TABLE', \(dialect.quoteLiteral(finalName))"
                    statements.append("""
                        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID(\(dialect.quoteLiteral(dialect.qualifiedName(table: finalName, schema: driverSchema)))) AND minor_id = 0 AND name = N'MS_Description') \
                        EXEC sys.sp_updateextendedproperty N'MS_Description', \(dialect.quoteLiteral(comment)), \(level) \
                        ELSE EXEC sys.sp_addextendedproperty N'MS_Description', \(dialect.quoteLiteral(comment)), \(level)
                        """)
                case .redis: break
                }
            }
            if (kind == .mysql || kind == .mariadb), !engine.isEmpty, engine != originalEngine {
                statements.append("ALTER TABLE \(dialect.qualifiedName(table: finalName, schema: driverSchema)) ENGINE = \(engine)")
            }
            return statements
        }
    }

    var planError: String? {
        if case .failure(let error) = plan { return error.localizedDescription }
        return nil
    }

    var statements: [String] {
        (try? plan.get()) ?? []
    }

    var hasChanges: Bool {
        isNew ? !tableName.isEmpty || columns.count > 1 : !statements.isEmpty
    }

    // MARK: - Editing

    func addField() {
        let field = ColumnDesign(name: uniqueName(), type: dialect.suggestedTypes.first(where: { $0.lowercased().contains("varchar") || $0 == "TEXT" }) ?? "text")
        columns.append(field)
        selection = field.id
    }

    func insertField() {
        let field = ColumnDesign(name: uniqueName(), type: dialect.suggestedTypes.first ?? "text")
        let index = selection.flatMap { id in columns.firstIndex { $0.id == id } } ?? columns.count
        columns.insert(field, at: index)
        selection = field.id
    }

    func deleteField() {
        guard let id = selection, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns.remove(at: index)
        selection = columns.indices.contains(index) ? columns[index].id : columns.last?.id
    }

    func togglePrimaryKey() {
        guard let id = selection, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].isPrimaryKey.toggle()
        if columns[index].isPrimaryKey { columns[index].nullable = false }
    }

    func addIndex() {
        let base = (tableName.isEmpty ? "table" : tableName) + "_idx"
        var name = base
        var n = 1
        while indexDesigns.contains(where: { $0.name == name }) { n += 1; name = "\(base)\(n)" }
        let columnName = selection.flatMap { id in columns.first { $0.id == id }?.name } ?? columns.first?.name
        let index = IndexDesign(name: name, columns: columnName.map { [$0] } ?? [])
        indexDesigns.append(index)
        indexSelection = index.id
    }

    func deleteIndex() {
        guard let id = indexSelection, let index = indexDesigns.firstIndex(where: { $0.id == id }) else { return }
        indexDesigns.remove(at: index)
        indexSelection = indexDesigns.indices.contains(index) ? indexDesigns[index].id : indexDesigns.last?.id
    }

    func isPrimaryIndex(_ index: IndexDesign) -> Bool {
        guard let name = index.originalName else { return false }
        return indexes.first { $0.name == name }?.primary == true
    }

    private func uniqueName() -> String {
        var n = columns.count + 1
        while columns.contains(where: { $0.name == "field\(n)" }) { n += 1 }
        return "field\(n)"
    }

    // MARK: - Saving

    /// Runs the planned statements. PostgreSQL and SQLite roll back on failure; MySQL commits DDL as it goes.
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        let statements: [String]
        do {
            statements = try plan.get()
        } catch {
            saveError = error.localizedDescription
            return false
        }
        guard !statements.isEmpty else { return true }
        isSaving = true
        defer { isSaving = false }
        do {
            try await driver.applyDesign(statements)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        revision += 1
        originalName = tableName
        await load()
        await context?.loadObjects(schema: schema, force: true)
        return true
    }
}
