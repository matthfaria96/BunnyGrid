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
        }, onTextView: { model.textView = $0 }, onCursorChange: { model.updateCursor(in: $0) })
    }

    private var toolRow: some View {
        HStack(spacing: 2) {
            ToolIconButton(systemImage: "square.and.arrow.down", help: "Save (⌘S)") { app.saveQuery(model) }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "text.alignleft", help: "Beautify SQL") { model.beautify() }
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ToolIconButton(systemImage: "curlybraces", help: "Code Snippet") {
                app.showAssistant = true
                app.rightPane = .snippets
            }
            if showAIFeatures {
                AskAIButton(query: model)
                    .padding(.leading, 4)
            }
            Spacer()
            ToolIconButton(systemImage: "rectangle.split.1x2", help: "Show Result Below Editor", isOn: model.showResultPanel && !model.resultsBesideEditor) {
                model.resultsBesideEditor = false
                model.showResultPanel = true
            }
            ToolIconButton(systemImage: "rectangle.split.2x1", help: "Show Result Next to Editor", isOn: model.showResultPanel && model.resultsBesideEditor) {
                model.resultsBesideEditor = true
                model.showResultPanel = true
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Enter Focus Mode", isOn: app.isFocusMode) {
                app.toggleFocusMode()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var runRow: some View {
        HStack(spacing: 8) {
            ConnectionPicker(model: model)
            DatabasePicker(model: model)
            Spacer(minLength: 8)
            Menu {
                Button("Run") { model.run() }
                Button("Run Selected") { model.run() }.disabled(!model.hasSelection)
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
            .help("Run (⌘↩). Runs only the selected text when there is a selection.")
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                if let connectionID = model.connectionID {
                    HistoryPopover(connectionID: connectionID) { sql in
                        model.text = sql
                        showingHistory = false
                    }
                }
            }
            ToolIconButton(systemImage: "stop.fill", help: "Stop", tint: .red) { model.cancel() }
                .disabled(!model.isRunning)
            ToolIconButton(systemImage: "list.bullet.indent", help: "Explain") { model.explain() }
                .disabled(model.isRunning || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .keyboardShortcut("y", modifiers: [.command, .shift])
    }
}

/// A borderless icon button with a tooltip, tinted when on.
struct ToolIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .accentColor
    var isOn = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isEnabled ? (isOn ? tint : tint.opacity(0.9)) : Color.secondary.opacity(0.5))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? tint.opacity(0.16) : (isHovering ? Color.primary.opacity(0.07) : .clear)))
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
            .frame(width: 150, alignment: .leading)
        }
        .menuStyle(.button)
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
            .frame(width: 150, alignment: .leading)
        }
        .menuStyle(.button)
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
                        tab("Result \(index + 1)", .result(result.id))
                            .help(result.statement)
                    }
                }
                HStack {
                    Spacer()
                    ToolIconButton(systemImage: "chevron.up", help: "Maximize Panel") {
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
                        ResultSetPane(model: model, result: result)
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

/// One result set: Data | Info, Pin and Export on the right, the grid and its footer.
private struct ResultSetPane: View {
    let model: QueryTabModel
    let result: QueryResult
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                subTab("Data", selected: !showInfo) { showInfo = false }
                subTab("Info", selected: showInfo) { showInfo = true }
                Spacer()
                ExportMenu(columns: result.columns, rows: result.rows, suggestedName: model.title)
                    .buttonStyle(.borderless)
                    .help("Export Result")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            if showInfo {
                ResultInfo(model: model, result: result)
            } else {
                ResultGridView(columns: result.columns, rows: result.rows)
                Divider()
                HStack(spacing: 10) {
                    Text(result.statement.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
        }
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
                        label("Rows"); Text(result.rows.count.formatted())
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
