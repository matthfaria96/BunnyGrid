import BunnyGridCore
import SwiftUI

/// The fixed "Objects" tab: lists the objects of the selected folder (or the databases of a connection)
/// with Navicat's object toolbar above.
struct ObjectsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    /// The search the list uses: applied a moment after typing stops.
    @State private var appliedSearch = ""
    @State private var searchDebounce: Task<Void, Never>?
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
        return appliedSearch.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(appliedSearch) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Redis has no object toolbar: its tools (Key, Console, Server Monitor) are in the main toolbar.
            if app.currentSession?.config.kind != .redis {
                toolbar
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let noun = context?.kind.isDocumentStore == true && category == .tables ? "Collection" : category.noun
                // Read once: each `selectedObject` filters the folder (thousands of objects on a large schema).
                let selected = selectedObject
                let canOpen = selected != nil && category.objectKind != .routine && category.objectKind != nil
                // Design, New and Import are SQL table tools; a MongoDB collection opens in its own viewer.
                let isTables = category == .tables && context?.kind.isDocumentStore != true
                let writable = context?.driver.config.readOnly == false
                ToolIcon("folder", .blue, "Open \(noun)", isEnabled: canOpen) {
                    if let object = selected { open(object) }
                }
                ToolIcon("pencil", .blue, "Design \(noun)", isEnabled: isTables && selected != nil) {
                    if let object = selected, let context { app.openDesign(table: object, in: context) }
                }
                ToolIcon("plus.circle", .green, "New \(noun)", isEnabled: isTables && writable && context != nil) {
                    if let context { app.openDesign(table: nil, in: context) }
                }
                ToolIcon("minus.circle", .red, "Delete \(noun)",
                         isEnabled: selected != nil && [.tables, .views, .materializedViews].contains(category) && writable) {
                    if let object = selected, let context {
                        app.pendingObjectAction = PendingObjectAction(kind: .drop, object: object, context: context)
                    }
                }
                Divider().frame(height: 18).padding(.horizontal, 6)
                ToolIcon("square.and.arrow.down", .green, "Import Wizard", isEnabled: isTables && writable && selected != nil) {
                    if let object = selected, let context { app.importTarget = ImportTarget(context: context, object: object) }
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
                    .onChange(of: search) { _, value in
                        searchDebounce?.cancel()
                        if value.isEmpty { appliedSearch = value; return }
                        searchDebounce = Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            if !Task.isCancelled { appliedSearch = value }
                        }
                    }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(minWidth: 70, maxWidth: 200, minHeight: 28, maxHeight: 28)
            .glassBackground(in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        if let session = connectionSession {
            let names = session.databases.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            ObjectListTable(
                columns: [ObjectListColumn(title: "Name", width: 260, minWidth: 120), ObjectListColumn(title: "Status", width: 90)],
                rows: names.map { name in
                    let open = session.context(name)?.isOpen == true
                    return ObjectListRow(id: name, icon: open ? "database-open" : "database-closed", cells: [name, open ? "Open" : "Closed"],
                                         dimmed: !open, secondaryColumns: [1])
                },
                selection: $selection,
                onOpen: { ids in
                    selection = ids
                    openSelectedDatabases()
                }
            )
        } else if let context, category == .queries, let connectionID = context.session?.id {
            let queries = app.savedQueries(connectionID: connectionID, database: context.name)
                .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            ObjectListTable(
                columns: [ObjectListColumn(title: "Name", width: 220, minWidth: 120), ObjectListColumn(title: "Modified", width: 160),
                          ObjectListColumn(title: "SQL", width: 400)],
                rows: queries.map { query in
                    ObjectListRow(id: query.id.uuidString, icon: "query",
                                  cells: [query.name, query.updatedAt.formatted(.dateTime.year().month().day().hour().minute()),
                                          query.sql.replacingOccurrences(of: "\n", with: " ")],
                                  secondaryColumns: [1, 2])
                },
                selection: Binding(get: { Set(querySelection.map(\.uuidString)) },
                                   set: { querySelection = Set($0.compactMap(UUID.init(uuidString:))) }),
                onOpen: { ids in openQueries(Set(ids.compactMap(UUID.init(uuidString:))), queries: queries, in: context) }
            )
            .contextMenu {
                if !querySelection.isEmpty {
                    Button("Open Query") { openQueries(querySelection, queries: queries, in: context) }
                    Button("Delete Query", role: .destructive) { for id in querySelection { app.deleteSavedQuery(id) } }
                }
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
                        objectList(context: context)
                    }
                    if objects.isEmpty {
                        Text(search.isEmpty ? "No \(category.rawValue.lowercased())" : "No matches").foregroundStyle(.tertiary)
                    }
                }
                .task(id: "\(context.session?.id.uuidString ?? "")/\(context.name)/\(schema ?? "")/\(category.rawValue)/\(statisticsVersion)") {
                    let driverSchema = context.driverSchema(schema)
                    statistics = (try? await context.driver.tableStatistics(schema: driverSchema)) ?? [:]
                }
            }
        } else if let redis = app.redisSelection {
            // Redis has no object list: keys live in the navigator and open in their own tabs.
            ContentUnavailableView {
                Label("db\(redis.database)", systemImage: "key.horizontal")
            } description: {
                Text("Keys are listed in the navigation pane. Double-click one to open it, or use Key and Console in the toolbar.")
            }
        } else {
            // Nothing selected: an empty list with just its column headers, like Navicat.
            ObjectListTable(columns: ["Name", "Rows", "Data Length", "Engine", "Created Date", "Modified Date"].map {
                ObjectListColumn(title: $0, width: $0 == "Name" ? 200 : 110)
            }, rows: [], selection: .constant([]))
        }
    }

    /// The object list: SQLite shows Name, Root Page, Has Indexes, Has Triggers (as Navicat does); servers show
    /// Rows, Data Length, Engine, dates, Collation and Comment.
    /// Navicat for MongoDB: Documents, Size, Storage Size, Indexes and Avg. Object Size per collection.
    private func collectionList(context: DatabaseContext) -> some View {
        func bytes(_ value: Int?) -> String {
            value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        }
        let columns = [ObjectListColumn(title: "Name", width: 200, minWidth: 120),
                       ObjectListColumn(title: "Documents", width: 90, trailing: true),
                       ObjectListColumn(title: "Size", width: 90, trailing: true),
                       ObjectListColumn(title: "Storage Size", width: 100, trailing: true),
                       ObjectListColumn(title: "Indexes", width: 70, trailing: true),
                       ObjectListColumn(title: "Avg. Object Size", width: 120, trailing: true)]
        let rows = objects.map { object -> ObjectListRow in
            let stats = statistics[object.name]
            return ObjectListRow(id: object.id, icon: object.kind.iconName,
                                 cells: [object.name, stats?.rows.map { $0.formatted() } ?? "", bytes(stats?.sizeBytes),
                                         bytes(stats?.storageBytes), stats?.indexCount.map(String.init) ?? "", bytes(stats?.averageObjectBytes)])
        }
        return ObjectListTable(columns: columns, rows: rows, selection: $selection, onOpen: { ids in
            if let object = objects.first(where: { ids.contains($0.id) }) { open(object) }
        }, autosaveName: "objects-mongodb")
        .contextMenu {
            if let object = selectedObject { ObjectActionItems(object: object, context: context) }
        }
    }

    private func objectList(context: DatabaseContext) -> some View {
        let isSQLite = context.kind == .sqlite
        if context.kind.isDocumentStore { return AnyView(collectionList(context: context)) }
        let columns: [ObjectListColumn] = isSQLite
            ? [ObjectListColumn(title: "Name", width: 190, minWidth: 120), ObjectListColumn(title: "Root Page", width: 95),
               ObjectListColumn(title: "Has Indexes", width: 97), ObjectListColumn(title: "Has Triggers", width: 97),
               ObjectListColumn(title: "Rows", width: 80, trailing: true)]
            : [ObjectListColumn(title: "Name", width: 190, minWidth: 120), ObjectListColumn(title: "Rows", width: 50, trailing: true),
               ObjectListColumn(title: "Data Length", width: 118, trailing: true),
               ObjectListColumn(title: context.kind == .mysql || context.kind == .mariadb ? "Engine" : (context.usesSchemas ? "Schema" : "Database"), width: 78),
               ObjectListColumn(title: "Created Date", width: 148), ObjectListColumn(title: "Modified Date", width: 148),
               ObjectListColumn(title: "Collation", width: 130), ObjectListColumn(title: "Comment", width: 200)]
        let connectionID = context.session?.id
        let rows = objects.map { object -> ObjectListRow in
            let stats = statistics[object.name]
            let cells: [String]
            if isSQLite {
                cells = [object.name, stats?.rootPage.map(String.init) ?? "", stats?.hasIndexes.map { $0 ? "Yes" : "No" } ?? "",
                         stats?.hasTriggers.map { $0 ? "Yes" : "No" } ?? "", stats?.rows.map { $0.formatted() } ?? ""]
            } else {
                cells = [object.name, stats?.rows.map { $0.formatted() } ?? "",
                         stats?.sizeBytes.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : nil } ?? "",
                         stats?.engine ?? object.schema ?? context.name, stats?.created ?? "", stats?.modified ?? "",
                         stats?.collation ?? "", stats?.comment ?? ""]
            }
            let starred = connectionID.map { app.isFavorite(object, connectionID: $0, database: context.name) } ?? false
            return ObjectListRow(id: object.id, icon: object.kind.iconName, cells: cells, starred: starred,
                                 secondaryColumns: isSQLite ? [] : [3, 4, 5, 6, 7])
        }
        return AnyView(ObjectListTable(columns: columns, rows: rows, selection: $selection, onOpen: { ids in
            if let object = objects.first(where: { ids.contains($0.id) }) { open(object) }
        }, autosaveName: "objects-\(context.kind.rawValue)")
        .contextMenu {
            if let object = selectedObject {
                if let connectionID {
                    Button(app.isFavorite(object, connectionID: connectionID, database: context.name) ? "Remove from Favorites" : "Add to Favorites") {
                        app.toggleFavorite(object, connectionID: connectionID, database: context.name)
                    }
                    Divider()
                }
                ObjectActionItems(object: object, context: context)
            }
        }
        )
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
                .frame(width: 26, height: 26)
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
    @State private var selection: Set<String> = []

    private var shown: [Entry] {
        search.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.table.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ObjectListTable(
            columns: [ObjectListColumn(title: "Name", width: 220, minWidth: 120), ObjectListColumn(title: "Table", width: 160),
                      ObjectListColumn(title: category == .indexes ? "Unique" : "Fires", width: 100),
                      ObjectListColumn(title: category == .indexes ? "Fields" : "Events", width: 260)],
            rows: shown.map { ObjectListRow(id: $0.id, icon: category.iconName, cells: [$0.name, $0.table, $0.detail, $0.extra], secondaryColumns: [2, 3]) },
            selection: $selection
        )
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
