import AppKit
import BunnyGridCore
import SwiftUI

/// Main window, laid out like Navicat: big toolbar, then Navigation | tabs | AI Assistant, then the status bar.
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            MainToolbar()
            Divider()
            HSplitView {
                if app.showNavigator {
                    NavigatorView()
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 480)
                }
                WorkspaceView()
                    .frame(minWidth: 360, maxWidth: .infinity)
                    .layoutPriority(1)
                if app.showAssistant {
                    RightPane()
                        .frame(minWidth: app.assistant.isExpanded ? 560 : 345, idealWidth: app.assistant.isExpanded ? 560 : 345, maxWidth: app.assistant.isExpanded ? 900 : 600)
                }
            }
            Divider()
            StatusBar()
        }
        // The chrome draws its own title row beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(app.windowTitle)
        .sheet(item: $app.draft) { draft in
            ConnectionEditorView(draft: draft)
        }
        .sheet(isPresented: $app.showingConnectionPicker) {
            NewConnectionSheet()
        }
        .sheet(item: $app.namingQuery) { tab in
            SaveQuerySheet(tab: tab)
        }
        .sheet(item: $app.importTarget) { target in
            ImportWizardView(target: target)
        }
        .sheet(item: $app.generationTarget) { target in
            DataGenerationView(target: target)
        }
        .sheet(item: $app.exportTarget) { target in
            ExportWizardView(target: target)
        }
        .sheet(item: $app.sqlFileTarget) { target in
            ExecuteSQLFileView(target: target)
        }
        .sheet(item: $app.syncWizard) { request in
            SyncWizardView(request: request)
        }
        .sheet(item: $app.usersSession) { session in
            UsersView(session: session)
        }
        .modifier(ObjectActionAlert())
        .modifier(BackupSheets())
        .alert("BunnyGrid", isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("--settings") { openSettings() }
            // `--window-size 1037x695` matches the window to a reference capture.
            if let index = CommandLine.arguments.firstIndex(of: "--window-size"), CommandLine.arguments.indices.contains(index + 1) {
                let parts = CommandLine.arguments[index + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    var frame = window.frame
                    frame.origin.y += frame.height - parts[1]
                    frame.size = CGSize(width: parts[0], height: parts[1])
                    window.setFrame(frame, display: true)
                }
            }
        }
        #endif
    }
}

/// Bottom bar: the tab's SQL, a warning marker, the record position, the last refresh, and pane toggles.
struct StatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.selectedTab == nil {
            // Objects tab: a single centered summary, as Navicat shows it.
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(.bar)
        } else {
            segments
        }
    }

    private var paneToggles: some View {
        HStack(spacing: 2) {
            IconButton(systemImage: "sidebar.left", help: "Show/Hide Navigation Pane", isOn: app.showNavigator) {
                app.showNavigator.toggle()
            }
            IconButton(systemImage: "sidebar.right", help: "Show/Hide Information Pane", isOn: app.showAssistant) {
                app.showAssistant.toggle()
            }
        }
        .padding(.horizontal, 6)
    }

    /// "1 Connection in My Connections", "2 Tables in main", …
    private var summary: String {
        func plural(_ count: Int, _ noun: String) -> String {
            guard count != 1 else { return "1 \(noun)" }
            return "\(count) " + (noun.hasSuffix("x") || noun.hasSuffix("s") ? noun + "es" : noun.hasSuffix("y") ? String(noun.dropLast()) + "ies" : noun + "s")
        }
        switch app.navSelection {
        case .group(let group):
            return "\(plural(app.connections.filter { $0.group == group }.count, "Connection")) in \(group)"
        case .connection(let id):
            if let session = app.sessions[id], session.isConnected {
                return "\(plural(session.databases.count, "Database")) in \(session.config.displayName)"
            }
            return "\(plural(app.connections.count, "Connection")) in My Connections"
        case .database(let id, let db), .schema(let id, let db, _), .category(let id, let db, _, _), .object(let id, let db, _), .savedQuery(let id, let db, _):
            guard let context = app.sessions[id]?.context(db) else { return "" }
            let schema = context.usesSchemas ? app.currentSchema : nil
            let place = schema.map { "\(db).\($0)" } ?? db
            if app.objectCategory == .queries {
                return "\(plural(app.savedQueries(connectionID: id, database: db).count, "Query")) in \(place)"
            }
            let count = [.indexes, .triggers, .backups].contains(app.objectCategory)
                ? app.listedItemCount
                : context.objects(in: schema, category: app.objectCategory)?.count ?? 0
            // Navicat: "2 tables".
            return place.isEmpty ? "" : plural(count, app.objectCategory.noun).lowercased()
        default:
            return app.connections.isEmpty ? "" : "\(plural(app.connections.count, "Connection")) in My Connections"
        }
    }

    /// Centered "a | b | c" like Navicat's status bar, with a warning icon when something failed.
    private var segments: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text("|").foregroundStyle(.secondary) }
                    Text(part).lineLimit(1)
                }
                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(warning)
                }
            }
        }
        .padding(.horizontal, 12)
        .font(.system(size: 12))
        .foregroundStyle(.primary.opacity(0.85))
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(.bar)
    }

    private var parts: [String] {
        switch app.selectedTab {
        case .table(let model):
            return [model.recordDescription, lastRefresh].filter { !$0.isEmpty }
        case .query(let model):
            var parts: [String] = []
            if let elapsed = model.elapsed { parts.append(String(format: "Elapsed Time: %.3fs", elapsed.milliseconds / 1_000)) }
            if case .result(let id) = model.resultPane, let result = model.resultSets.first(where: { $0.id == id }) {
                parts.append("\(result.rows.count.formatted()) records")
            }
            parts.append("Line: \(model.cursorLine)  Col: \(model.cursorColumn)")
            return parts
        case .design(let model):
            return ["Number of Fields: \(model.columns.count)"]
        case .model(let model):
            return [model.summary]
        case .redis(let model): return [model.statusText].filter { !$0.isEmpty }
        case .document(let tab):
            return [tab.recordText]
        case .automation, nil:
            return []
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Divider().frame(height: 14)
            content().padding(.horizontal, 10)
        }
    }

    private var sql: String {
        switch app.selectedTab {
        case .table(let model): model.lastSQL
        case .query(let model): model.lastSQL
        case .design(let model): model.statements.joined(separator: "; ")
        case .model: ""
        case .redis: ""
        case .document(let tab): tab.lastStatement
        case .automation, nil: ""
        }
    }

    private var warning: String? {
        switch app.selectedTab {
        case .table(let model): model.transactionError ?? model.error ?? model.saveError ?? model.readOnlyReason
        case .query(let model): model.error
        case .design(let model): model.planError
        case .model(let model): model.error
        case .redis(let model): model.error
        case .document(let tab): tab.warning
        case .automation, nil: nil
        }
    }

    private var record: String {
        switch app.selectedTab {
        case .table(let model): model.recordDescription
        case .query(let model): model.selectedResult.map { "\($0.rows.count.formatted()) records" } ?? ""
        case .design(let model): model.columns.count == 1 ? "1 field" : "\(model.columns.count) fields"
        case .model(let model): model.summary
        case .redis(let model): model.statusText
        case .document(let tab): tab.recordText
        case .automation: "\(app.automation.jobs.count) batch jobs"
        case nil: app.currentContext.map { "\($0.objects(in: app.currentSchema, category: app.objectCategory)?.count ?? 0) \(app.objectCategory.rawValue.lowercased())" } ?? ""
        }
    }

    private var lastRefresh: String {
        guard case .table(let model) = app.selectedTab, let date = model.lastRefresh else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "Last Refresh: <1m" }
        if minutes < 60 { return "Last Refresh: \(minutes)m" }
        return "Last Refresh: \(minutes / 60)h"
    }
}
