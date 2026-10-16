import AppKit
import BunnyGridCore
import SwiftUI

/// One visible line of the navigator tree.
private struct NavRow: Identifiable {
    let node: NavNode
    let depth: Int
    let title: String
    var subtitle: String?
    let icon: String
    var iconColor: Color = .secondary
    var isExpandable = false
    var isExpanded = false
    var isLoading = false
    var warning: String?
    var isDisabled = false
    var isFavorite = false

    var id: NavNode { node }
}

/// The left pane: Cloud, My Connections → groups → connections → databases → schemas → object folders → objects,
/// with the search bar at the bottom, as in Navicat's Navigation pane.
struct NavigatorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { app.navSelection }, set: { app.select($0) })) {
                ForEach(rows) { row in
                    NavRowView(row: row)
                        .tag(row.node)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6))
                        .selectionDisabled(row.isDisabled)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)

            Divider()
            NavigatorSearchBar()
        }
    }

    // MARK: - Tree

    private var rows: [NavRow] {
        var rows: [NavRow] = []
        let filter = app.navigatorFilter.trimmingCharacters(in: .whitespaces)

        rows.append(NavRow(node: .cloud, depth: 0, title: "BunnyGrid Cloud", icon: "cloud.fill", iconColor: .blue,
                           isExpandable: true, isExpanded: app.expanded.contains(.cloud)))
        if app.expanded.contains(.cloud) {
            rows.append(NavRow(node: .cloudInfo, depth: 1, title: "Sync is coming soon", icon: "icloud.slash",
                               iconColor: .secondary, isDisabled: true))
        }

        rows.append(NavRow(node: .myConnections, depth: 0, title: "My Connections", icon: "powerplug.portrait.fill", iconColor: .green,
                           isExpandable: true, isExpanded: app.expanded.contains(.myConnections)))
        guard app.expanded.contains(.myConnections) else { return rows }

        for group in app.groups {
            let node = NavNode.group(group)
            rows.append(NavRow(node: node, depth: 1, title: group, icon: "folder.fill", iconColor: .yellow,
                               isExpandable: true, isExpanded: app.expanded.contains(node)))
            if app.expanded.contains(node) {
                for config in app.connections where config.group == group {
                    appendConnection(config, depth: 2, filter: filter, to: &rows)
                }
            }
        }
        for config in app.connections where config.group == nil {
            appendConnection(config, depth: 1, filter: filter, to: &rows)
        }
        return rows
    }

    private func appendConnection(_ config: ConnectionConfig, depth: Int, filter: String, to rows: inout [NavRow]) {
        let node = NavNode.connection(config.id)
        let session = app.sessions[config.id]
        let isOpen = session?.isConnected == true
        var row = NavRow(node: node, depth: depth, title: config.displayName, icon: config.kind.systemImage,
                         iconColor: isOpen ? (config.color.swiftUIColor ?? config.kind.tint) : .secondary,
                         isExpandable: true, isExpanded: app.expanded.contains(node))
        if case .failed(let message) = session?.state { row.warning = message }
        row.isLoading = session?.state == .connecting
        rows.append(row)
        guard row.isExpanded, let session, session.isConnected else { return }

        for database in session.databases {
            let dbNode = NavNode.database(config.id, database)
            let context = session.context(database)
            var dbRow = NavRow(node: dbNode, depth: depth + 1, title: database, icon: "cylinder.fill",
                               iconColor: context?.isOpen == true ? .green : .secondary,
                               isExpandable: true, isExpanded: app.expanded.contains(dbNode))
            dbRow.isLoading = context?.state == .opening
            if case .failed(let message) = context?.state { dbRow.warning = message }
            rows.append(dbRow)
            guard dbRow.isExpanded, let context, context.isOpen else { continue }

            if context.usesSchemas {
                for schema in context.schemas {
                    let schemaNode = NavNode.schema(config.id, database, schema)
                    let schemaRow = NavRow(node: schemaNode, depth: depth + 2, title: schema, icon: "square.stack.3d.up.fill",
                                           iconColor: context.objects(in: schema) != nil ? .teal : .secondary,
                                           isExpandable: true, isExpanded: app.expanded.contains(schemaNode))
                    rows.append(schemaRow)
                    if schemaRow.isExpanded {
                        appendCategories(context: context, schema: schema, depth: depth + 3, filter: filter, to: &rows)
                    }
                }
            } else {
                appendCategories(context: context, schema: nil, depth: depth + 2, filter: filter, to: &rows)
            }
        }
    }

    private func appendCategories(context: DatabaseContext, schema: String?, depth: Int, filter: String, to rows: inout [NavRow]) {
        guard let id = context.session?.id else { return }
        let filtering = !filter.isEmpty || app.favoritesOnly
        for category in ObjectCategory.categories(for: context.kind) {
            let node = NavNode.category(id, context.name, schema, category)
            let isExpanded = app.expanded.contains(node) || (filtering && category.objectKind != nil)
            var row = NavRow(node: node, depth: depth, title: category.rawValue, icon: category.systemImage,
                             iconColor: category.tint, isExpandable: true, isExpanded: isExpanded)
            let objects = context.objects(in: schema, category: category)
            row.isLoading = objects == nil && isExpanded
            rows.append(row)
            guard isExpanded else { continue }
            if category == .queries {
                for saved in app.savedQueries(connectionID: id, database: context.name)
                where filter.isEmpty || saved.name.localizedCaseInsensitiveContains(filter) {
                    rows.append(NavRow(node: .savedQuery(id, context.name, saved.id), depth: depth + 1, title: saved.name,
                                       icon: "doc.text", iconColor: category.tint))
                }
                continue
            }
            guard let objects else { continue }
            for object in objects where filter.isEmpty || object.name.localizedCaseInsensitiveContains(filter) {
                let favorite = app.isFavorite(object, connectionID: id, database: context.name)
                if app.favoritesOnly && !favorite { continue }
                var objectRow = NavRow(node: .object(id, context.name, object), depth: depth + 1, title: object.name,
                                       icon: object.kind.systemImage, iconColor: category.tint)
                objectRow.isFavorite = favorite
                rows.append(objectRow)
            }
        }
    }
}

private struct NavRowView: View {
    @Environment(AppModel.self) private var app
    let row: NavRow

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if row.isExpandable {
                    Button {
                        app.setExpanded(row.node, !row.isExpanded)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
            }
            Image(systemName: row.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(row.iconColor)
                .frame(width: 18)
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(row.isDisabled ? .secondary : .primary)
            if let subtitle = row.subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if row.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
            }
            if row.isLoading {
                ProgressView().controlSize(.mini)
            } else if let warning = row.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(warning)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { app.activate(row.node) })
        .contextMenu { NavContextMenu(node: row.node) }
    }
}

private struct NavContextMenu: View {
    @Environment(AppModel.self) private var app
    let node: NavNode

    var body: some View {
        switch node {
        case .connection(let id):
            if app.sessions[id]?.isConnected == true {
                Button("Close Connection") { app.disconnect(id) }
                Button("New Query") { app.openQuery(in: app.sessions[id]?.contexts.values.first) }
                Button("Refresh") { Task { await app.sessions[id]?.refreshDatabases() } }
            } else {
                Button("Open Connection") { app.setExpanded(node, true) }
            }
            Divider()
            Button("Edit Connection…") { app.edit(id) }
            Button("Duplicate Connection") { app.duplicate(id) }
            Divider()
            Button("Delete Connection", role: .destructive) { app.delete(id) }
        case .database(let id, let db):
            if let context = app.sessions[id]?.context(db), context.isOpen {
                Button("Close Database") {
                    app.expanded.remove(node)
                    app.sessions[id]?.closeDatabase(db)
                }
                Button("New Query") { app.openQuery(in: context) }
                Button("Refresh") { Task { await context.refresh() } }
            } else {
                Button("Open Database") { app.setExpanded(node, true) }
            }
        case .schema(let id, let db, let schema):
            Button("New Query") { app.openQuery(in: app.sessions[id]?.context(db)) }
            Button("Refresh") { Task { await app.sessions[id]?.context(db)?.loadObjects(schema: schema, force: true) } }
        case .category(let id, let db, let schema, let category):
            if category == .tables, let context = app.sessions[id]?.context(db), !context.driver.config.readOnly {
                Button("New Table") { app.openDesign(table: nil, in: context) }
            }
            if category == .queries, let context = app.sessions[id]?.context(db) {
                Button("New Query") { app.openQuery(in: context) }
            }
            Button("Refresh") { Task { await app.sessions[id]?.context(db)?.loadObjects(schema: schema, force: true) } }
        case .savedQuery(_, _, let queryID):
            Button("Open Query") { app.activate(node) }
            Divider()
            Button("Delete Query", role: .destructive) { app.deleteSavedQuery(queryID) }
        case .object(let id, let db, let object):
            let favorite = app.isFavorite(object, connectionID: id, database: db)
            Button(favorite ? "Remove from Favorites" : "Add to Favorites") {
                app.toggleFavorite(object, connectionID: id, database: db)
            }
            Divider()
            if object.kind == .table, let context = app.sessions[id]?.context(db) {
                Button("Design Table") { app.openDesign(table: object, in: context) }
                if !context.driver.config.readOnly {
                    Button("Import Wizard…") { app.importTarget = ImportTarget(context: context, object: object) }
                }
            }
            if object.kind != .routine {
                Button("Open \(object.kind == .table ? "Table" : "View")") { app.activate(node) }
                Button("Select Top 100 in New Query") {
                    guard let context = app.sessions[id]?.context(db) else { return }
                    app.openQuery(text: context.driver.dialect.selectPage(table: object.name, schema: object.schema, offset: 0, limit: 100) + ";", in: context)
                }
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(object.name, forType: .string)
            }
        case .myConnections, .group:
            Button("New Connection…") { app.newConnection() }
        default:
            EmptyView()
        }
    }
}

/// Search field and the filter / favorites / locate / collapse buttons under the tree.
private struct NavigatorSearchBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search", text: $app.navigatorFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !app.navigatorFilter.isEmpty {
                IconButton(systemImage: "xmark.circle.fill", help: "Clear Search") { app.navigatorFilter = "" }
            }
            IconButton(systemImage: "line.3.horizontal.decrease", help: "Filter — coming soon", isEnabled: false) {}
            IconButton(systemImage: app.favoritesOnly ? "star.fill" : "star", help: "Show only favorites",
                       isOn: app.favoritesOnly, tint: .yellow, isEnabled: !app.favorites.isEmpty || app.favoritesOnly) {
                app.favoritesOnly.toggle()
            }
            IconButton(systemImage: "scope", help: "Locate the open object in the navigator", isEnabled: app.selectedTableTab != nil) {
                app.revealSelectedTab()
            }
            IconButton(systemImage: "chevron.up.chevron.down", help: "Collapse All") { app.collapseNavigator() }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

extension DatabaseKind {
    var systemImage: String {
        switch self {
        case .sqlite: "doc.text.fill"
        case .postgresql: "cylinder.split.1x2.fill"
        case .mysql, .mariadb: "cylinder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sqlite: .cyan
        case .postgresql: .blue
        case .mysql: .orange
        case .mariadb: .brown
        }
    }
}

extension ObjectCategory {
    var systemImage: String {
        switch self {
        case .tables: "tablecells.fill"
        case .views: "eyeglasses"
        case .materializedViews: "eyeglasses"
        case .functions: "function"
        case .queries: "doc.text.magnifyingglass"
        case .backups: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .tables, .views: .blue
        case .materializedViews: .orange
        case .functions: .indigo
        case .queries: .orange
        case .backups: .gray
        }
    }
}

extension DatabaseObjectKind {
    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .view: "eyeglasses"
        case .materializedView: "eyeglasses"
        case .routine: "function"
        }
    }
}

extension ConnectionColor {
    var swiftUIColor: Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
