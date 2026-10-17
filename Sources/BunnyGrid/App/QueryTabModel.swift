import AppKit
import BunnyGridCore
import Foundation
import Observation

/// Where AI-generated code goes in the editor (Navicat's insert options).
enum EditorInsertMode: CaseIterable, Identifiable {
    case atCursor, replaceSelection, replaceAll, append

    var id: Self { self }

    var title: String {
        switch self {
        case .atCursor: "Insert at Editor Cursor"
        case .replaceSelection: "Replace Selection in Editor"
        case .replaceAll: "Replace All in Editor"
        case .append: "Append to Editor"
        }
    }

    var shortTitle: String {
        switch self {
        case .atCursor: "Insert at Cursor"
        case .replaceSelection: "Replace Selection"
        case .replaceAll: "Replace All"
        case .append: "Append"
        }
    }

    var systemImage: String {
        switch self {
        case .atCursor: "text.cursor"
        case .replaceSelection: "selection.pin.in.out"
        case .replaceAll: "doc.text"
        case .append: "text.append"
        }
    }
}

/// One statement run from the editor: what Navicat lists in Message and Summary.
struct StatementExecution: Identifiable {
    let id = UUID()
    let statement: String
    let start: Date
    let duration: Duration
    /// The result for statements that succeeded.
    let result: QueryResult?
    let error: String?

    var succeeded: Bool { error == nil }
}

/// What a Run executes: Navicat's Run, Run Selected and Run Current Statement.
enum QueryRunScope {
    /// The selection when there is one, otherwise the whole editor (⌘↩).
    case automatic
    case all
    case selection
    /// The statement under the cursor (⌘⇧↩).
    case currentStatement
}

/// Which part of the result panel is showing.
enum QueryResultPane: Hashable {
    case message
    case summary
    case result(UUID)
}

/// A SQL editor tab with its results.
@MainActor
@Observable
final class QueryTabModel: Identifiable {
    let id = UUID()
    var title: String
    /// Tracked by hand: the macro's setter compares the old and new value first, which for a long
    /// script is a full string comparison on every keystroke.
    @ObservationIgnored private var storedText: String
    var text: String {
        get {
            // Text typed in a large script reaches the binding after a short pause; take it now.
            (textView as? SQLTextView)?.flushText?()
            access(keyPath: \.text)
            return storedText
        }
        set {
            withMutation(keyPath: \.text) { storedText = newValue }
            // Views read these flags instead of the text, so they don't re-render (and re-scan a long
            // script) on every keystroke. Each is only written when it actually changes.
            let blank = !newValue.contains { !$0.isWhitespace }
            if blank != isBlank { isBlank = blank }
            if newValue.isEmpty != isEmpty { isEmpty = newValue.isEmpty }
            if !isEdited { isEdited = true }
            scheduleColumnPrefetch()
        }
    }
    /// The editor holds only whitespace (or nothing).
    private(set) var isBlank = true
    private(set) var isEmpty = true
    /// Edited since it was opened or last saved.
    private var isEdited = false
    var selectedText = ""
    private(set) var results: [QueryResult] = []
    var selectedResultID: UUID?
    private(set) var isRunning = false
    private(set) var error: String?
    /// The statement that failed and the engine's message, for Fix with AI / Explain Error.
    private(set) var failedStatement: String?
    private(set) var failureMessage: String?
    /// Every statement of the last run, in order.
    private(set) var executions: [StatementExecution] = []
    private(set) var runStarted: Date?
    private(set) var runEnded: Date?
    /// Result tabs kept across runs.
    var pinnedResultIDs: Set<UUID> = []
    var resultPane: QueryResultPane = .message
    var showResultPanel = false
    /// Navicat's "Show Result Below Editor" / "Show Result Next to Editor".
    var resultsBesideEditor = UserDefaults.standard.bool(forKey: "queryResultsBeside") {
        didSet { UserDefaults.standard.set(resultsBesideEditor, forKey: "queryResultsBeside") }
    }
    /// Cursor position for the status bar ("Line: 1 Col: 1").
    var cursorLine = 1
    var cursorColumn = 1
    /// The cursor as a UTF-16 offset into `text`, for Run Current Statement.
    @ObservationIgnored var cursorOffset = 0
    /// Plans of the Explain results, by result id.
    private(set) var plans: [UUID: [QueryPlanNode]] = [:]
    @ObservationIgnored private(set) weak var context: DatabaseContext?
    /// The editor's text view, registered by `SQLEditorView`, so AI code can be inserted with undo.
    @ObservationIgnored weak var textView: NSTextView?
    /// The Ask AI answer being shown for this editor.
    var aiRun: AskAIRun?
    /// The Ask AI card (compose state).
    var showingAskAICustom = false
    /// The last custom question, so Back and reopening restore it.
    var lastCustomAction: AIAction?
    /// The database's shared driver (navigator, table tabs).
    @ObservationIgnored private var contextDriver: any DatabaseDriver
    /// The editor's own connection, opened on the first run, so a transaction begun here doesn't take in
    /// edits applied from table tabs (and theirs don't land in this one). Not used for in-memory SQLite,
    /// where a second connection would be a different, empty database.
    @ObservationIgnored private var ownDriver: (any DatabaseDriver)?
    /// The driver running the current statement, for Stop.
    @ObservationIgnored private var activeDriver: (any DatabaseDriver)?
    @ObservationIgnored private var isClosed = false
    private(set) var location: String
    private(set) var connectionID: UUID?
    private(set) var databaseName: String
    /// Set once the query is saved to the navigator's Queries folder.
    private(set) var savedQueryID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init(title: String, text: String, context: DatabaseContext) {
        self.title = title
        self.storedText = text
        self.isBlank = !text.contains { !$0.isWhitespace }
        self.isEmpty = text.isEmpty
        self.context = context
        self.contextDriver = context.driver
        self.location = context.location(schema: context.defaultSchema)
        self.connectionID = context.session?.id
        self.databaseName = context.name
        scheduleColumnPrefetch()
    }

    convenience init(saved: SavedQuery, context: DatabaseContext) {
        self.init(title: saved.name, text: saved.sql, context: context)
        markSaved(id: saved.id, name: saved.name)
    }

    /// Unsaved: a new query with text, or a saved one edited since (an edit that is undone still counts).
    var isDirty: Bool {
        savedQueryID == nil ? !isEmpty : isEdited
    }

    func markSaved(id: UUID, name: String) {
        savedQueryID = id
        isEdited = false
        title = name
    }

    /// Last statement run, for the status bar.
    var lastSQL: String { selectedResult?.statement ?? "" }

    var selectedResult: QueryResult? {
        results.first { $0.id == selectedResultID } ?? results.last
    }

    var hasSelection: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs the selection if there is one, otherwise the whole editor (⌘↩).
    func run() { run(.automatic) }

    func runSelected() { run(.selection) }

    func runAll() { run(.all) }

    /// Runs only the statement under the cursor (⌘⇧↩).
    func runCurrentStatement() { run(.currentStatement) }

    /// The statement Run Current Statement and Explain use: the one around the cursor.
    var currentStatement: SQLSplitter.Statement? {
        SQLSplitter.statement(at: textView?.selectedRange().location ?? cursorOffset, in: text)
    }

    func run(_ scope: QueryRunScope) {
        let script: String
        switch scope {
        case .automatic: script = hasSelection ? selectedText : text
        case .all: script = text
        case .selection: script = hasSelection ? selectedText : ""
        case .currentStatement: script = currentStatement?.sql ?? ""
        }
        execute(SQLSplitter.split(script), history: script)
    }

    /// Rows read per result set: Options › Records › Limit records (the rest via Load More / Fetch All).
    var rowLimit: Int? {
        let options = AppOptions.shared.values
        return options.limitRecords ? max(options.recordsPerPage, 1) : nil
    }

    /// Runs `statements` one by one, so results before a failing statement stay visible.
    /// With `explaining`, results that are plans get a tree in the result panel.
    private func execute(_ statements: [String], history script: String, explaining: Bool = false) {
        guard !statements.isEmpty, !isRunning else { return }
        isRunning = true
        error = nil
        failedStatement = nil
        failureMessage = nil
        executions = []
        runStarted = Date()
        runEnded = nil
        showResultPanel = true
        let limit = rowLimit
        task = Task {
            defer {
                isRunning = false
                activeDriver = nil
            }
            let clock = ContinuousClock()
            let start = clock.now
            // Pinned results stay as tabs when the editor runs again (Navicat's Pin Result).
            results = results.filter { pinnedResultIDs.contains($0.id) }
            resultEditors = resultEditors.filter { pinnedResultIDs.contains($0.key) }
            plans = [:]
            var driver: (any DatabaseDriver)?
            do {
                driver = try await queryDriver()
            } catch {
                self.error = "Could not open the editor's connection: \(error.localizedDescription)"
                failureMessage = error.localizedDescription
            }
            activeDriver = driver
            for (index, statement) in statements.enumerated() {
                guard let driver else { break }
                let began = Date()
                let statementStart = clock.now
                do {
                    try Task.checkCancellation()
                    let result = try await driver.executeTimed(statement, maxRows: limit)
                    results.append(result)
                    if explaining, let plan = QueryPlan.parse(result, kind: driver.config.kind) { plans[result.id] = plan }
                    executions.append(StatementExecution(statement: statement, start: began, duration: result.duration, result: result, error: nil))
                } catch {
                    // Stop makes the server fail the statement ("canceling statement due to user request"…).
                    if error is CancellationError || Task.isCancelled {
                        self.error = "Cancelled."
                        executions.append(StatementExecution(statement: statement, start: began, duration: clock.now - statementStart, result: nil,
                                                             error: error is CancellationError ? "Cancelled" : "Cancelled: \(error.localizedDescription)"))
                        break
                    }
                    let prefix = statements.count > 1 ? "Statement \(index + 1) of \(statements.count) failed: " : ""
                    self.error = prefix + error.localizedDescription
                    failedStatement = statement
                    failureMessage = error.localizedDescription
                    executions.append(StatementExecution(statement: statement, start: began, duration: clock.now - statementStart, result: nil, error: error.localizedDescription))
                    break
                }
            }
            runEnded = Date()
            selectedResultID = results.last(where: \.isResultSet)?.id ?? results.last?.id
            // Like Navicat: a result set opens its Result tab, an error opens Summary, anything else Message.
            if self.error != nil {
                resultPane = .summary
            } else if let shown = results.last(where: \.isResultSet) {
                resultPane = .result(shown.id)
            } else {
                resultPane = .message
            }
            record(script, duration: clock.now - start, rowCount: results.last(where: \.isResultSet)?.rows.count, error: error)
        }
    }

    /// Stop: cancels the run and asks the server to stop the running statement
    /// (`pg_cancel_backend`, `KILL QUERY`, `sqlite3_interrupt`).
    func cancel() {
        guard let task else { return }
        task.cancel()
        if let driver = activeDriver {
            Task { try? await driver.cancelCurrentQuery() }
        }
    }

    /// The tab is closing: stop what runs and close the editor's connection.
    func close() {
        isClosed = true
        cancel()
        releaseConnection()
    }

    /// The editor's own connection, opened (with the connection's Initial Queries) on first use.
    private func queryDriver() async throws -> any DatabaseDriver {
        if let ownDriver { return ownDriver }
        let config = contextDriver.config
        guard let context, let session = context.session, !(config.kind == .sqlite && config.filePath.isEmpty) else { return contextDriver }
        let dedicated = session.makeDedicatedDriver(database: context.name)
        try await dedicated.connect()
        do {
            try await Session.runInitialQueries(session.config, on: dedicated)
        } catch {
            await dedicated.disconnect()
            throw error
        }
        // Closed or pointed elsewhere while connecting.
        guard !isClosed, self.context === context else {
            await dedicated.disconnect()
            throw CancellationError()
        }
        ownDriver = dedicated
        return dedicated
    }

    private func releaseConnection() {
        guard let dedicated = ownDriver else { return }
        ownDriver = nil
        Task { await dedicated.disconnect() }
    }

    /// Points the editor at another connection or database (the toolbar's pickers).
    func use(_ newContext: DatabaseContext) {
        guard !isRunning else { return }
        releaseConnection()
        resultEditors = [:]
        context = newContext
        contextDriver = newContext.driver
        location = newContext.location(schema: newContext.defaultSchema)
        connectionID = newContext.session?.id
        databaseName = newContext.name
        scheduleColumnPrefetch()
    }

    // MARK: - Capped results

    /// A result cut at the row limit whose statement only reads, so it can run again for more rows.
    func canLoadMore(_ result: QueryResult) -> Bool {
        result.isTruncated && SQLSplitter.isReadOnly(result.statement)
    }

    /// Runs the statement again reading one more page of rows.
    func loadMore(_ result: QueryResult) {
        reload(result, maxRows: result.rows.count + (rowLimit ?? 1_000))
    }

    /// Runs the statement again reading every row.
    func fetchAll(_ result: QueryResult) {
        reload(result, maxRows: nil)
    }

    // MARK: - Edit Result

    /// The table-tab editing model behind each shown result set (Navicat's Edit Result), made on demand.
    private(set) var resultEditors: [UUID: TableTabModel] = [:]

    func editor(for result: QueryResult) -> TableTabModel? { resultEditors[result.id] }

    /// Holds the editor a rerun closure belongs to (the closure is made before the editor).
    private final class EditorBox { weak var editor: TableTabModel? }

    /// Builds the result's editing model once: a statement reading one table (`ResultEditTarget`) with that table's
    /// primary key in the result can be edited; anything else stays read-only with the reason as tooltip.
    func prepareEditor(for result: QueryResult) async {
        guard result.isResultSet, resultEditors[result.id] == nil, let context else { return }
        let kind = contextDriver.config.kind
        let detected = ResultEditTarget.detect(result.statement)
        var target = try? detected.get()
        var refusal: String?
        if case .failure(let reason) = detected { refusal = reason.message }
        if kind.isDocumentStore || kind == .redis { refusal = "Results of this connection can't be edited"; target = nil }
        let schema: String? = switch kind {
        case .postgresql, .sqlserver: target?.schema ?? context.defaultSchema
        case .mysql, .mariadb: target?.schema ?? context.name
        case .sqlite: target?.schema.flatMap { $0.lowercased() == "main" ? nil : $0 } ?? context.driverSchema(nil)
        case .mongodb, .redis: nil
        }
        let object = DatabaseObject(schema: schema, name: target?.table ?? "Query Result", kind: .table)
        let box = EditorBox()
        let editor = TableTabModel(result: result, object: object, context: context, refusal: refusal) { [weak self] in
            guard let self, let editor = box.editor else { throw CancellationError() }
            return try await self.rerun(for: editor)
        }
        box.editor = editor
        resultEditors[result.id] = editor
        await editor.loadResultCatalog(target: target)
    }

    /// Runs an edited result's statement again (after Apply or Refresh) and puts the fresh rows in its tab.
    private func rerun(for editor: TableTabModel) async throws -> QueryResult {
        guard let oldID = resultEditors.first(where: { $0.value === editor })?.key,
              let old = results.first(where: { $0.id == oldID }) else { throw DatabaseError.queryFailed("The result is no longer open.") }
        let driver = try await queryDriver()
        let began = Date()
        let fresh = try await driver.executeTimed(old.statement, maxRows: old.isTruncated ? old.rows.count : rowLimit.map { max($0, old.rows.count) })
        replaceResult(oldID, with: fresh, began: began, editor: editor)
        return fresh
    }

    /// Puts a rerun's result in place of the old one: same tab, pin, plan and editor (when given; a stale editor is dropped).
    private func replaceResult(_ oldID: UUID, with fresh: QueryResult, began: Date, editor: TableTabModel? = nil) {
        guard let index = results.firstIndex(where: { $0.id == oldID }) else { return }
        resultEditors[oldID] = nil
        if let editor { resultEditors[fresh.id] = editor }
        results[index] = fresh
        if let plan = plans.removeValue(forKey: oldID) { plans[fresh.id] = plan }
        if let position = executions.firstIndex(where: { $0.result?.id == oldID }) {
            executions[position] = StatementExecution(statement: executions[position].statement, start: began, duration: fresh.duration, result: fresh, error: nil)
        }
        if pinnedResultIDs.remove(oldID) != nil { pinnedResultIDs.insert(fresh.id) }
        if selectedResultID == oldID { selectedResultID = fresh.id }
        if resultPane == .result(oldID) { resultPane = .result(fresh.id) }
    }

    private func reload(_ result: QueryResult, maxRows: Int?) {
        guard !isRunning, canLoadMore(result), results.contains(where: { $0.id == result.id }) else { return }
        if resultEditors[result.id]?.hasChanges == true { return }
        isRunning = true
        error = nil
        task = Task {
            defer {
                isRunning = false
                activeDriver = nil
            }
            do {
                let driver = try await queryDriver()
                activeDriver = driver
                let began = Date()
                let fresh = try await driver.executeTimed(result.statement, maxRows: maxRows)
                replaceResult(result.id, with: fresh, began: began)
            } catch {
                self.error = Task.isCancelled ? "Cancelled." : error.localizedDescription
            }
        }
    }

    /// Result sets of the last run, numbered "Result 1", "Result 2"… in the result panel.
    var resultSets: [QueryResult] { results.filter(\.isResultSet) }

    var elapsed: Duration? {
        guard let runStarted, let runEnded else { return nil }
        return .milliseconds(runEnded.timeIntervalSince(runStarted) * 1_000)
    }

    /// Explain: the plan of the selected statement, or of the one under the cursor, without running it
    /// (`SQLDialect.explain`). The plan opens as a tree in an "Explain" result tab.
    func explain() {
        let statement = hasSelection ? SQLSplitter.split(selectedText).first : currentStatement?.sql
        guard let statement else { return }
        let sql = contextDriver.dialect.explain(statement)
        execute([sql], history: sql, explaining: true)
    }

    func plan(for result: QueryResult) -> [QueryPlanNode]? { plans[result.id] }

    /// Navicat's Beautify SQL: keywords uppercased and one clause per line (done locally, no AI).
    func beautify() {
        let source = hasSelection ? selectedText : text
        let formatted = SQLBeautifier.format(source)
        insert(formatted, mode: hasSelection ? .replaceSelection : .replaceAll)
    }

    func updateCursor(in textView: NSTextView) {
        let string = textView.string as NSString
        let location = min(textView.selectedRange().location, string.length)
        cursorOffset = location
        let line: Int, lineStart: Int
        if let highlighter = (textView as? SQLTextView)?.highlighter, highlighter.length == string.length {
            // The editor's line table: a binary search instead of splitting everything before the cursor.
            let index = highlighter.line(containing: location)
            line = index + 1
            lineStart = highlighter.lineStarts[index]
        } else {
            lineStart = string.lineRange(for: NSRange(location: location, length: 0)).location
            var count = 1
            string.enumerateSubstrings(in: NSRange(location: 0, length: lineStart), options: [.byLines, .substringNotRequired]) { _, _, _, _ in count += 1 }
            line = count
        }
        let column = string.substring(with: NSRange(location: lineStart, length: location - lineStart)).count + 1
        if line != cursorLine { cursorLine = line }
        if column != cursorColumn { cursorColumn = column }
    }

    // MARK: - Editing from the AI

    func canInsert(_ mode: EditorInsertMode) -> Bool {
        mode == .replaceSelection ? hasSelection : true
    }

    /// Puts `code` into the editor through the text view, so ⌘Z undoes it.
    func insert(_ code: String, mode: EditorInsertMode) {
        guard let textView else {
            switch mode {
            case .replaceAll: text = code
            default: text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + code
            }
            return
        }
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        var range: NSRange
        var insertion = code
        switch mode {
        case .atCursor: range = NSRange(location: selection.location, length: 0)
        case .replaceSelection: range = selection
        case .replaceAll: range = NSRange(location: 0, length: string.length)
        case .append:
            range = NSRange(location: string.length, length: 0)
            if string.length > 0, !textView.string.hasSuffix("\n") { insertion = "\n\n" + code } else if string.length > 0 { insertion = "\n" + code }
        }
        guard textView.shouldChangeText(in: range, replacementString: insertion) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: insertion)
        textView.didChangeText()
        let inserted = NSRange(location: range.location, length: (insertion as NSString).length)
        textView.setSelectedRange(inserted)
        textView.scrollRangeToVisible(inserted)
        textView.window?.makeFirstResponder(textView)
    }

    private func record(_ sql: String, duration: Duration, rowCount: Int?, error: String?) {
        guard let session = context?.session else { return }
        session.onQueryExecuted?(QueryHistoryEntry(
            connectionID: session.id,
            sql: sql.trimmingCharacters(in: .whitespacesAndNewlines),
            durationMilliseconds: duration.milliseconds,
            rowCount: rowCount,
            error: error
        ))
    }

    // MARK: - Autocomplete

    func completions(prefix: String, qualifier: String?) -> [String] {
        guard let context else { return [] }
        return PerfTrace.measure("editor.completions") {
            SQLCompletion.suggestions(prefix: prefix, qualifier: qualifier, sql: completionWindow, catalog: context.completionCatalog)
        }
    }

    /// The text around the cursor that aliases are looked up in: the statement being typed is in there,
    /// and a long script isn't re-parsed (nor copied out of the editor) for every popup.
    private var completionWindow: String {
        guard let textView else { return text }
        let string = textView.string as NSString
        let cursor = min(textView.selectedRange().location, string.length)
        let start = max(cursor - 8_000, 0), end = min(cursor + 8_000, string.length)
        let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return string.substring(with: range)
    }

    /// Debounced so typing doesn't fire a catalog query per keystroke.
    private func scheduleColumnPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            // Finding the tables a long script mentions takes a while; do it off the main thread.
            let sql = self.text
            let references = await Task.detached(priority: .utility) { SQLCompletion.tableReferences(in: sql) }.value
            guard !Task.isCancelled else { return }
            self.context?.prefetchColumns(for: references)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    var shortDescription: String {
        let ms = milliseconds
        return ms < 1_000 ? String(format: "%.1f ms", ms) : String(format: "%.2f s", ms / 1_000)
    }
}
