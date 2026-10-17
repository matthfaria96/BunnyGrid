import BunnyGridCore
import Foundation
import Observation

/// A BI workspace tab (Navicat BI): data sources, charts and dashboards, saved to `bi-workspaces.json`.
/// It is a `DocumentTab`, so the shared tab switches need no BI case.
@MainActor
@Observable
final class BIWorkspaceModel: DocumentTab, Identifiable {
    enum Selection: Hashable {
        case chart(UUID)
        case dashboard(UUID)
        case source(UUID)
    }

    nonisolated let id = UUID()
    nonisolated var systemImage: String { "bi" }
    var workspace: BIWorkspace { didSet { scheduleSave() } }
    var selection: Selection?
    /// Chart results keyed by chart (editor) or dashboard item.
    private(set) var results: [UUID: BIResult] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []
    /// Distinct values per source and field, for dashboard filters.
    private(set) var valueCache: [String: [String]] = [:]
    private(set) var lastStatement = ""
    private(set) var warning: String?

    @ObservationIgnored private let resolve: @MainActor (UUID, String) -> (any DatabaseDriver)?
    @ObservationIgnored private let store = BIWorkspaceStore(fileURL: AppModel.dataDirectory.appending(path: "bi-workspaces.json"))
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    let connectionID: UUID?

    init(workspace: BIWorkspace, connectionID: UUID?, resolve: @escaping @MainActor (UUID, String) -> (any DatabaseDriver)?) {
        self.workspace = workspace
        self.connectionID = connectionID
        self.resolve = resolve
        selection = workspace.dashboards.first.map { .dashboard($0.id) } ?? workspace.charts.first.map { .chart($0.id) }
    }

    // MARK: DocumentTab

    var feature: Feature? { .bi }

    var title: String { workspace.name }
    var kindName: String { "BI Workspace" }
    var hasUnsavedChanges: Bool { false }
    var recordText: String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(workspace.sources.count, "data source"), count(workspace.charts.count, "chart"),
                count(workspace.dashboards.count, "dashboard")].joined(separator: ", ")
    }
    var attachmentText: String {
        var lines = ["BI workspace \(workspace.name)"]
        for source in workspace.sources {
            lines.append("Data source \(source.name): \(source.sql ?? source.table ?? "") — fields \(source.fields.map { "\($0.name) (\($0.type.rawValue))" }.joined(separator: ", "))")
        }
        for chart in workspace.charts {
            lines.append("Chart \(chart.displayTitle): \(chart.type.title) of \(chart.measures.map(\.label).joined(separator: ", ")) by \(chart.dimensions.map(\.label).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
    var canSave: Bool { true }
    func save() { saveNow() }
    func cancel() {
        refreshTasks.values.forEach { $0.cancel() }
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        workspace.updatedAt = Date()
        do { try store.upsert(workspace) } catch { warning = error.localizedDescription }
    }

    // MARK: Lookup

    var selectedChart: BIChart? {
        if case .chart(let id) = selection { workspace.chart(id) } else { nil }
    }
    var selectedDashboard: BIDashboard? {
        if case .dashboard(let id) = selection { workspace.dashboards.first { $0.id == id } } else { nil }
    }

    func fields(of chart: BIChart) -> [BIField] { workspace.source(chart.sourceID)?.fields ?? [] }

    func fieldType(_ name: String, in chart: BIChart) -> BIFieldType {
        fields(of: chart).first { $0.name == name }?.type ?? .text
    }

    func updateChart(_ id: UUID, refresh: Bool = true, _ change: (inout BIChart) -> Void) {
        guard let i = workspace.charts.firstIndex(where: { $0.id == id }) else { return }
        var chart = workspace.charts[i]
        let before = chart.spec()
        let source = chart.sourceID
        change(&chart)
        workspace.charts[i] = chart
        if refresh && (chart.spec() != before || chart.sourceID != source) { refreshChart(id) }
        if refresh, chart.spec() != before || chart.sourceID != source {
            for board in workspace.dashboards where board.items.contains(where: { $0.chartID == id }) { refreshDashboard(board.id) }
        }
    }

    func updateDashboard(_ id: UUID, refresh: Bool = false, _ change: (inout BIDashboard) -> Void) {
        guard let i = workspace.dashboards.firstIndex(where: { $0.id == id }) else { return }
        // On a copy, like updateChart: `change` may read the workspace (place() looks up the chart type), and
        // doing that while `workspace` is being mutated in place was an exclusivity crash on every chart placed
        // on a dashboard (drag from the sidebar, Add Chart, Add to Dashboard).
        var board = workspace.dashboards[i]
        change(&board)
        workspace.dashboards[i] = board
        if refresh { refreshDashboard(id) }
    }

    // MARK: Creating

    @discardableResult
    func addSource(name: String, connectionID: UUID, database: String, schema: String?, table: String?, sql: String?) -> UUID {
        let source = BIDataSource(name: name, connectionID: connectionID, database: database, schema: schema, table: table, sql: sql)
        workspace.sources.append(source)
        Task { await loadFields(source.id) }
        return source.id
    }

    func removeSource(_ id: UUID) {
        workspace.sources.removeAll { $0.id == id }
        for i in workspace.charts.indices where workspace.charts[i].sourceID == id { workspace.charts[i].sourceID = nil }
        if selection == .source(id) { selection = nil }
    }

    @discardableResult
    func addChart(type: BIChartType = .bar, sourceID: UUID? = nil) -> UUID {
        let n = workspace.charts.count + 1
        let chart = BIChart(name: "Chart \(n)", sourceID: sourceID ?? workspace.sources.first?.id, type: type)
        workspace.charts.append(chart)
        selection = .chart(chart.id)
        return chart.id
    }

    func duplicateChart(_ id: UUID) {
        guard var copy = workspace.chart(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        workspace.charts.append(copy)
        selection = .chart(copy.id)
        refreshChart(copy.id)
    }

    func removeChart(_ id: UUID) {
        workspace.charts.removeAll { $0.id == id }
        for i in workspace.dashboards.indices { workspace.dashboards[i].items.removeAll { $0.chartID == id } }
        if selection == .chart(id) { selection = workspace.charts.first.map { .chart($0.id) } }
    }

    @discardableResult
    func addDashboard() -> UUID {
        let board = BIDashboard(name: "Dashboard \(workspace.dashboards.count + 1)")
        workspace.dashboards.append(board)
        selection = .dashboard(board.id)
        return board.id
    }

    func removeDashboard(_ id: UUID) {
        workspace.dashboards.removeAll { $0.id == id }
        if selection == .dashboard(id) { selection = nil }
    }

    func place(_ chartID: UUID, on dashboardID: UUID) {
        updateDashboard(dashboardID) { board in
            let type = workspace.chart(chartID)?.type
            let (w, h) = type == .kpi ? (3, 2) : (6, 4)
            let slot = board.nextSlot(width: w, height: h)
            board.items.append(BIDashboardItem(chartID: chartID, x: slot.x, y: slot.y, width: w, height: h))
        }
        refreshDashboard(dashboardID)
    }

    // MARK: Data

    private func driver(for source: BIDataSource) -> (any DatabaseDriver)? {
        resolve(source.connectionID, source.database)
    }

    func loadFields(_ sourceID: UUID) async {
        guard let source = workspace.source(sourceID) else { return }
        guard let driver = driver(for: source) else { warning = "\(source.name): the connection is not open."; return }
        do {
            let fields = try await BIEngine.fields(for: source, driver: driver)
            if let i = workspace.sources.firstIndex(where: { $0.id == sourceID }) { workspace.sources[i].fields = fields }
            warning = nil
        } catch {
            warning = "\(source.name): \(error.localizedDescription)"
        }
    }

    func setRole(_ role: BIFieldRole, field: String, source sourceID: UUID) {
        guard let i = workspace.sources.firstIndex(where: { $0.id == sourceID }),
              let j = workspace.sources[i].fields.firstIndex(where: { $0.name == field }) else { return }
        workspace.sources[i].fields[j].role = role
    }

    /// Refreshes the chart shown in the editor (keyed by chart id).
    func refreshChart(_ id: UUID) {
        guard let chart = workspace.chart(id) else { return }
        run(key: id, chart: chart, extraFilters: [])
    }

    /// Refreshes every chart on a dashboard with its interactive filters (keyed by item id).
    func refreshDashboard(_ id: UUID) {
        guard let board = workspace.dashboards.first(where: { $0.id == id }) else { return }
        for item in board.items {
            guard let chart = workspace.chart(item.chartID) else { continue }
            let fields = Set(fields(of: chart).map(\.name))
            run(key: item.id, chart: chart, extraFilters: board.filters.filter { fields.contains($0.field) })
        }
    }

    func refreshAll() {
        Task {
            for source in workspace.sources { await loadFields(source.id) }
            switch selection {
            case .chart(let id): refreshChart(id)
            case .dashboard(let id): refreshDashboard(id)
            default: break
            }
        }
    }

    private func run(key: UUID, chart: BIChart, extraFilters: [BIFilter]) {
        refreshTasks[key]?.cancel()
        guard let source = workspace.source(chart.sourceID) else {
            results[key] = nil
            errors[key] = "Choose a data source."
            return
        }
        guard let driver = driver(for: source) else {
            errors[key] = "The connection of \(source.name) is not open."
            return
        }
        let spec = chart.spec(extraFilters: extraFilters)
        loading.insert(key)
        refreshTasks[key] = Task { [weak self] in
            // Coalesce rapid edits (dragging fields, typing a Top N) into one query.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            do {
                if source.fields.isEmpty { await self?.loadFields(source.id) }
                let result = try await BIEngine.run(spec, source: source, driver: driver)
                guard !Task.isCancelled, let self else { return }
                self.results[key] = result
                self.errors[key] = nil
                self.lastStatement = result.statement ?? "Aggregated in memory"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errors[key] = error.localizedDescription
            }
            self?.loading.remove(key)
        }
    }

    /// The values a dashboard filter offers: distinct values of the field on the first source that has it.
    func values(for field: String) async -> [String] {
        guard let source = workspace.sources.first(where: { $0.fields.contains { $0.name == field } }) else { return [] }
        let key = "\(source.id)/\(field)"
        if let cached = valueCache[key] { return cached }
        guard let driver = driver(for: source) else { return [] }
        let values = (try? await BIEngine.distinctValues(field: field, source: source, driver: driver)) ?? []
        valueCache[key] = values
        return values
    }

    /// Fields a dashboard can filter on: dimensions of the sources its charts use.
    func filterableFields(_ board: BIDashboard) -> [BIField] {
        let sources = Set(board.items.compactMap { workspace.chart($0.chartID)?.sourceID })
        var seen = Set<String>()
        return workspace.sources.filter { sources.contains($0.id) }.flatMap(\.fields)
            .filter { $0.role == .dimension && seen.insert($0.name).inserted }
    }
}
