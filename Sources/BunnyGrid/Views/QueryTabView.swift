import AppKit
import BunnyGridCore
import SwiftUI

/// The query editor, laid out like Navicat's: a tool row (Save, Beautify SQL, Code Snippet, Ask AI, result layout,
/// focus mode), a run row (connection, database, Run, Stop, Explain), the editor, and the result panel
/// with Message / Summary / Result tabs below or beside it.
struct QueryTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: QueryTabModel
    @State private var showingHistory = false
    @AppStorage("showAIFeatures") private var showAIFeatures = true

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            runRow
            Divider()
            Group {
                if model.showResultPanel {
                    if model.resultsBesideEditor {
                        HSplitView {
                            editor.frame(minWidth: 220)
                            QueryResultPanel(model: model).frame(minWidth: 260)
                        }
                    } else {
                        VSplitView {
                            editor.frame(minHeight: 100, idealHeight: 240)
                            QueryResultPanel(model: model).frame(minHeight: 140)
                        }
                    }
                } else {
                    editor
                }
            }
        }
        .overlay { AskAIOverlay(query: model) }
    }

    private var editor: some View {
        SQLEditorView(text: $model.text, selectedText: $model.selectedText, completions: { prefix, qualifier in
            model.completions(prefix: prefix, qualifier: qualifier)
        }, onTextView: { model.textView = $0 }, onCursorChange: { model.updateCursor(in: $0) }, menuItems: editorMenu)
    }

    /// Run and format commands at the top of the editor's context menu, as in Navicat.
    private var editorMenu: [SQLEditorView.MenuItem] {
        let idle = !model.isRunning
        return [
            .init(title: "Run Selected", isEnabled: idle && model.hasSelection) { model.runSelected() },
            .init(title: "Run Current Statement", key: "\r", modifiers: [.command, .shift], isEnabled: idle) { model.runCurrentStatement() },
            .init(title: "Explain", isEnabled: idle) { model.explain() },
            .init(title: "Beautify SQL", key: "b", modifiers: [.command, .shift], isEnabled: true) { model.beautify() },
        ]
    }

    /// Shortcuts without a visible button of their own (the Run menu lists them).
    private var hiddenShortcuts: some View {
        Group {
            Button("Run Current Statement") { model.runCurrentStatement() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.isRunning)
            Button("Beautify SQL") { model.beautify() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Stop") { model.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isRunning)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var toolRow: some View {
        HStack(spacing: 2) {
            ToolIconButton(systemImage: "square.and.arrow.down", help: "Save (⌘S)", tint: .secondary) { app.saveQuery(model) }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "hammer", help: "Query Builder (coming soon)") {}
                .disabled(true)
            ToolIconButton(systemImage: "wand.and.stars", help: "Beautify SQL (⌘⇧B)") { model.beautify() }
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ToolIconButton(systemImage: "parentheses", help: "Code Snippet") {
                app.showAssistant = true
                app.rightPane = .snippets
            }
            if showAIFeatures {
                AskAIButton(query: model)
                    .padding(.leading, 4)
            }
            Spacer()
            ToolIconButton(systemImage: "rectangle.split.1x2", help: "Show Result Below Editor", isToggle: true, isOn: model.showResultPanel && !model.resultsBesideEditor) {
                model.resultsBesideEditor = false
                model.showResultPanel = true
            }
            ToolIconButton(systemImage: "rectangle.split.2x1", help: "Show Result Next to Editor", isToggle: true, isOn: model.showResultPanel && model.resultsBesideEditor) {
                model.resultsBesideEditor = true
                model.showResultPanel = true
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "viewfinder", help: "Enter Focus Mode", isOn: app.isFocusMode) {
                app.toggleFocusMode()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var runRow: some View {
        HStack(spacing: 8) {
            ConnectionPicker(model: model)
            DatabasePicker(model: model)
            Spacer(minLength: 8)
            Menu {
                Button("Run") { model.run() }
                Button("Run Selected") { model.runSelected() }.disabled(!model.hasSelection)
                Button("Run Current Statement") { model.runCurrentStatement() }
                Button("Run All") { model.runAll() }
                Divider()
                Button("Query History…") { showingHistory = true }
            } label: {
                Label(model.hasSelection ? "Run Selected" : "Run", systemImage: "play")
            } primaryAction: {
                model.run()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning)
            .help("Run (⌘↩) runs the selection, or the whole editor without one. Run Current Statement (⌘⇧↩) runs the statement under the cursor.")
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                if let connectionID = model.connectionID {
                    HistoryPopover(connectionID: connectionID) { sql in
                        model.text = sql
                        showingHistory = false
                    }
                }
            }
            ToolIconButton(systemImage: "stop", help: "Stop (⌘.): cancels the statement on the server", tint: .red) { model.cancel() }
                .disabled(!model.isRunning)
            ToolIconButton(systemImage: "flowchart", help: "Explain: the plan of the selected statement, or of the one under the cursor") { model.explain() }
                .disabled(model.isRunning || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .keyboardShortcut("y", modifiers: [.command, .shift])
        .background { hiddenShortcuts }
    }
}

/// A borderless icon button with a tooltip, tinted when on.
struct ToolIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .accentColor
    /// Layout toggles are tinted only while on, like Navicat's result-position buttons.
    var isToggle = false
    var isOn = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isEnabled ? (isOn || !isToggle ? tint : Color.primary.opacity(0.8)) : Color.secondary.opacity(0.5))
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovering && isEnabled ? Color.primary.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Connection popup: any connected session.
private struct ConnectionPicker: View {
    @Environment(AppModel.self) private var app
    let model: QueryTabModel

    var body: some View {
        let current = model.connectionID.flatMap { app.connection(id: $0) }
        Menu {
            ForEach(app.connections) { config in
                Button {
                    guard let session = app.connect(config.id) else { return }
                    Task {
                        var waited = 0
                        while !session.isConnected && !session.isFailed && waited < 100 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
                        let database = config.kind == .sqlite ? "main" : (config.database.isEmpty ? session.databases.first ?? "" : config.database)
                        guard session.isConnected, !database.isEmpty else { return }
                        model.use(session.openDatabase(database))
                    }
                } label: {
                    if config.id == model.connectionID { Label(config.displayName, systemImage: "checkmark") } else { Text(config.displayName) }
                }
            }
        } label: {
            Label {
                Text(current?.displayName ?? "No Connection").lineLimit(1)
            } icon: {
                if let current, let icon = IconLibrary.image(current.kind.iconName, size: 14) { Image(nsImage: icon) }
            }
            .labelStyle(.titleAndIcon)
            .popupFieldLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRunning)
    }
}

/// Database popup: the databases of the editor's connection.
private struct DatabasePicker: View {
    @Environment(AppModel.self) private var app
    let model: QueryTabModel

    var body: some View {
        let session = model.connectionID.flatMap { app.sessions[$0] }
        Menu {
            ForEach(session?.databases ?? [], id: \.self) { database in
                Button {
                    if let session { model.use(session.openDatabase(database)) }
                } label: {
                    if database == model.databaseName { Label(database, systemImage: "checkmark") } else { Text(database) }
                }
            }
        } label: {
            Label {
                Text(model.databaseName).lineLimit(1)
            } icon: {
                if let icon = IconLibrary.image("database-open", size: 14) { Image(nsImage: icon) }
            }
            .labelStyle(.titleAndIcon)
            .popupFieldLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRunning || session == nil)
    }
}

// MARK: - Result panel

/// Message · Summary · Result N, with Maximize and Hide on the right, as in Navicat.
private struct QueryResultPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: QueryTabModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 4) {
                    tab("Message", .message)
                    tab("Summary", .summary)
                    ForEach(Array(model.resultSets.enumerated()), id: \.element.id) { index, result in
                        tab((model.pinnedResultIDs.contains(result.id) ? "📌 " : "") + (model.plan(for: result) != nil ? "Explain" : "Result \(index + 1)"), .result(result.id))
                            .help(result.statement)
                    }
                }
                HStack {
                    Spacer()
                    ToolIconButton(systemImage: "chevron.up", help: "Maximize Panel", tint: .secondary) {
                        model.resultsBesideEditor = false
                        app.toggleFocusMode()
                    }
                    ToolIconButton(systemImage: "xmark", help: "Hide Panel", tint: .secondary) { model.showResultPanel = false }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 32)
            Divider()
            Group {
                switch model.resultPane {
                case .message: MessagePane(model: model)
                case .summary: SummaryPane(model: model)
                case .result(let id):
                    if let result = model.resultSets.first(where: { $0.id == id }) {
                        ResultSetPane(model: model, result: result).id(result.id)
                    } else {
                        MessagePane(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tab(_ title: String, _ pane: QueryResultPane) -> some View {
        let selected = model.resultPane == pane
        return Button { model.resultPane = pane } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The log: each statement, then "> OK" / "> Affected rows" / the error, and its time.
private struct MessagePane: View {
    let model: QueryTabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.executions.isEmpty {
                    Text(model.isRunning ? "Running…" : "Run a query to see messages here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.executions) { execution in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(execution.statement)
                        if let error = execution.error {
                            Text("> \(error)").foregroundStyle(.red)
                        } else if let affected = execution.result?.affectedRows, execution.result?.isResultSet == false {
                            Text("> Affected rows: \(affected)")
                        } else {
                            Text("> OK")
                            if let result = execution.result, result.isTruncated {
                                Text("> Fetched the first \(result.rows.count.formatted()) rows; more are available")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("> Query Time: \(String(format: "%.3f", execution.duration.milliseconds / 1_000))s")
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

/// Processed / Success / Error counts, times, and the per-statement table with Fix with AI on failures.
private struct SummaryPane: View {
    @Environment(AppModel.self) private var app
    let model: QueryTabModel
    @State private var errorsOnly = false
    @AppStorage("showAIFeatures") private var showAIFeatures = true

    private var rows: [StatementExecution] {
        errorsOnly ? model.executions.filter { !$0.succeeded } : model.executions
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Processed Query"); Text("\(model.executions.count)")
                    label("Start Time"); Text(model.runStarted.map(Self.time) ?? "--")
                }
                GridRow {
                    label("Success"); Text("\(model.executions.filter(\.succeeded).count)")
                    label("End Time"); Text(model.runEnded.map(Self.time) ?? "--")
                }
                GridRow {
                    label("Error"); Text("\(model.executions.filter { !$0.succeeded }.count)")
                    label("Elapsed Time")
                    HStack(spacing: 14) {
                        Text(model.elapsed.map { String(format: "%.3fs", $0.milliseconds / 1_000) } ?? "--")
                        Toggle("Show errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            Divider()
            Table(rows) {
                TableColumn("Query") { execution in
                    HStack(alignment: .top, spacing: 6) {
                        Text(execution.statement).lineLimit(3).foregroundStyle(execution.succeeded ? Color.primary : Color.red)
                        if !execution.succeeded && showAIFeatures {
                            Spacer(minLength: 4)
                            Button("Fix with AI") { AskAI.run(.fixError, on: model, app: app) }
                                .controlSize(.small)
                                .help("Let the AI assistant correct this statement")
                        }
                    }
                }
                .width(min: 180, ideal: 320)
                TableColumn("Message") { execution in
                    HStack(alignment: .top, spacing: 6) {
                        Text(execution.error ?? "OK").lineLimit(3).foregroundStyle(execution.succeeded ? Color.primary : Color.red)
                        if !execution.succeeded && showAIFeatures {
                            Spacer(minLength: 4)
                            Button("Ask AI") { AskAI.run(.explainError, on: model, app: app) }
                                .controlSize(.small)
                                .help("Explain this error message")
                        }
                    }
                }
                .width(min: 160, ideal: 280)
                TableColumn("Query Time") { execution in
                    Text(String(format: "%.4f", execution.duration.milliseconds / 1_000)).monospacedDigit()
                }
                .width(80)
                TableColumn("Fetch Time") { execution in
                    Text(execution.result?.isResultSet == true ? "0.000" : "--").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// One result set: Data | Info (Plan | Data | Info for Explain), Export on the right, the grid and its footer.
private struct ResultSetPane: View {
    private enum SubTab { case plan, data, info }

    @Bindable var model: QueryTabModel
    let result: QueryResult
    @State private var chosenTab: SubTab?
    @State private var formView = false
    @State private var focusedRow = 0

    private var plan: [QueryPlanNode]? { model.plan(for: result) }
    private var subTab: SubTab { chosenTab ?? (plan != nil ? .plan : .data) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if plan != nil { subTabButton("Plan", .plan) }
                subTabButton("Data", .data)
                subTabButton("Info", .info)
                Spacer()
                if subTab == .data {
                    ToolIconButton(systemImage: "square.and.pencil", help: "Edit Result: query results are read-only; open the table to edit") {}
                        .disabled(true)
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    ToolIconButton(systemImage: "chart.bar.xaxis", help: "Data Profiling: available on table tabs") {}
                        .disabled(true)
                    ExportMenu(columns: result.columns, rows: result.rows, suggestedName: model.title)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                        .help(result.isTruncated ? "Export the rows fetched so far" : "Export Result")
                    Divider().frame(height: 16).padding(.horizontal, 4)
                }
                let pinned = model.pinnedResultIDs.contains(result.id)
                ToolIconButton(systemImage: pinned ? "pin.fill" : "pin", help: pinned ? "Unpin Result" : "Pin Result: keep this tab when the query runs again") {
                    if pinned { model.pinnedResultIDs.remove(result.id) } else { model.pinnedResultIDs.insert(result.id) }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            switch subTab {
            case .info:
                ResultInfo(model: model, result: result)
            case .plan:
                QueryPlanView(nodes: plan ?? [])
            case .data:
                if formView {
                    QueryResultForm(result: result, row: $focusedRow)
                } else {
                    ResultGridView(columns: result.columns, rows: result.rows, onFocusChange: { cell in
                        if let cell { focusedRow = cell.row }
                    })
                }
                Divider()
                footer
            }
        }
    }

    /// The statement, and for a result cut at the row limit: how many rows came, Load More and Fetch All.
    private var footer: some View {
        HStack(spacing: 10) {
            // Record buttons as in Navicat; a query result is read-only, so they stay disabled.
            HStack(spacing: 4) {
                ForEach(["plus", "minus", "checkmark", "xmark"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 22)
                }
            }
            .foregroundStyle(.tertiary)
            .help("Query results are read-only")
            if result.isTruncated {
                Text("First \(result.rows.count.formatted()) rows")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if model.canLoadMore(result) {
                    Button("Load More") { model.loadMore(result) }
                        .help("Run the statement again, fetching \((model.rowLimit ?? 1_000).formatted()) more rows")
                    Button("Fetch All") { model.fetchAll(result) }
                        .help("Run the statement again, fetching every row")
                }
            }
            Text(result.statement.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
                .frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                ToolIconButton(systemImage: "tablecells", help: "Grid View", isToggle: true, isOn: !formView) { formView = false }
                ToolIconButton(systemImage: "list.bullet.rectangle", help: "Form View", isToggle: true, isOn: formView) { formView = true }
            }
            .buttonStyle(.plain)
        }
        .buttonStyle(.link)
        .disabled(model.isRunning)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func subTabButton(_ title: String, _ tab: SubTab) -> some View {
        subTab(title, selected: subTab == tab) { chosenTab = tab }
    }

    private func subTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Time Stamp, Query Time, Fetch Time, Connection, Database, and the statement.
private struct ResultInfo: View {
    @Environment(AppModel.self) private var app
    let model: QueryTabModel
    let result: QueryResult

    var body: some View {
        let execution = model.executions.first { $0.result?.id == result.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        label("Time Stamp"); Text(execution.map { Self.stamp($0.start) } ?? "--")
                        label("Connection"); Text(model.connectionID.flatMap { app.connection(id: $0)?.displayName } ?? "--")
                    }
                    GridRow {
                        label("Query Time"); Text(String(format: "%.3f", result.duration.milliseconds / 1_000))
                        label("Database"); Text(model.databaseName)
                    }
                    GridRow {
                        label("Rows"); Text(result.rows.count.formatted() + (result.isTruncated ? " (more not fetched)" : ""))
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                .font(.system(size: 12))
                Divider()
                Text(SQLSyntax.highlight(result.statement))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// An Explain plan as an always-expanded tree: each step with its cost, rows and conditions.
private struct QueryPlanView: View {
    let nodes: [QueryPlanNode]

    var body: some View {
        let rows = nodes.flatMap { $0.flattened() }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if row.depth > 0 {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: Self.symbol(for: row.node.title))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.node.title)
                                .font(.system(size: 12, weight: .medium))
                            if !row.node.details.isEmpty {
                                Text(row.node.details.map { "\($0.key): \($0.value)" }.joined(separator: "   "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(.leading, 12 + CGFloat(max(row.depth - 1, 0)) * 20 + (row.depth > 0 ? 4 : 0))
                    .padding(.trailing, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }

    /// An SF Symbol for the kind of step.
    private static func symbol(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("join") || t.contains("nested loop") { return "arrow.triangle.merge" }
        if t.contains("sort") || t.contains("order by") || t.contains("b-tree") { return "arrow.up.arrow.down" }
        if t.contains("aggregate") || t.contains("group") { return "sum" }
        if t.contains("index") || t.contains("search") || t.contains("lookup") { return "magnifyingglass" }
        if t.contains("scan") { return "tablecells" }
        if t.contains("hash") { return "number" }
        if t.contains("limit") { return "line.3.horizontal.decrease" }
        if t.contains("subquery") || t.contains("query block") || t.contains("co-routine") || t.contains("cte") || t.contains("union") {
            return "square.stack.3d.up"
        }
        return "smallcircle.filled.circle"
    }
}

/// Past queries on this connection; clicking one loads it into the editor.
private struct HistoryPopover: View {
    @Environment(AppModel.self) private var app
    let connectionID: UUID
    let onSelect: (String) -> Void
    @State private var search = ""

    private var entries: [QueryHistoryEntry] {
        let all = app.history(for: connectionID)
        guard !search.isEmpty else { return all }
        return all.filter { $0.sql.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Clear") { app.clearHistory(for: connectionID) }
                    .disabled(app.history(for: connectionID).isEmpty)
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                Text(search.isEmpty ? "No queries yet" : "No matches")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    Button { onSelect(entry.sql) } label: {
                        HistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 360)
    }
}

private struct HistoryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.sql)
                .font(.callout.monospaced())
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(entry.executedAt, format: .relative(presentation: .named))
                Text(Duration.milliseconds(entry.durationMilliseconds).shortDescription)
                if let rows = entry.rowCount { Text("\(rows) rows") }
                if let error = entry.error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Form View of a query result: one record, field by field, read-only.
private struct QueryResultForm: View {
    let result: QueryResult
    @Binding var row: Int

    var body: some View {
        VStack(spacing: 0) {
            if result.rows.indices.contains(row) {
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                            GridRow {
                                Text(column).font(.system(size: 12, weight: .semibold)).gridColumnAlignment(.trailing)
                                let value = result.rows[row][index]
                                Text(value.isNull ? "(Null)" : value.displayString)
                                    .foregroundStyle(value.isNull ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                    .frame(maxWidth: 420, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No record").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button { row = max(0, row - 1) } label: { Image(systemName: "chevron.up") }.disabled(row <= 0)
                Button { row = min(result.rows.count - 1, row + 1) } label: { Image(systemName: "chevron.down") }.disabled(row >= result.rows.count - 1)
                Text("Record \(min(row + 1, result.rows.count)) of \(result.rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 24)
        }
    }
}

extension View {
    /// Navicat's connection / database popups: a filled rounded field, 160 wide, with ⇕ at the end.
    func popupFieldLabel(width: CGFloat = 160) -> some View {
        HStack(spacing: 4) {
            self.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
}
