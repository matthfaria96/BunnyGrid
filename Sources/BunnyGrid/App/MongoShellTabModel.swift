import BunnyGridCore
import Foundation
import Observation

/// Navicat's MongoDB query editor: shell-style commands (`db.coll.find(…).sort(…)`, `aggregate([…])`, `insertOne`…)
/// on the tab's own connection, one result per statement, Explain as a plan tree, and Stop through `killOp`.
@MainActor
@Observable
final class MongoShellTabModel: DocumentTab {
    struct Output: Identifiable {
        let id = UUID()
        let output: MongoShellOutput
        let plan: [QueryPlanNode]?
    }

    nonisolated let id = UUID()
    var name: String
    var text: String
    var selectedText = ""
    private(set) var database: String
    @ObservationIgnored weak var context: DatabaseContext?
    let connectionID: UUID?
    private(set) var outputs: [Output] = []
    var selectedOutputID: UUID?
    var viewMode: CollectionTabModel.ViewMode = .grid
    private(set) var isRunning = false
    var error: String?
    private(set) var lastStatement = ""
    @ObservationIgnored private var driver: MongoDriver?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(title: String, text: String, context: DatabaseContext) {
        name = title
        self.text = text
        self.context = context
        database = context.name
        connectionID = context.session?.id
    }

    var title: String { "\(name)@\(database) (\(context?.session?.config.displayName ?? "MongoDB"))" }
    var kindName: String { "Query" }
    nonisolated var systemImage: String { "query" }
    var hasUnsavedChanges: Bool { false }
    var warning: String? { error }
    var selectedOutput: Output? { outputs.first { $0.id == selectedOutputID } ?? outputs.last }
    var recordText: String {
        guard let output = selectedOutput else { return "" }
        let count = output.output.documents.count
        return count == 1 ? "1 document" : "\(count.countText) documents"
    }
    var attachmentText: String { text }
    var canSave: Bool { false }
    func save() {}

    func cancel() {
        task?.cancel()
        let driver = driver
        self.driver = nil
        Task { await driver?.disconnect() }
    }

    /// The tab's own connection, opened on first use (a long query doesn't block the navigator).
    private func connectedDriver() async throws -> MongoDriver {
        if let driver { return driver }
        guard let session = context?.session, let made = session.makeDedicatedDriver(database: database) as? MongoDriver else {
            throw DatabaseError.notConnected
        }
        try await made.connect()
        driver = made
        return made
    }

    func run() {
        let script = selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : selectedText
        execute(script, explain: false)
    }

    /// Explains the first statement (find, aggregate, count…) instead of running it.
    func explain() {
        let script = selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : selectedText
        execute(script, explain: true)
    }

    private func execute(_ script: String, explain: Bool) {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        let limit = AppOptions.shared.values.recordsPerPage
        task = Task {
            defer { isRunning = false }
            do {
                var statements = try MongoShellParser.parseScript(script)
                if explain {
                    guard var first = statements.first(where: { if case .collection = $0.target { true } else { false } }) else {
                        throw DatabaseError.queryFailed("Explain needs a collection command such as db.coll.find().")
                    }
                    if first.chained("explain") == nil { first.calls.append(MongoShellCall("explain")) }
                    statements = [first]
                }
                let driver = try await connectedDriver()
                var executor = MongoShellExecutor(driver: driver, database: database)
                var results: [Output] = []
                for statement in statements {
                    try Task.checkCancellation()
                    lastStatement = statement.text
                    let output = try await executor.run(statement, maxDocuments: limit)
                    if let db = output.switchedDatabase {
                        executor.database = db
                        database = db
                    }
                    var plan: [QueryPlanNode]?
                    if case .plan(let document) = output.content { plan = MongoExplain.plan(document) }
                    results.append(Output(output: output, plan: plan))
                    if let session = context?.session {
                        let ms = Double(output.duration.components.seconds) * 1000 + Double(output.duration.components.attoseconds) / 1e15
                        session.onQueryExecuted?(QueryHistoryEntry(connectionID: session.id, sql: statement.text, durationMilliseconds: ms,
                                                                   rowCount: output.documents.count))
                    }
                }
                outputs = results
                selectedOutputID = results.last?.id
                if results.contains(where: { $0.plan != nil }) { viewMode = .tree }
            } catch is CancellationError {
                error = "Cancelled."
            } catch {
                self.error = ConnectionErrorText.describe(error)
            }
        }
    }

    func stop() {
        let driver = driver
        Task { try? await driver?.cancelCurrentQuery() }
    }
}
