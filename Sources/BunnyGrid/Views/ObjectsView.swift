import BunnyGridCore
import SwiftUI

/// The fixed "Objects" tab: lists the objects of the selected folder (or the databases of a connection)
/// with Navicat's object toolbar above.
struct ObjectsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var pendingDrop: DatabaseObject?
    @State private var querySelection: Set<UUID> = []

    private var context: DatabaseContext? { app.currentContext }
    private var schema: String? { context?.usesSchemas == true ? app.currentSchema : nil }
    private var category: ObjectCategory { app.objectCategory }

    /// A selected connection (without a database) lists its databases instead of objects.
    private var connectionSession: Session? {
        if case .connection(let id) = app.navSelection { return app.sessions[id] }
        return nil
    }

    private var objects: [DatabaseObject] {
        guard let context else { return [] }
        let all = context.objects(in: schema, category: category) ?? []
        return search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .confirmationDialog(
            "Delete \(pendingDrop.map { "“\($0.name)”" } ?? "")? This permanently drops it from the database.",
            isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let object = pendingDrop { drop(object) }
                pendingDrop = nil
            }
        }
    }

    private var selectedObject: DatabaseObject? {
        objects.first { selection.contains($0.id) }
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            if connectionSession != nil {
                ToolbarChip(title: "Open Database", systemImage: "cylinder.fill", tint: .green, isEnabled: !selection.isEmpty) {
                    openSelectedDatabases()
                }
                ToolbarChip(title: "New Database", systemImage: "plus.circle", tint: .green, isEnabled: false) {}
            } else if category == .queries {
                let selected = selectedSavedQuery
                ToolbarChip(title: "Open Query", systemImage: "arrow.up.forward.square", tint: .orange, isEnabled: selected != nil) {
                    if let selected, let context { app.openSavedQuery(selected, in: context) }
                }
                ToolbarChip(title: "New Query", systemImage: "plus.square", tint: .orange, isEnabled: context != nil) {
                    app.openQuery(in: context)
                }
                ToolbarChip(title: "Delete Query", systemImage: "minus.square", tint: .red, isEnabled: selected != nil) {
                    for id in querySelection { app.deleteSavedQuery(id) }
                    querySelection = []
                }
            } else {
                let noun = category.noun
                let canOpen = selectedObject != nil && category.objectKind != .routine && category.objectKind != nil
                ToolbarChip(title: "Open \(noun)", systemImage: "arrow.up.forward.square", tint: .blue, isEnabled: canOpen) {
                    if let object = selectedObject { open(object) }
                }
                let isTables = category == .tables
                let writable = context?.driver.config.readOnly == false
                ToolbarChip(title: "Design \(noun)", systemImage: "pencil.and.ruler", tint: .blue, isEnabled: isTables && selectedObject != nil) {
                    if let object = selectedObject, let context { app.openDesign(table: object, in: context) }
                }
                ToolbarChip(title: "New \(noun)", systemImage: "plus.square", tint: .green, isEnabled: isTables && writable && context != nil) {
                    if let context { app.openDesign(table: nil, in: context) }
                }
                ToolbarChip(title: "Delete \(noun)", systemImage: "minus.square", tint: .red,
                            isEnabled: selectedObject != nil && [.tables, .views, .materializedViews].contains(category) && context?.driver.config.readOnly == false) {
                    pendingDrop = selectedObject
                }
                Divider().frame(height: 16)
                ToolbarChip(title: "Import Wizard", systemImage: "square.and.arrow.down", tint: .teal,
                            isEnabled: isTables && writable && selectedObject != nil) {
                    if let object = selectedObject, let context { app.importTarget = ImportTarget(context: context, object: object) }
                }
                ToolbarChip(title: "Export Wizard", systemImage: "square.and.arrow.up", tint: .teal, isEnabled: false) {}
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: 180)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let session = connectionSession {
            Table(session.databases.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.map(DatabaseRow.init), selection: $selection) {
                TableColumn("Name") { row in
                    Label(row.name, systemImage: "cylinder.fill")
                        .foregroundStyle(session.context(row.name)?.isOpen == true ? .primary : .secondary)
                }
                TableColumn("Status") { row in
                    Text(session.context(row.name)?.isOpen == true ? "Open" : "Closed").foregroundStyle(.secondary)
                }
                .width(90)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                selection = ids
                openSelectedDatabases()
            }
        } else if let context, category == .queries, let connectionID = context.session?.id {
            let queries = app.savedQueries(connectionID: connectionID, database: context.name)
                .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            Table(queries, selection: $querySelection) {
                TableColumn("Name") { query in
                    Label {
                        Text(query.name)
                    } icon: {
                        Image(systemName: "doc.text").foregroundStyle(.orange)
                    }
                }
                TableColumn("Modified") { query in
                    Text(query.updatedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 160)
                TableColumn("SQL") { query in
                    Text(query.sql.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Open Query") { openQueries(ids, queries: queries, in: context) }
                Button("Delete Query", role: .destructive) { for id in ids { app.deleteSavedQuery(id) } }
            } primaryAction: { ids in
                openQueries(ids, queries: queries, in: context)
            }
            .overlay {
                if queries.isEmpty {
                    Text("No saved queries. Write one in New Query and press ⌘S.").foregroundStyle(.tertiary)
                }
            }
        } else if let context {
            if category.objectKind == nil {
                ContentUnavailableView("No \(category.rawValue)", systemImage: category.systemImage, description: Text("Backups are coming soon."))
            } else if context.objects(in: schema) == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await context.loadObjects(schema: schema) }
            } else {
                Table(objects, selection: $selection) {
                    TableColumn("Name") { object in
                        Label {
                            Text(object.name)
                        } icon: {
                            Image(systemName: object.kind.systemImage).foregroundStyle(category.tint)
                        }
                    }
                    TableColumn(context.usesSchemas ? "Schema" : "Database") { object in
                        Text(object.schema ?? context.name).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 140)
                    TableColumn("Type") { object in
                        Text(category.noun).foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 120)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let object = objects.first(where: { ids.contains($0.id) }), let connectionID = context.session?.id {
                        Button(app.isFavorite(object, connectionID: connectionID, database: context.name) ? "Remove from Favorites" : "Add to Favorites") {
                            app.toggleFavorite(object, connectionID: connectionID, database: context.name)
                        }
                        if object.kind == .table {
                            Button("Design Table") { app.openDesign(table: object, in: context) }
                        }
                        Divider()
                    }
                    if let object = objects.first(where: { ids.contains($0.id) }), object.kind != .routine {
                        Button("Open \(category.noun)") { open(object) }
                        Button("Select Top 100 in New Query") {
                            app.openQuery(text: context.driver.dialect.selectPage(table: object.name, schema: object.schema, offset: 0, limit: 100) + ";", in: context)
                        }
                    }
                } primaryAction: { ids in
                    if let object = objects.first(where: { ids.contains($0.id) }) { open(object) }
                }
                .overlay {
                    if objects.isEmpty {
                        Text(search.isEmpty ? "No \(category.rawValue.lowercased())" : "No matches").foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            Color(nsColor: .controlBackgroundColor)
                .overlay {
                    Text(app.connections.isEmpty ? "Create a connection with the Connection button." : "Open a connection in the navigator.")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var selectedSavedQuery: SavedQuery? {
        app.savedQueries.first { querySelection.contains($0.id) }
    }

    private func openQueries(_ ids: Set<UUID>, queries: [SavedQuery], in context: DatabaseContext) {
        for query in queries where ids.contains(query.id) { app.openSavedQuery(query, in: context) }
    }

    private func open(_ object: DatabaseObject) {
        guard object.kind != .routine, let context else { return }
        app.openTable(object, in: context)
    }

    private func openSelectedDatabases() {
        guard let session = connectionSession else { return }
        for name in selection {
            app.setExpanded(.database(session.id, name), true)
        }
        if let first = selection.first { app.select(.database(session.id, first)) }
    }

    private func drop(_ object: DatabaseObject) {
        guard let context else { return }
        let keyword = switch object.kind {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED VIEW"
        default: "TABLE"
        }
        let sql = "DROP \(keyword) \(context.driver.dialect.qualifiedName(object))"
        Task {
            do {
                _ = try await context.driver.executeTimed(sql)
                for tab in app.tabs where tab.tableObject == object { app.closeTab(tab.id) }
                await context.loadObjects(schema: schema, force: true)
            } catch {
                app.alertMessage = error.localizedDescription
            }
        }
    }
}

private struct DatabaseRow: Identifiable {
    let name: String
    var id: String { name }
}
