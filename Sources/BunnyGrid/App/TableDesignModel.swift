import BunnyGridCore
import Foundation
import Observation

/// Design Table / New Table: edits a table's fields and saves them as CREATE or ALTER TABLE.
@MainActor
@Observable
final class TableDesignModel: Identifiable {
    enum Section: String, CaseIterable {
        case fields = "Fields"
        case indexes = "Indexes"
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
    /// nil until the table exists in the database.
    private(set) var originalName: String?
    var columns: [ColumnDesign] = []
    private(set) var originalColumns: [TableColumn] = []
    private(set) var indexes: [TableIndex] = []
    var indexDesigns: [IndexDesign] = []
    var indexSelection: IndexDesign.ID?
    var selection: ColumnDesign.ID?
    var section: Section = .fields
    private(set) var isLoading = false
    private(set) var isSaving = false
    var saveError: String?

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
            case .mysql, .mariadb: "int"
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
        case .postgresql: schema
        case .mysql, .mariadb: databaseName
        case .sqlite: nil
        }
    }

    func load() async {
        guard let originalName else { return }
        isLoading = true
        defer { isLoading = false }
        originalColumns = (try? await driver.listColumns(table: originalName, schema: driverSchema)) ?? []
        indexes = (try? await driver.listIndexes(table: originalName, schema: driverSchema)) ?? []
        columns = originalColumns.map(ColumnDesign.init)
        indexDesigns = indexes.map(IndexDesign.init)
    }

    /// The statements Save would run, or why the design can't be saved.
    var plan: Result<[String], any Error> {
        Result {
            if isNew {
                return [try dialect.createTable(name: tableName, schema: driverSchema, columns: columns)]
                    + (try dialect.alterIndexes(table: tableName, schema: driverSchema, original: [], design: indexDesigns))
            }
            var statements = try dialect.alterTable(name: originalName ?? tableName, schema: driverSchema, original: originalColumns, design: columns)
            if let originalName, tableName != originalName, !tableName.isEmpty {
                let renamed = kind == .mysql || kind == .mariadb
                    ? "RENAME TABLE \(dialect.qualifiedName(table: originalName, schema: driverSchema)) TO \(dialect.qualifiedName(table: tableName, schema: driverSchema))"
                    : "ALTER TABLE \(dialect.qualifiedName(table: originalName, schema: driverSchema)) RENAME TO \(dialect.quoteIdentifier(tableName))"
                statements.append(renamed)
            }
            let finalName = tableName.isEmpty ? (originalName ?? tableName) : tableName
            statements += try dialect.alterIndexes(table: finalName, schema: driverSchema, original: indexes, design: indexDesigns)
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
        let transactional = kind != .mysql && kind != .mariadb
        do {
            if transactional { _ = try await driver.executeTimed(dialect.beginTransaction) }
            for statement in statements { _ = try await driver.executeTimed(statement) }
            if transactional { _ = try await driver.executeTimed("COMMIT") }
        } catch {
            if transactional { _ = try? await driver.executeStatement("ROLLBACK") }
            saveError = error.localizedDescription
            return false
        }
        originalName = tableName
        await load()
        await context?.loadObjects(schema: schema, force: true)
        return true
    }
}
