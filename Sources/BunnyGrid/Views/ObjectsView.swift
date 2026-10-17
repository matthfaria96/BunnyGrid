import BunnyGridCore
import SwiftUI

/// The fixed "Objects" tab: lists the objects of the selected folder (or the databases of a connection)
/// with Navicat's object toolbar above.
struct ObjectsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var querySelection: Set<UUID> = []
    @State private var statistics: [String: TableStatistics] = [:]
    @State private var statisticsVersion = 0
    @AppStorage("objectsGridMode") private var gridMode = false

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
    }

    private var selectedObject: DatabaseObject? {
        objects.first { selection.contains($0.id) }
    }

    /// Navicat's icon-only object toolbar: open, design, new, delete | import, export | refresh, then view mode and search.
    private var toolbar: some View {
        HStack(alignment: .center, spacing: 4) {
            if connectionSession != nil {
                ToolIcon("folder", .blue, "Open Database", isEnabled: !selection.isEmpty) { openSelectedDatabases() }
                ToolIcon("plus.circle", .green, "New Database", isEnabled: connectionSession?.config.kind != .sqlite) {
                    app.creatingDatabaseFor = connectionSession?.id
                }
            } else if category == .backups {
                BackupToolbarItems(context: context, schema: schema)
            } else if category == .queries {
                let selected = selectedSavedQuery
                ToolIcon("folder", .blue, "Open Query", isEnabled: selected != nil) {
                    if let selected, let context { app.openSavedQuery(selected, in: context) }
                }
                ToolIcon("plus.circle", .green, "New Query", isEnabled: context != nil) { app.openQuery(in: context) }
                ToolIcon("minus.circle", .red, "Delete Query", isEnabled: selected != nil) {
                    for id in querySelection { app.deleteSavedQuery(id) }
                    querySelection = []
                }
            } else {
                let noun = category.noun
                let canOpen = selectedObject != nil && category.objectKind != .routine && category.objectKind != nil
                let isTables = category == .tables
                let writable = context?.driver.config.readOnly == false
                ToolIcon("folder", .blue, "Open \(noun)", isEnabled: canOpen) {
                    if let object = selectedObject { open(object) }
                }
                ToolIcon("pencil", .blue, "Design \(noun)", isEnabled: isTables && selectedObject != nil) {
                    if let object = selectedObject, let context { app.openDesign(table: object, in: context) }
                }
                ToolIcon("plus.circle", .green, "New \(noun)", isEnabled: isTables && writable && context != nil) {
                    if let context { app.openDesign(table: nil, in: context) }
                }
                ToolIcon("minus.circle", .red, "Delete \(noun)",
                         isEnabled: selectedObject != nil && [.tables, .views, .materializedViews].contains(category) && writable) {
                    if let object = selectedObject, let context {
                        app.pendingObjectAction = PendingObjectAction(kind: .drop, object: object, context: context)
                    }
                }
                Divider().frame(height: 18).padding(.horizontal, 6)
                ToolIcon("square.and.arrow.down", .green, "Import Wizard", isEnabled: isTables && writable && selectedObject != nil) {
                    if let object = selectedObject, let context { app.importTarget = ImportTarget(context: context, object: object) }
                }
                ToolIcon("square.and.arrow.up", .orange, "Export Wizard", isEnabled: context != nil && [.tables, .views, .materializedViews].contains(category)) {
                    if let context {
                        let chosen = objects.filter { selection.contains($0.id) }
                        app.exportTarget = ExportTarget(context: context, objects: chosen.isEmpty ? objects : chosen)
                    }
                }
            }
            Divider().frame(height: 18).padding(.horizontal, 6)
            ToolIcon("arrow.clockwise", .secondary, "Refresh", isEnabled: context != nil || connectionSession != nil) {
                Task {
                    if let session = connectionSession { await session.refreshDatabases() }
                    if let context { await context.loadObjects(schema: schema, force: true) }
                    statisticsVersion += 1
                }
            }
            Spacer()
            ToolIcon("list.bullet", gridMode ? .secondary : .accentColor, "List", isEnabled: true) { gridMode = false }
            ToolIcon("square.grid.3x3", gridMode ? .accentColor : .secondary, "Grid", isEnabled: true) { gridMode = true }
            Divider().frame(height: 18).padding(.horizontal, 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(width: 200, height: 28)
            .glassBackground(in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        if let session = connectionSession {
            Table(session.databases.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.map(DatabaseRow.init), selection: $selection) {
                TableColumn("Name") { row in
                    Label {
                        Text(row.name).foregroundStyle(session.context(row.name)?.isOpen == true ? .primary : .secondary)
                    } icon: {
                        AppIcon(name: session.context(row.name)?.isOpen == true ? "database-open" : "database-closed", size: 16)
                    }
                }
                TableColumn("Status") { row in
                    Text(session.context(row.name)?.isOpen == true ? "Open" : "Closed").foregroundStyle(.secondary)
                }
                .width(90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
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
                        AppIcon(name: "query", size: 16)
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
            .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
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
        } else if let context, category == .indexes || category == .triggers {
            IndexTriggerList(context: context, category: category, search: search)
        } else if let context {
            if category == .backups {
                BackupListView(context: context, schema: schema, search: search)
            } else if category.objectKind == nil {
                ContentUnavailableView("No \(category.rawValue)", systemImage: category.systemImage)
            } else if context.objects(in: schema) == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await context.loadObjects(schema: schema) }
            } else {
                ZStack {
                if gridMode {
                    ObjectTiles(objects: objects, selection: $selection, tint: category.tint) { open($0) }
                } else {
                // Statistics travel inside the row values: SwiftUI's Table doesn't redraw cells for outside state.
                if context.kind == .sqlite {
                    sqliteTable(context: context, objects: objects)
                } else {
                Table(objects.map { ObjectRow(object: $0, stats: statistics[$0.name]) }, selection: $selection) {
                    TableColumn("Name") { row in
                        let object = row.object
                        Label {
                            Text(object.name)
                            if let connectionID = context.session?.id, app.isFavorite(object, connectionID: connectionID, database: context.name) {
                                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                            }
                        } icon: {
                            AppIcon(name: object.kind.iconName, size: 16)
                        }
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn("Rows") { row in
                        Text(row.stats?.rows.map { $0.formatted() } ?? "")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 90)
                    TableColumn("Data Length") { row in
                        Text(row.stats?.sizeBytes.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : nil } ?? "")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn(context.kind == .mysql || context.kind == .mariadb ? "Engine" : (context.usesSchemas ? "Schema" : "Database")) { row in
                        Text(row.stats?.engine ?? row.object.schema ?? context.name).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 110)
                    TableColumn("Created Date") { row in
                        Text(row.stats?.created ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 90, ideal: 140)
                    TableColumn("Modified Date") { row in
                        Text(row.stats?.modified ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 90, ideal: 140)
                    TableColumn("Collation") { row in
                        Text(row.stats?.collation ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 80, ideal: 130)
                    TableColumn("Comment") { row in
                        Text(row.stats?.comment ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
                .task(id: "\(context.session?.id.uuidString ?? "")/\(context.name)/\(schema ?? "")/\(category.rawValue)/\(statisticsVersion)") {
                    statistics = (try? await context.driver.tableStatistics(schema: context.usesSchemas ? schema : (context.kind == .sqlite ? nil : context.name))) ?? [:]
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let object = objects.first(where: { ids.contains($0.id) }), let connectionID = context.session?.id {
                        Button(app.isFavorite(object, connectionID: connectionID, database: context.name) ? "Remove from Favorites" : "Add to Favorites") {
                            app.toggleFavorite(object, connectionID: connectionID, database: context.name)
                        }
                        Divider()
                        ObjectActionItems(object: object, context: context)
                    }
                } primaryAction: { ids in
                    if let object = objects.first(where: { ids.contains($0.id) }) { open(object) }
                }
                }
                }
                if objects.isEmpty {
                    Text(search.isEmpty ? "No \(category.rawValue.lowercased())" : "No matches").foregroundStyle(.tertiary)
                }
                }
            }
        } else {
            // Nothing selected: an empty list with just its column headers, like Navicat.
            Table([DatabaseRow]()) {
                TableColumn("Name") { Text($0.name) }
                TableColumn("Rows") { _ in Text("") }
                TableColumn("Data Length") { _ in Text("") }
                TableColumn("Engine") { _ in Text("") }
                TableColumn("Created Date") { _ in Text("") }
                TableColumn("Modified Date") { _ in Text("") }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
        }
    }

    /// SQLite's columns in Navicat: Name, Root Page, Has Indexes, Has Triggers.
    private func sqliteTable(context: DatabaseContext, objects: [DatabaseObject]) -> some View {
        Table(objects.map { ObjectRow(object: $0, stats: statistics[$0.name]) }, selection: $selection) {
            TableColumn("Name") { row in
                Label {
                    Text(row.object.name)
                } icon: {
                    AppIcon(name: row.object.kind.iconName, size: 16)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Root Page") { row in
                Text(row.stats?.rootPage.map(String.init) ?? "").monospacedDigit()
            }
            .width(min: 70, ideal: 100)
            TableColumn("Has Indexes") { row in
                Text(row.stats?.hasIndexes.map { $0 ? "Yes" : "No" } ?? "")
            }
            .width(min: 70, ideal: 100)
            TableColumn("Has Triggers") { row in
                Text(row.stats?.hasTriggers.map { $0 ? "Yes" : "No" } ?? "")
            }
            .width(min: 70, ideal: 100)
            TableColumn("Rows") { row in
                Text(row.stats?.rows.map { $0.formatted() } ?? "").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
        .task(id: "\(context.session?.id.uuidString ?? "")/\(context.name)/\(category.rawValue)/\(statisticsVersion)") {
            statistics = (try? await context.driver.tableStatistics(schema: nil)) ?? [:]
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let object = objects.first(where: { ids.contains($0.id) }) {
                ObjectActionItems(object: object, context: context)
            }
        } primaryAction: { ids in
            if let object = objects.first(where: { ids.contains($0.id) }) { open(object) }
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
}

/// Small icon button of the Objects toolbar.
private struct ToolIcon: View {
    let systemImage: String
    let tint: Color
    let help: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    init(_ systemImage: String, _ tint: Color, _ help: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tint = tint
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Grid view of the Objects tab: one tile per object.
private struct ObjectTiles: View {
    let objects: [DatabaseObject]
    @Binding var selection: Set<String>
    let tint: Color
    let open: (DatabaseObject) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(objects) { object in
                    let isSelected = selection.contains(object.id)
                    VStack(spacing: 6) {
                        AppIcon(name: object.kind.iconName, size: 46)
                        Text(object.name)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.accentColor : .clear))
                    }
                    .frame(width: 100, height: 92)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(object) }
                    .simultaneousGesture(TapGesture().onEnded { selection = [object.id] })
                }
            }
            .padding(12)
        }
    }
}

private struct ObjectRow: Identifiable {
    let object: DatabaseObject
    let stats: TableStatistics?
    var id: String { object.id }
}

private struct DatabaseRow: Identifiable {
    let name: String
    var id: String { name }
}

/// SQLite's Index and Trigger buttons: every index or trigger in the database, with its table.
private struct IndexTriggerList: View {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let table: String
        let detail: String
        let extra: String
    }

    @Environment(AppModel.self) private var app
    let context: DatabaseContext
    let category: ObjectCategory
    let search: String
    @State private var entries: [Entry] = []
    @State private var loaded = false

    private var shown: [Entry] {
        search.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.table.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Table(shown) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    AppIcon(name: category.iconName, size: 16)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Table") { entry in Text(entry.table) }
                .width(min: 100, ideal: 160)
            TableColumn(category == .indexes ? "Unique" : "Fires") { entry in Text(entry.detail).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100)
            TableColumn(category == .indexes ? "Fields" : "Events") { entry in Text(entry.extra).foregroundStyle(.secondary).lineLimit(1) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false)).environment(\.defaultMinListRowHeight, 19)
        .overlay {
            if loaded && shown.isEmpty {
                Text(search.isEmpty ? "No \(category.rawValue.lowercased())" : "No matches").foregroundStyle(.tertiary)
            } else if !loaded {
                ProgressView()
            }
        }
        .task(id: "\(context.name)/\(category.rawValue)") { await load() }
    }

    private func load() async {
        loaded = false
        var result: [Entry] = []
        let tables = (context.objects(in: context.defaultSchema) ?? []).filter { $0.kind == .table }
        for table in tables {
            let schema = context.driverSchema(table.schema)
            if category == .indexes {
                for index in (try? await context.driver.listIndexes(table: table.name, schema: schema)) ?? [] where !index.primary {
                    result.append(Entry(id: "\(table.name).\(index.name)", name: index.name, table: table.name,
                                        detail: index.unique ? "Yes" : "No", extra: index.columns.joined(separator: ", ")))
                }
            } else {
                for trigger in (try? await context.driver.listTriggers(table: table.name, schema: schema)) ?? [] {
                    result.append(Entry(id: "\(table.name).\(trigger.name)", name: trigger.name, table: table.name,
                                        detail: trigger.timing, extra: trigger.events.joined(separator: ", ")))
                }
            }
        }
        entries = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        app.listedItemCount = entries.count
        loaded = true
    }
}
