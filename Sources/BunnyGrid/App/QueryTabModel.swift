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

/// A SQL editor tab with its results.
@MainActor
@Observable
final class QueryTabModel: Identifiable {
    let id = UUID()
    var title: String
    var text: String {
        didSet { scheduleColumnPrefetch() }
    }
    var selectedText = ""
    private(set) var results: [QueryResult] = []
    var selectedResultID: UUID?
    private(set) var isRunning = false
    private(set) var error: String?
    /// The statement that failed and the engine's message, for Fix with AI / Explain Error.
    private(set) var failedStatement: String?
    private(set) var failureMessage: String?
    @ObservationIgnored private(set) weak var context: DatabaseContext?
    /// The editor's text view, registered by `SQLEditorView`, so AI code can be inserted with undo.
    @ObservationIgnored weak var textView: NSTextView?
    /// The Ask AI answer being shown for this editor.
    var aiRun: AskAIRun?
    /// The Ask AI custom actions sheet.
    var showingAskAICustom = false
    @ObservationIgnored private let driver: any DatabaseDriver
    let location: String
    let connectionID: UUID?
    let databaseName: String
    /// Set once the query is saved to the navigator's Queries folder.
    private(set) var savedQueryID: UUID?
    private var savedText: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init(title: String, text: String, context: DatabaseContext) {
        self.title = title
        self.text = text
        self.context = context
        self.driver = context.driver
        self.location = context.location(schema: context.defaultSchema)
        self.connectionID = context.session?.id
        self.databaseName = context.name
        scheduleColumnPrefetch()
    }

    convenience init(saved: SavedQuery, context: DatabaseContext) {
        self.init(title: saved.name, text: saved.sql, context: context)
        markSaved(id: saved.id, name: saved.name)
    }

    var isDirty: Bool {
        savedQueryID == nil ? !text.isEmpty : text != savedText
    }

    func markSaved(id: UUID, name: String) {
        savedQueryID = id
        savedText = text
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

    /// Runs the selection if there is one, otherwise the whole editor.
    func run() {
        let script = hasSelection ? selectedText : text
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isRunning else { return }
        isRunning = true
        error = nil
        failedStatement = nil
        failureMessage = nil
        task = Task {
            defer { isRunning = false }
            let clock = ContinuousClock()
            let start = clock.now
            // Statement by statement, so results before a failing statement stay visible.
            let statements = SQLSplitter.split(script)
            results = []
            for (index, statement) in statements.enumerated() {
                do {
                    try Task.checkCancellation()
                    results.append(try await driver.executeTimed(statement))
                } catch is CancellationError {
                    error = "Cancelled."
                    break
                } catch {
                    let prefix = statements.count > 1 ? "Statement \(index + 1) of \(statements.count) failed: " : ""
                    self.error = prefix + error.localizedDescription
                    failedStatement = statement
                    failureMessage = error.localizedDescription
                    break
                }
            }
            selectedResultID = results.last(where: \.isResultSet)?.id ?? results.last?.id
            record(script, duration: clock.now - start, rowCount: results.last(where: \.isResultSet)?.rows.count, error: error)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
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
        return SQLCompletion.suggestions(prefix: prefix, qualifier: qualifier, sql: text, catalog: context.completionCatalog)
    }

    /// Debounced so typing doesn't fire a catalog query per keystroke.
    private func scheduleColumnPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.context?.prefetchColumns(for: self.text)
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
