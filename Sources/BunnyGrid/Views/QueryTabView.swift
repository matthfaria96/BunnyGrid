import BunnyGridCore
import SwiftUI

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    @State private var showingHistory = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                SQLEditorView(text: $model.text, selectedText: $model.selectedText) { prefix, qualifier in
                    model.completions(prefix: prefix, qualifier: qualifier)
                }
            }
            .frame(minHeight: 120, idealHeight: 260)

            ResultsPane(model: model)
                .frame(minHeight: 120)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: model.run) {
                Label(model.hasSelection ? "Run Selection" : "Run", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning)
            .help("Run (⌘↩). Runs only the selected text when there is a selection.")

            if model.isRunning {
                Button(action: model.cancel) { Label("Stop", systemImage: "stop.fill") }
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text("⎋ or ⌃Space to complete")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button { showingHistory.toggle() } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .help("Query History (⇧⌘Y)")
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                if let connectionID = model.connectionID {
                    HistoryPopover(connectionID: connectionID) { sql in
                        model.text = sql
                        showingHistory = false
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ResultsPane: View {
    @Bindable var model: QueryTabModel

    var body: some View {
        VStack(spacing: 0) {
            if model.results.count > 1 {
                Picker("Result", selection: Binding(
                    get: { model.selectedResult?.id },
                    set: { model.selectedResultID = $0 }
                )) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        Text("Result \(index + 1)").tag(Optional(result.id))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(6)
                Divider()
            }

            if let error = model.error {
                ErrorBanner(message: error)
                    .frame(maxHeight: model.results.isEmpty ? .infinity : 90)
                Divider()
            }
            Group {
                if let result = model.selectedResult {
                    if result.isResultSet {
                        ResultGridView(columns: result.columns, rows: result.rows)
                    } else {
                        Text(result.affectedRows.map { "\($0) row(s) affected" } ?? "Statement executed")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if model.error == nil {
                    Text("Run a query to see results")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack {
            if let result = model.selectedResult {
                if result.isResultSet { Text("\(result.rows.count.formatted()) rows") }
                Text(result.duration.shortDescription)
                Text(result.statement.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let result = model.selectedResult, result.isResultSet {
                ExportMenu(columns: result.columns, rows: result.rows, suggestedName: model.title)
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
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
