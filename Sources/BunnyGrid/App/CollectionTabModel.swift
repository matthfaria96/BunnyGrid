import BunnyGridCore
import Foundation
import Observation

/// A MongoDB collection (or view, or GridFS bucket) in Navicat's collection viewer: filter / sort / projection bar,
/// paging, Grid / Tree / JSON views, cell edits kept pending until Apply, and a JSON editor for whole documents.
@MainActor
@Observable
final class CollectionTabModel: DocumentTab {
    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grid View"
        case tree = "Tree View"
        case json = "JSON View"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .grid: "tablecells"
            case .tree: "list.bullet.indent"
            case .json: "curlybraces"
            }
        }
    }

    /// The JSON editor sheet: a new, duplicated or existing document.
    struct DocumentEditor: Identifiable {
        let id = UUID()
        var text: String
        /// The `_id` of the document being replaced; nil inserts.
        var originalID: BSON?
        var error: String?
    }

    nonisolated let id = UUID()
    let object: DatabaseObject
    let collection: String
    let databaseName: String
    @ObservationIgnored weak var context: DatabaseContext?
    let connectionID: UUID?

    var viewMode: ViewMode = .grid
    var filterText = ""
    var sortText = ""
    var projectionText = ""
    var showQueryBar = true
    var pageSize = AppOptions.shared.values.recordsPerPage
    private(set) var page = 0
    private(set) var documents: [BSONDocument] = []
    private(set) var flattened = DocumentFlattener.flatten([])
    private(set) var totalCount: Int?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var error: String?
    private(set) var lastStatement = ""
    var selectedRows = IndexSet()
    var editor: DocumentEditor?
    var confirmingDelete = false
    /// Pending cell edits: row → field → new value; pending deletions by row.
    private(set) var edits: [Int: [String: BSON]] = [:]
    private(set) var deletions = IndexSet()
    private(set) var revision = 0
    var stats: BSONDocument?
    var showingImport = false
    var showingExport = false

    init(context: DatabaseContext, object: DatabaseObject) {
        self.context = context
        self.object = object
        collection = DocumentCatalog.collectionName(object)
        databaseName = context.name
        connectionID = context.session?.id
    }

    var isView: Bool { object.kind == .view }
    var isGridFS: Bool { if case .gridFSBucket = DocumentCatalog.classify(object) { true } else { false } }
    var isReadOnly: Bool { isView || context?.session?.config.readOnly == true }
    private var driver: MongoDriver? { context?.mongoDriver }

    // MARK: DocumentTab

    /// "customers@shop (My Mongo)", like every other tab.
    var title: String { "\(isGridFS ? object.name : collection)@\(databaseName) (\(context?.session?.config.displayName ?? "MongoDB"))" }
    var kindName: String { isView ? "View" : "Collection" }
    nonisolated var systemImage: String { "table" }
    var hasUnsavedChanges: Bool { hasChanges }
    var warning: String? { error }
    var recordText: String {
        guard hasLoaded else { return "" }
        let start = page * pageSize
        let total = totalCount.map { " of \($0.countText)" } ?? ""
        return documents.isEmpty ? "No documents" : "Documents \((start + 1).countText)–\((start + documents.count).countText)\(total)"
    }
    var attachmentText: String {
        "MongoDB collection \(databaseName).\(collection). Fields:\n" +
            flattened.columns.map { "  \($0): \(flattened.columnTypes[$0] ?? "Mixed")" }.joined(separator: "\n")
    }
    var canSave: Bool { hasChanges }
    func save() { Task { await applyChanges() } }
    func cancel() {}

    // MARK: Loading

    var pageCount: Int {
        guard let totalCount, pageSize > 0 else { return 1 }
        return max(1, (totalCount + pageSize - 1) / pageSize)
    }

    func loadIfNeeded() async {
        if !hasLoaded { await reload() }
    }

    private func query() throws -> DocumentQuery {
        func parse(_ text: String, _ what: String) throws -> BSONDocument {
            do {
                return try MongoShellParser.parseDocument(text)
            } catch {
                throw DatabaseError.queryFailed("\(what): \(error.localizedDescription)")
            }
        }
        return DocumentQuery(filter: try parse(filterText, "Filter"), sort: try parse(sortText, "Sort"),
                             projection: try parse(projectionText, "Projection"), skip: page * pageSize, limit: pageSize)
    }

    /// The shell command equivalent to the current view, for the status bar and history.
    private func statement(for query: DocumentQuery) -> String {
        var text = "db.getCollection(\(BSONFormat.quote(collection))).find(\(BSONFormat.shell(query.filter, layout: .compact))"
        if !query.projection.isEmpty { text += ", \(BSONFormat.shell(query.projection, layout: .compact))" }
        text += ")"
        if !query.sort.isEmpty { text += ".sort(\(BSONFormat.shell(query.sort, layout: .compact)))" }
        if query.skip > 0 { text += ".skip(\(query.skip))" }
        if let limit = query.limit { text += ".limit(\(limit))" }
        return text
    }

    func reload() async {
        guard let driver else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let query = try query()
            lastStatement = statement(for: query)
            documents = try await driver.find(query, database: databaseName, collection: collection)
            flattened = DocumentFlattener.flatten(documents)
            edits = [:]
            deletions = []
            selectedRows = []
            revision += 1
            error = nil
            hasLoaded = true
            totalCount = try? await driver.count(filter: query.filter, database: databaseName, collection: collection)
            if stats == nil, !isView { stats = try? await driver.collectionStats(database: databaseName, collection: collection) }
        } catch {
            self.error = ConnectionErrorText.describe(error)
            hasLoaded = true
        }
    }

    func applyFilter() {
        page = 0
        Task { await reload() }
    }

    func resetFilter() {
        filterText = ""
        sortText = ""
        projectionText = ""
        applyFilter()
    }

    func goToPage(_ newPage: Int) {
        let clamped = min(max(newPage, 0), pageCount - 1)
        guard clamped != page else { return }
        page = clamped
        Task { await reload() }
    }

    /// Clicking a grid header sorts by that field (ascending, descending, off), written into the sort box.
    func toggleSort(_ field: String) {
        let current = (try? MongoShellParser.parseDocument(sortText)) ?? BSONDocument()
        let direction = current[field]?.intValue ?? 0
        sortText = switch direction {
        case 1: "{ \(field): -1 }"
        case -1: ""
        default: "{ \(field): 1 }"
        }
        applyFilter()
    }

    var gridSort: OrderBy? {
        guard let sort = try? MongoShellParser.parseDocument(sortText), let first = sort.elements.first else { return nil }
        return OrderBy(column: first.key, direction: first.value.intValue == -1 ? .descending : .ascending)
    }

    // MARK: Grid edits

    var hasChanges: Bool { !edits.isEmpty || !deletions.isEmpty }

    func cellState(row: Int, column: Int) -> GridCellState {
        if deletions.contains(row) { return .deleted }
        guard flattened.columns.indices.contains(column) else { return .normal }
        return edits[row]?[flattened.columns[column]] != nil ? .edited : .normal
    }

    /// The grid shows pending edits in place of the loaded values.
    var displayRows: [[CellValue]] {
        guard !edits.isEmpty else { return flattened.rows }
        var rows = flattened.rows
        for (row, fields) in edits where rows.indices.contains(row) {
            for (field, value) in fields {
                if let column = flattened.columns.firstIndex(of: field) { rows[row][column] = DocumentFlattener.cell(value) }
            }
        }
        return rows
    }

    func setValue(_ value: CellValue, row: Int, column: Int) {
        guard !isReadOnly, documents.indices.contains(row), flattened.columns.indices.contains(column) else { return }
        let field = flattened.columns[column]
        guard field != "_id" else {
            error = "The _id field can't be changed. Duplicate the document instead."
            return
        }
        let original = documents[row][field]
        let new = DocumentFlattener.value(from: value, original: original)
        if new == original {
            edits[row]?[field] = nil
            if edits[row]?.isEmpty == true { edits[row] = nil }
        } else {
            edits[row, default: [:]][field] = new
        }
        revision += 1
    }

    func toggleDelete(_ rows: IndexSet) {
        guard !isReadOnly else { return }
        for row in rows {
            if deletions.contains(row) { deletions.remove(row) } else { deletions.insert(row) }
        }
        revision += 1
    }

    func discardChanges() {
        edits = [:]
        deletions = []
        revision += 1
    }

    /// Sends pending edits as `updateOne({_id}, {$set})` and deletions as `deleteOne({_id})`.
    func applyChanges() async {
        guard let driver, hasChanges else { return }
        do {
            for (row, fields) in edits.sorted(by: { $0.key < $1.key }) where !deletions.contains(row) {
                guard let id = documents[row]["_id"] else { continue }
                var set = BSONDocument()
                for field in flattened.columns where fields[field] != nil { set[field] = fields[field] }
                let result = try await driver.update(filter: ["_id": id], update: .document(["$set": .document(set)]), many: false, upsert: false,
                                                     database: databaseName, collection: collection)
                if result.matched != 1 { throw DatabaseError.queryFailed("The document \(BSONFormat.scalarShell(id)) no longer exists. Reload and try again.") }
            }
            for row in deletions {
                guard let id = documents[row]["_id"] else { continue }
                _ = try await driver.delete(filter: ["_id": id], many: false, database: databaseName, collection: collection)
            }
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }

    // MARK: Documents

    func addDocument() {
        editor = DocumentEditor(text: "{\n  \n}", originalID: nil)
    }

    func editSelected() {
        guard let row = selectedRows.first, documents.indices.contains(row) else { return }
        editor = DocumentEditor(text: BSONFormat.shell(documents[row]), originalID: documents[row]["_id"])
    }

    func duplicateSelected() {
        guard let row = selectedRows.first, documents.indices.contains(row) else { return }
        var copy = documents[row]
        copy["_id"] = nil
        editor = DocumentEditor(text: BSONFormat.shell(copy), originalID: nil)
    }

    /// Saves the editor: replaces the document (by its `_id`) or inserts a new one.
    func saveEditor() async -> Bool {
        guard let driver, var editor else { return false }
        do {
            var document = try MongoShellParser.parseDocument(editor.text)
            if let id = editor.originalID {
                if document["_id"] == nil { document.elements.insert(BSONElement("_id", id), at: 0) }
                if document["_id"] != id {
                    // A changed _id is a new document; the old one goes.
                    try await driver.insert([document], database: databaseName, collection: collection)
                    _ = try await driver.delete(filter: ["_id": id], many: false, database: databaseName, collection: collection)
                } else {
                    var replacement = document
                    replacement["_id"] = nil
                    let result = try await driver.update(filter: ["_id": id], update: .document(replacement), many: false, upsert: false,
                                                         database: databaseName, collection: collection)
                    if result.matched != 1 { throw DatabaseError.queryFailed("The document no longer exists.") }
                }
            } else {
                try await driver.insert([document], database: databaseName, collection: collection)
            }
            self.editor = nil
            await reload()
            return true
        } catch {
            editor.error = ConnectionErrorText.describe(error)
            self.editor = editor
            return false
        }
    }

    func deleteSelected() async {
        guard let driver else { return }
        do {
            for row in selectedRows where documents.indices.contains(row) {
                guard let id = documents[row]["_id"] else { continue }
                _ = try await driver.delete(filter: ["_id": id], many: false, database: databaseName, collection: collection)
            }
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }

    // MARK: Import / Export

    /// Every document matching the filter (not just the page), for export.
    func allMatching() async throws -> [BSONDocument] {
        guard let driver else { return [] }
        var query = try query()
        query.skip = 0
        query.limit = nil
        return try await driver.find(query, database: databaseName, collection: collection)
    }

    func importDocuments(from url: URL) async -> String {
        guard let driver else { return "Not connected." }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let format: DocumentTransferFormat? = url.pathExtension.lowercased() == "csv" ? .csv : nil
            let documents = try DocumentTransfer.read(text, format: format)
            try await driver.insert(documents, database: databaseName, collection: collection)
            await reload()
            return "Imported \(documents.count.countText) documents."
        } catch {
            return ConnectionErrorText.describe(error)
        }
    }

    /// GridFS: the file's bytes, reassembled from `<bucket>.chunks` in order.
    func gridFSFileData(row: Int) async throws -> (name: String, data: Data) {
        guard let driver, documents.indices.contains(row), let id = documents[row]["_id"] else { throw DatabaseError.notConnected }
        let bucket = String(collection.dropLast(".files".count))
        let chunks = try await driver.find(DocumentQuery(filter: ["files_id": id], sort: ["n": .int32(1)]), database: databaseName, collection: "\(bucket).chunks")
        var data = Data()
        for chunk in chunks { if case .binary(let b)? = chunk["data"] { data.append(b.data) } }
        return (documents[row]["filename"]?.stringValue ?? "file", data)
    }
}
