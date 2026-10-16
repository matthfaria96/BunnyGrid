import BunnyGridCore
import Foundation
import Observation

/// How the grid should paint a cell that has pending changes.
enum GridCellState {
    case normal
    case edited
    case inserted
    /// A cell of a new row the user left alone; the column's DEFAULT will apply.
    case defaultValue
    case deleted
}

/// A table or view opened in the data grid, with its pending edits.
@MainActor
@Observable
final class TableTabModel: Identifiable {
    enum Mode: String, CaseIterable {
        case data = "Data"
        case structure = "Structure"
    }

    enum ViewMode {
        case grid
        case form
    }

    /// One statement this tab ran, for the History panel.
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let sql: String
        let error: String?
    }

    let id = UUID()
    let object: DatabaseObject
    private let baseDriver: any DatabaseDriver
    /// The tab's own connection while "Begin Transaction" is active.
    private var transactionDriver: (any DatabaseDriver)?
    private var driver: any DatabaseDriver { transactionDriver ?? baseDriver }
    var isInTransaction: Bool { transactionDriver != nil }
    private(set) var transactionError: String?
    @ObservationIgnored private weak var context: DatabaseContext?
    let location: String
    let connectionID: UUID?
    let databaseName: String

    var mode: Mode = .data
    var viewMode: ViewMode = .grid
    var showFilterBar = false
    var showCellEditor = false
    var showHistory = false
    var hiddenColumns: Set<String> = []
    /// Data Masking rules by column name; masked values show (and export) masked.
    var masks: [String: MaskRule] = [:]
    var showProfiling = false
    /// The cell the user clicked last, in `displayRows` coordinates.
    var focusedCell: GridCell?
    private(set) var log: [LogEntry] = []
    private(set) var lastRefresh: Date?
    private(set) var lastSQL = ""
    var filterText = ""
    private(set) var appliedFilter = ""
    private(set) var orderBy: OrderBy?
    private(set) var page: TablePage?
    private(set) var offset = 0
    var pageSize = 1000
    private(set) var totalRows: Int?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var columns: [TableColumn] = []
    private(set) var indexes: [TableIndex] = []
    private var hasLoaded = false

    // MARK: Pending edits

    /// New values keyed by page row, then by column index.
    private(set) var edits: [Int: [Int: CellValue]] = [:]
    /// Rows added at the bottom of the grid; only the columns the user set are stored.
    private(set) var insertedRows: [[Int: CellValue]] = []
    private(set) var deletedRows: Set<Int> = []
    /// Bumped on every change so the grid knows to redraw even when values are unchanged.
    private(set) var revision = 0
    private(set) var isSaving = false
    var saveError: String?
    var selectedRows = IndexSet()
    private(set) var scrollRequest: GridScrollRequest?

    init(object: DatabaseObject, context: DatabaseContext) {
        self.object = object
        self.context = context
        self.baseDriver = context.driver
        self.location = context.location(schema: object.schema)
        self.connectionID = context.session?.id
        self.databaseName = context.name
    }

    var kind: DatabaseKind { driver.config.kind }

    /// Column name → type as shown in the grid header ("int4", "numeric(5,2)").
    var columnTypes: [String: String] {
        Dictionary(columns.map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first })
    }

    var pageNumber: Int { offset / max(pageSize, 1) + 1 }

    var focusedValue: CellValue? {
        guard let cell = focusedCell else { return nil }
        let rows = displayRows
        guard rows.indices.contains(cell.row), rows[cell.row].indices.contains(cell.column) else { return nil }
        return rows[cell.row][cell.column]
    }

    /// "Record 5 of 1000 in page 1".
    var recordDescription: String {
        let count = displayRows.count
        guard count > 0 else { return "No records" }
        let current = (focusedCell?.row ?? selectedRows.first ?? 0) + 1
        return "Record \(min(current, count)) of \(count) in page \(pageNumber)"
    }

    func goToPage(_ page: Int) async {
        guard !hasChanges else { return }
        offset = max(0, page - 1) * pageSize
        await reload()
    }

    func setPageSize(_ size: Int) async {
        guard !hasChanges, size > 0 else { return }
        pageSize = size
        offset = 0
        await reload()
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Reload that the footer's stop button can interrupt.
    func requestReload() {
        guard !hasChanges else { return }
        loadTask?.cancel()
        loadTask = Task { await reload() }
    }

    /// Stops waiting for the current load. The server may still finish the query; its result is ignored.
    func stopLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    /// Moves the focus to the next cell containing `text` (case-insensitive), wrapping around.
    @discardableResult
    func findNext(_ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let page else { return false }
        let rows = displayRows
        let columnCount = page.columns.count
        guard columnCount > 0, !rows.isEmpty else { return false }
        let total = rows.count * columnCount
        let start = focusedCell.map { $0.row * columnCount + $0.column + 1 } ?? 0
        for step in 0..<total {
            let index = (start + step) % total
            let row = index / columnCount, column = index % columnCount
            if hiddenColumns.contains(page.columns[column]) { continue }
            if rows[row][column].displayString.localizedCaseInsensitiveContains(needle) {
                focusedCell = GridCell(row: row, column: column)
                selectedRows = [row]
                scrollRequest = GridScrollRequest(row: row)
                return true
            }
        }
        return false
    }

    private func record(_ sql: String, error: String? = nil) {
        log.insert(LogEntry(sql: sql, error: error), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let filter = appliedFilter.isEmpty ? nil : appliedFilter
        lastSQL = driver.dialect.selectPage(
            table: object.name, schema: object.schema, offset: offset, limit: pageSize,
            orderBy: orderBy.map { [$0] } ?? [], filter: filter
        )
        do {
            async let pageResult = driver.fetchPage(
                table: object.name, schema: object.schema, offset: offset, limit: pageSize,
                orderBy: orderBy.map { [$0] } ?? [], filter: filter
            )
            async let count = driver.countRows(table: object.name, schema: object.schema, filter: filter)
            let loaded = try await pageResult
            let total = try? await count
            guard !Task.isCancelled else { return }
            page = loaded
            totalRows = total
            lastRefresh = Date()
            record(lastSQL)
        } catch {
            self.error = error.localizedDescription
            record(lastSQL, error: error.localizedDescription)
        }
        clearPendingChanges()
        if columns.isEmpty {
            columns = (try? await driver.listColumns(table: object.name, schema: object.schema)) ?? []
            indexes = (try? await driver.listIndexes(table: object.name, schema: object.schema)) ?? []
        }
    }

    func applyFilter() async {
        guard !hasChanges else { return }
        appliedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        offset = 0
        await reload()
    }

    /// Cycles ascending → descending → unsorted, like Beekeeper's and Navicat's headers.
    func toggleSort(_ column: String) async {
        guard !hasChanges else { return }
        switch orderBy {
        case .some(let current) where current.column == column && current.direction == .ascending:
            orderBy = OrderBy(column: column, direction: .descending)
        case .some(let current) where current.column == column:
            orderBy = nil
        default:
            orderBy = OrderBy(column: column, direction: .ascending)
        }
        offset = 0
        await reload()
    }

    var canGoBack: Bool { offset > 0 && !hasChanges }
    var canGoForward: Bool { page?.hasMore == true && !hasChanges }

    func nextPage() async {
        offset += pageSize
        await reload()
    }

    func previousPage() async {
        offset = max(0, offset - pageSize)
        await reload()
    }

    var rangeDescription: String {
        guard let page, !page.rows.isEmpty else { return "No rows" }
        let range = "\(offset + 1)–\(offset + page.rows.count)"
        if let totalRows { return "\(range) of \(totalRows.formatted())" }
        return range
    }

    // MARK: - Editing

    var primaryKeyColumns: [String] {
        columns.filter(\.isPrimaryKey).map(\.name)
    }

    /// Why the grid is read-only, or nil when it can be edited.
    var readOnlyReason: String? {
        if object.kind != .table { return "Views are read-only" }
        if driver.config.readOnly { return "Read-only connection" }
        if columns.isEmpty { return nil }
        if primaryKeyColumns.isEmpty { return "Read-only: table has no primary key" }
        guard let page else { return nil }
        if primaryKeyColumns.contains(where: { !page.columns.contains($0) }) { return "Read-only: primary key not in result" }
        return nil
    }

    var isEditable: Bool { page != nil && !columns.isEmpty && readOnlyReason == nil }

    var hasChanges: Bool { changeCount > 0 }

    var changeCount: Int {
        edits.keys.filter { !deletedRows.contains($0) }.count + insertedRows.count + deletedRows.count
    }

    /// Page rows with edits applied, followed by inserted rows, with masks applied.
    var displayRows: [[CellValue]] {
        guard let page else { return [] }
        var rows = page.rows
        for (row, values) in edits {
            for (column, value) in values { rows[row][column] = value }
        }
        rows += insertedRows.map { values in page.columns.indices.map { values[$0] ?? .null } }
        return applyMasks(rows)
    }

    /// Indexes of masked columns, which the grid won't edit inline.
    var maskedColumnIndexes: Set<Int> {
        guard let page else { return [] }
        return Set(page.columns.indices.filter { (masks[page.columns[$0]] ?? .none) != .none })
    }

    /// The loaded page as exports should see it: masks applied, pending edits not.
    var exportRows: [[CellValue]] {
        applyMasks(page?.rows ?? [])
    }

    private func applyMasks(_ rows: [[CellValue]]) -> [[CellValue]] {
        guard let page, masks.values.contains(where: { $0 != .none }) else { return rows }
        let rules = page.columns.map { masks[$0] ?? .none }
        return rows.map { row in row.enumerated().map { index, value in index < rules.count ? rules[index].apply(to: value) : value } }
    }

    // MARK: - Table Profile

    /// The current filter, sort, hidden columns and masks as a named profile.
    func makeProfile(named name: String) -> TableProfile? {
        guard let connectionID else { return nil }
        return TableProfile(
            connectionID: connectionID, database: databaseName, schema: object.schema, table: object.name, name: name,
            filter: appliedFilter, sortColumn: orderBy?.column, sortDescending: orderBy?.direction == .descending,
            hiddenColumns: hiddenColumns.sorted(), masks: masks.filter { $0.value != .none }
        )
    }

    func apply(_ profile: TableProfile) async {
        guard !hasChanges else { return }
        filterText = profile.filter
        appliedFilter = profile.filter
        orderBy = profile.sortColumn.map { OrderBy(column: $0, direction: profile.sortDescending ? .descending : .ascending) }
        hiddenColumns = Set(profile.hiddenColumns)
        masks = profile.masks
        showFilterBar = showFilterBar || !profile.filter.isEmpty
        offset = 0
        await reload()
    }

    func cellState(row: Int, column: Int) -> GridCellState {
        guard let page else { return .normal }
        if row >= page.rows.count {
            let inserted = insertedRows[row - page.rows.count]
            return inserted[column] == nil ? .defaultValue : .inserted
        }
        if deletedRows.contains(row) { return .deleted }
        return edits[row]?[column] != nil ? .edited : .normal
    }

    func setValue(_ value: CellValue, row: Int, column: Int) {
        guard isEditable, let page, !maskedColumnIndexes.contains(column) else { return }
        if row >= page.rows.count {
            insertedRows[row - page.rows.count][column] = value
        } else {
            guard !deletedRows.contains(row) else { return }
            let original = page.rows[row][column]
            if original.isNull == value.isNull && original.displayString == value.displayString {
                edits[row]?[column] = nil
                if edits[row]?.isEmpty == true { edits[row] = nil }
            } else {
                edits[row, default: [:]][column] = value
            }
        }
        revision += 1
    }

    func addRow() {
        guard isEditable, let page else { return }
        insertedRows.append([:])
        let row = page.rows.count + insertedRows.count - 1
        scrollRequest = GridScrollRequest(row: row)
        revision += 1
    }

    func scroll(toRow row: Int) {
        scrollRequest = GridScrollRequest(row: row)
    }

    /// Marks loaded rows for deletion (or restores them if already marked) and drops new rows.
    func toggleDelete(_ rows: IndexSet) {
        guard isEditable, let page else { return }
        for row in rows.reversed() {
            if row >= page.rows.count {
                let index = row - page.rows.count
                if insertedRows.indices.contains(index) { insertedRows.remove(at: index) }
            } else if deletedRows.contains(row) {
                deletedRows.remove(row)
            } else {
                deletedRows.insert(row)
            }
        }
        selectedRows = []
        revision += 1
    }

    func discardChanges() {
        clearPendingChanges()
    }

    private func clearPendingChanges() {
        edits = [:]
        insertedRows = []
        deletedRows = []
        saveError = nil
        revision += 1
    }

    /// The pending edits as row changes, ordered deletes → updates → inserts.
    func pendingChanges() -> [RowChange] {
        guard let page else { return [] }
        let keyIndexes = primaryKeyColumns.compactMap { name in page.columns.firstIndex(of: name).map { (name, $0) } }
        func key(_ row: Int) -> [ColumnValue] {
            keyIndexes.map { ColumnValue($0.0, page.rows[row][$0.1]) }
        }
        func values(_ dict: [Int: CellValue]) -> [ColumnValue] {
            dict.sorted { $0.key < $1.key }.map { ColumnValue(page.columns[$0.key], $0.value) }
        }
        var changes: [RowChange] = deletedRows.sorted().map { .delete(key: key($0)) }
        changes += edits.keys.sorted().filter { !deletedRows.contains($0) }.map { row in
            .update(key: key(row), values: values(edits[row] ?? [:]))
        }
        changes += insertedRows.map { .insert(values: values($0)) }
        return changes
    }

    var pendingSQL: String {
        pendingChanges()
            .map { driver.dialect.sql(for: $0, table: object.name, schema: object.schema) + ";" }
            .joined(separator: "\n")
    }

    func applyChanges() async {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let statements = try await driver.applyChanges(pendingChanges(), table: object.name, schema: object.schema, inOpenTransaction: isInTransaction)
            for statement in statements { record(statement + ";") }
            await reload()
        } catch {
            saveError = error.localizedDescription
            record(pendingSQL, error: error.localizedDescription)
        }
    }
}

// MARK: - Manual transaction

extension TableTabModel {
    /// Whether this tab can open its own transaction: editable, and not an in-memory SQLite database
    /// (a second connection would see a different database).
    var canBeginTransaction: Bool {
        guard !isInTransaction, isEditable else { return false }
        return !(kind == .sqlite && driver.config.filePath.isEmpty)
    }

    /// Opens a dedicated connection and runs BEGIN; applied edits stay uncommitted until Commit.
    func beginTransaction(session: Session?) async {
        guard canBeginTransaction, let session else { return }
        let dedicated = session.makeDedicatedDriver(database: databaseName)
        do {
            try await dedicated.connect()
            _ = try await dedicated.executeTimed(dedicated.dialect.beginTransaction)
            transactionDriver = dedicated
            transactionError = nil
            await reload()
        } catch {
            await dedicated.disconnect()
            transactionError = error.localizedDescription
        }
    }

    /// Applies pending grid edits inside the transaction, then commits.
    func commitTransaction() async {
        guard let dedicated = transactionDriver else { return }
        if hasChanges {
            await applyChanges()
            guard saveError == nil else { return }
        }
        do {
            _ = try await dedicated.executeTimed("COMMIT")
            await endTransaction()
        } catch {
            transactionError = error.localizedDescription
        }
    }

    func rollbackTransaction() async {
        guard let dedicated = transactionDriver else { return }
        _ = try? await dedicated.executeStatement("ROLLBACK")
        discardChanges()
        await endTransaction()
    }

    private func endTransaction() async {
        let dedicated = transactionDriver
        transactionDriver = nil
        transactionError = nil
        await dedicated?.disconnect()
        await reload()
    }

    /// Closing the tab: roll back and drop the connection without waiting.
    func abandonTransaction() {
        guard let dedicated = transactionDriver else { return }
        transactionDriver = nil
        Task {
            _ = try? await dedicated.executeStatement("ROLLBACK")
            await dedicated.disconnect()
        }
    }
}

/// A cell position in grid coordinates (row index, column index into the result columns).
struct GridCell: Hashable {
    var row: Int
    var column: Int
}

/// Asks the grid to scroll to a row once; a new request has a new identity.
struct GridScrollRequest: Equatable {
    let row: Int
    let id = UUID()
}
