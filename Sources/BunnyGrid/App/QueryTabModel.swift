import BunnyGridCore
import Foundation
import Observation

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
    @ObservationIgnored private weak var context: DatabaseContext?
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
