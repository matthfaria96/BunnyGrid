import BunnyGridCore
import Foundation

extension AppModel {
    var biStore: BIWorkspaceStore { BIWorkspaceStore(fileURL: Self.dataDirectory.appending(path: "bi-workspaces.json")) }

    /// Saved workspaces, most recent first.
    var biWorkspaces: [BIWorkspace] { biStore.load().sorted { $0.updatedAt > $1.updatedAt } }

    private func biModel(_ workspace: BIWorkspace, connectionID: UUID?) -> BIWorkspaceModel {
        BIWorkspaceModel(workspace: workspace, connectionID: connectionID) { [weak self] connection, database in
            self?.sessions[connection]?.context(database)?.driver
        }
    }

    /// Opens a saved workspace (reusing its tab).
    func openBIWorkspace(_ workspace: BIWorkspace) {
        if let tab = tabs.first(where: { if case .document(let t) = $0 { (t as? BIWorkspaceModel)?.workspace.id == workspace.id } else { false } }) {
            selectedTabID = tab.id
            return
        }
        let model = biModel(workspace, connectionID: workspace.sources.first?.connectionID)
        appendTab(.document(model))
        model.refreshAll()
    }

    /// "New BI Workspace": an empty workspace, or (from a table's "Create BI Workspace") one with that table as its
    /// data source and a first chart.
    func newBIWorkspace(in context: DatabaseContext?, table: DatabaseObject? = nil) {
        var workspace = BIWorkspace(name: table.map { "\($0.name) Workspace" } ?? "BI Workspace \(biWorkspaces.count + 1)")
        if let context, let session = context.session {
            let objects = table.map { [$0] } ?? []
            for object in objects {
                workspace.sources.append(BIDataSource(name: object.name, connectionID: session.id, database: context.name,
                                                      schema: object.schema, table: object.name))
            }
        }
        if let source = workspace.sources.first { workspace.charts.append(BIChart(name: "Chart 1", sourceID: source.id)) }
        try? biStore.upsert(workspace)
        let model = biModel(workspace, connectionID: context?.session?.id)
        appendTab(.document(model))
        model.refreshAll()
    }

    #if DEBUG
    /// `--bi-demo`: a sample workspace on the opened database (demo.sqlite): sales by month, status mix, top cities,
    /// a KPI, a heatmap and a pivot, arranged on a dashboard with a status filter.
    /// `--bi-chart N` opens chart N in the editor instead; `--bi-export PATH.png|pdf` writes the dashboard.
    func openBIDemo(context: DatabaseContext) {
        guard let session = context.session else { return }
        let sql = """
            SELECT o.id, o.total, o.status, c.city, c.name AS customer,
                   date('2025-01-01', '+' || ((o.id * 37) % 365) || ' days') AS order_date
            FROM orders o JOIN customers c ON c.id = o.customer_id
            """
        let source = BIDataSource(name: "Orders with Customers", connectionID: session.id, database: context.name, sql: sql)
        let table = BIDataSource(name: "customers", connectionID: session.id, database: context.name, table: "customers")
        let sum = BIMeasure(field: "total", aggregation: .sum)
        let month = BIDimension(field: "order_date", bucket: .month)
        let charts = [
            BIChart(name: "Revenue by Month", sourceID: source.id, type: .area, dimensions: [month], measures: [sum],
                    color: BIDimension(field: "status"), title: "Revenue by Month", palette: .standard, numberFormat: .compact),
            BIChart(name: "Orders by Status", sourceID: source.id, type: .donut, dimensions: [BIDimension(field: "status")],
                    measures: [BIMeasure(field: nil, aggregation: .count)], title: "Orders by Status"),
            BIChart(name: "Revenue", sourceID: source.id, type: .kpi, measures: [sum], title: "Total Revenue", numberFormat: .currency),
            BIChart(name: "Orders", sourceID: source.id, type: .kpi, measures: [BIMeasure(field: "id", aggregation: .countDistinct)], title: "Orders"),
            BIChart(name: "Average Order", sourceID: source.id, type: .kpi, measures: [BIMeasure(field: "total", aggregation: .avg)],
                    title: "Average Order", numberFormat: .currency),
            BIChart(name: "Revenue by City", sourceID: source.id, type: .stackedBar, dimensions: [BIDimension(field: "city")], measures: [sum],
                    color: BIDimension(field: "status"), title: "Revenue by City and Status", palette: .ocean, numberFormat: .compact),
            BIChart(name: "Quarter Heatmap", sourceID: source.id, type: .heatmap,
                    dimensions: [BIDimension(field: "order_date", bucket: .quarter), BIDimension(field: "city")], measures: [sum],
                    title: "Revenue by Quarter and City", palette: .sunset, numberFormat: .compact),
            BIChart(name: "Weekly Orders", sourceID: source.id, type: .line, dimensions: [BIDimension(field: "order_date", bucket: .week)],
                    measures: [BIMeasure(field: nil, aggregation: .count)], title: "Orders per Week", palette: .forest),
            BIChart(name: "Pivot", sourceID: source.id, type: .table, dimensions: [BIDimension(field: "city"), BIDimension(field: "status")],
                    measures: [sum], title: "Revenue Pivot", numberFormat: .decimal),
        ]
        var board = BIDashboard(name: "Sales Overview", filters: [BIFilter(field: "status", op: .isIn, values: [])])
        let layout: [(Int, Int, Int, Int)] = [(0, 2, 8, 4), (8, 2, 4, 4), (0, 0, 4, 2), (4, 0, 4, 2), (8, 0, 4, 2), (0, 6, 6, 4), (6, 6, 6, 4)]
        for (chart, frame) in zip(charts, layout) {
            board.items.append(BIDashboardItem(chartID: chart.id, x: frame.0, y: frame.1, width: frame.2, height: frame.3))
        }
        let workspace = BIWorkspace(name: "Sales BI", sources: [source, table], charts: charts, dashboards: [board])
        try? biStore.upsert(workspace)
        let model = biModel(workspace, connectionID: session.id)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--bi-chart"), args.indices.contains(i + 1), let n = Int(args[i + 1]), charts.indices.contains(n) {
            model.selection = .chart(charts[n].id)
        }
        if let i = args.firstIndex(of: "--bi-filter"), args.indices.contains(i + 1) {
            model.updateDashboard(board.id) { $0.filters[0].values = args[i + 1].components(separatedBy: ",") }
        }
        appendTab(.document(model))
        model.refreshAll()
        if args.contains("--bi-focus") && !isFocusMode { toggleFocusMode() }
    }

    /// Runs the BI debug flags once the database is open.
    func runBIDebugFlags(opened: UUID?, database: String) {
        guard CommandLine.arguments.contains("--bi-demo"), let id = opened else { return }
        Task {
            while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
            if let context = sessions[id]?.context(database) { openBIDemo(context: context) }
        }
    }
    #endif
}
