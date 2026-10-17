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
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 480)
                }
                WorkspaceView()
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                if app.showAssistant {
                    RightPane()
                        .frame(minWidth: 260, idealWidth: app.assistant.isExpanded ? 560 : 290, maxWidth: app.assistant.isExpanded ? 900 : 520)
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
            ZStack {
                Text(summary)
                HStack {
                    Spacer()
                    paneToggles
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
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
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
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
            let count = context.objects(in: schema, category: app.objectCategory)?.count ?? 0
            return "\(plural(count, app.objectCategory.noun)) in \(place)"
        default:
            return app.connections.isEmpty ? "" : "\(plural(app.connections.count, "Connection")) in My Connections"
        }
    }

    private var segments: some View {
        HStack(spacing: 0) {
            Text(sql)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .textSelection(.enabled)
            section {
                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(warning)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.quaternary)
                }
            }
            section { Text(record).frame(minWidth: 170) }
            section {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(lastRefresh)
                }
                .frame(minWidth: 110)
            }
            paneToggles
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .background(.bar)
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
        case nil: ""
        }
    }

    private var warning: String? {
        switch app.selectedTab {
        case .table(let model): model.transactionError ?? model.error ?? model.saveError ?? model.readOnlyReason
        case .query(let model): model.error
        case .design(let model): model.planError
        case nil: nil
        }
    }

    private var record: String {
        switch app.selectedTab {
        case .table(let model): model.recordDescription
        case .query(let model): model.selectedResult.map { "\($0.rows.count.formatted()) records" } ?? ""
        case .design(let model): model.columns.count == 1 ? "1 field" : "\(model.columns.count) fields"
        case nil: app.currentContext.map { "\($0.objects(in: app.currentSchema, category: app.objectCategory)?.count ?? 0) \(app.objectCategory.rawValue.lowercased())" } ?? ""
        }
    }

    private var lastRefresh: String {
        guard case .table(let model) = app.selectedTab, let date = model.lastRefresh else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "Last Refresh: now" }
        if minutes < 60 { return "Last Refresh: \(minutes)m" }
        return "Last Refresh: \(minutes / 60)h"
    }
}
