import AppKit
import BunnyGridCore
import SwiftUI

/// The right pane, as in Navicat for macOS: General (ⓘ), then DDL / Field for a table, Code Snippet / Identifiers
/// for a query, DDL for a design, and the AI Assistant tab.
struct RightPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage("showAIFeatures") private var showAIFeatures = true

    private var available: [AppModel.RightPane] {
        var panes: [AppModel.RightPane] = [.info]
        switch app.selectedTab {
        case .table: panes += [.ddl, .field]
        case .query: panes += [.snippets, .identifiers]
        case .design: panes += [.ddl]
        case .model: break
        case nil: break
        }
        if showAIFeatures { panes.append(.ai) }
        return panes
    }

    private var current: AppModel.RightPane { available.contains(app.rightPane) ? app.rightPane : .info }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 4) {
                    ForEach(available, id: \.self) { pane in
                        tab(pane)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassBackground(in: Capsule(), interactive: true)
                HStack {
                    Spacer()
                    IconButton(systemImage: app.assistant.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: app.assistant.isExpanded ? "Narrow" : "Expand", tint: .accentColor) {
                        app.assistant.isExpanded.toggle()
                    }
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 38)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .info: InfoContent()
        case .ai: AssistantPanel()
        case .ddl:
            switch app.selectedTab {
            case .table(let model): DDLPane(context: model.connectionID.flatMap { app.sessions[$0]?.context(model.databaseName) }, object: model.object)
            case .design(let model): DDLPane(context: model.connectionID.flatMap { app.sessions[$0]?.context(model.databaseName) }, object: model.tableObject, revision: model.revision)
            default: InfoContent()
            }
        case .field:
            if case .table(let model) = app.selectedTab { FieldPane(table: model) } else { InfoContent() }
        case .snippets: SnippetsPane(query: app.selectedQueryTab)
        case .identifiers: IdentifiersPane(query: app.selectedQueryTab)
        }
    }

    private func tab(_ pane: AppModel.RightPane) -> some View {
        Button {
            app.rightPane = pane
        } label: {
            label(for: pane)
                .foregroundStyle(current == pane ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title(for: pane))
    }

    @ViewBuilder
    private func label(for pane: AppModel.RightPane) -> some View {
        switch pane {
        case .info: Image(systemName: "info.circle").font(.system(size: 14, weight: .medium))
        case .ddl:
            Text("DDL").font(.system(size: 7.5, weight: .heavy, design: .rounded))
                .padding(.horizontal, 2).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.2))
        case .field: Image(systemName: "rectangle.split.3x1").font(.system(size: 13, weight: .medium))
        case .snippets: Image(systemName: "curlybraces").font(.system(size: 13, weight: .medium))
        case .identifiers: Image(systemName: "list.bullet.rectangle").font(.system(size: 13, weight: .medium))
        case .ai: AppIcon(name: app.assistant.provider.iconName, size: 15)
        }
    }

    private func title(for pane: AppModel.RightPane) -> String {
        switch pane {
        case .info: "General"
        case .ddl: "DDL"
        case .field: "Field"
        case .snippets: "Code Snippet"
        case .identifiers: "Identifiers"
        case .ai: "AI Assistant"
        }
    }
}

/// What the Info tab describes: the selected navigator node, or the open table.
private struct InfoContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let node = app.navSelection, let id = node.connectionID, let config = app.connection(id: id) {
                switch node {
                case .object(_, let db, let object):
                    ObjectInfo(config: config, context: app.sessions[id]?.context(db), object: object)
                case .database(_, let db), .schema(_, let db, _), .category(_, let db, _, _):
                    DatabaseInfo(config: config, session: app.sessions[id], database: db)
                default:
                    ConnectionInfo(config: config, session: app.sessions[id])
                }
            } else if let tab = app.selectedTableTab, let id = tab.connectionID, let config = app.connection(id: id) {
                ObjectInfo(config: config, context: app.sessions[id]?.context(tab.databaseName), object: tab.object)
            } else {
                Text("No Info")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Large icon, name and subtitle at the top of an info card.
private struct InfoHeader<Icon: View>: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// Text offered by the Share link (Navicat's "Share" under the connection name).
    var shareText: String?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                if let shareText {
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                    .help("Share this connection's URI (without the password)")
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: "square.and.pencil").font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }
}

/// "Label / value" pairs stacked like Navicat's info list.
private struct InfoField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "--" : value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                content()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        }
    }
}

private struct ConnectionInfo: View {
    @Environment(AppModel.self) private var app
    let config: ConnectionConfig
    let session: Session?

    var body: some View {
        InfoScroll {
            InfoHeader(title: config.displayName, subtitle: config.kind.displayName, actionTitle: "Edit Connection", action: { app.edit(config.id) },
                       shareText: ConnectionURI.string(for: config)) {
                DatabaseBadge(kind: config.kind, size: 56, isActive: session?.isFailed != true)
            }
            InfoField(label: "Active Profile", value: "Main Profile")
            if case .failed(let message) = session?.state {
                InfoField(label: "Status", value: "Failed: \(message)")
            }
            InfoField(label: "Server Version", value: session?.serverVersion ?? "")
            InfoField(label: "Sessions", value: String(session?.contexts.count ?? 0))
            if config.kind.isFileBased {
                InfoField(label: "Database File", value: config.filePath)
            } else {
                if let socket = config.activeSocketPath {
                    InfoField(label: "Socket File", value: socket)
                } else {
                    InfoField(label: "Host", value: config.host)
                    InfoField(label: "Port", value: String(config.port))
                }
                InfoField(label: "User Name", value: config.username)
                if let ssh = config.activeSSH {
                    InfoField(label: "SSH Host", value: "\(ssh.username)@\(ssh.host):\(ssh.port)")
                }
                if config.tls != .disable && config.activeSocketPath == nil {
                    InfoField(label: "SSL", value: config.tls.displayName)
                }
            }
            InfoField(label: "Settings Location", value: AppModel.dataDirectory.appending(path: "connections.json").path)
            InfoField(label: "Remarks", value: config.remarks ?? "")
        }
    }
}

/// "🔌 BunnyGrid Reference" / "🛢 main" lines under the header, as Navicat shows the object's location.
private struct LocationLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 13)).lineLimit(1)
        }
    }
}

private struct DatabaseInfo: View {
    let config: ConnectionConfig
    let session: Session?
    let database: String

    var body: some View {
        let context = session?.context(database)
        InfoScroll {
            InfoHeader(title: database, subtitle: "Database", shareText: ConnectionURI.string(for: config)) {
                AppIcon(name: context?.isOpen == true ? "database-open" : "database-closed", size: 56)
            }
            LocationLine(icon: "powerplug", text: config.displayName)
                .padding(.bottom, 8)
            if let context, context.usesSchemas {
                InfoField(label: "Schemas", value: String(context.schemas.count))
            }
            if let objects = context?.objects(in: context?.defaultSchema) {
                InfoField(label: "Tables", value: String(objects.filter { $0.kind == .table }.count))
                InfoField(label: "Views", value: String(objects.filter { $0.kind == .view || $0.kind == .materializedView }.count))
            }
        }
    }
}

private struct ObjectInfo: View {
    let config: ConnectionConfig
    let context: DatabaseContext?
    let object: DatabaseObject
    @State private var stats: TableStatistics?
    @State private var columns: [BunnyGridCore.TableColumn] = []

    var body: some View {
        InfoScroll {
            InfoHeader(title: object.name, subtitle: kindName, shareText: "\(ConnectionURI.string(for: config)) — \(object.qualifiedName)") {
                AppIcon(name: object.kind.iconName, size: 56)
            }
            VStack(alignment: .leading, spacing: 6) {
                LocationLine(icon: "powerplug", text: config.displayName)
                LocationLine(icon: "cylinder", text: object.schema.map { "\(context?.name ?? "") · \($0)" } ?? context?.name ?? "")
            }
            .padding(.bottom, 8)
            if context?.kind == .sqlite {
                if let page = stats?.rootPage { InfoField(label: "Root Page", value: String(page)) }
                if let indexes = stats?.hasIndexes { InfoField(label: "Has Indexes", value: indexes ? "Yes" : "No") }
                if let triggers = stats?.hasTriggers { InfoField(label: "Has Triggers", value: triggers ? "Yes" : "No") }
                if let rows = stats?.rows { InfoField(label: "Rows", value: rows.formatted()) }
            } else {
                if let rows = stats?.rows { InfoField(label: "Rows", value: rows.formatted()) }
                if let size = stats?.sizeBytes, size > 0 { InfoField(label: "Data Length", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                if let engine = stats?.engine { InfoField(label: "Engine", value: engine) }
                if let created = stats?.created { InfoField(label: "Created Date", value: created) }
                if let modified = stats?.modified { InfoField(label: "Modified Date", value: modified) }
                if let collation = stats?.collation { InfoField(label: "Collation", value: collation) }
                InfoField(label: "Comment", value: stats?.comment ?? "")
            }
        }
        .task(id: object.id) { await load() }
    }

    private var kindName: String {
        switch object.kind {
        case .table: "Table"
        case .view: "View"
        case .materializedView: "Materialized View"
        case .routine: "Function"
        }
    }

    private var driverSchema: String? {
        guard let context else { return nil }
        switch context.kind {
        case .postgresql: return object.schema
        case .mysql, .mariadb: return context.name
        case .sqlite: return nil
        }
    }

    private func load() async {
        stats = nil
        columns = []
        guard let context, object.kind != .routine else { return }
        columns = (try? await context.driver.listColumns(table: object.name, schema: driverSchema)) ?? []
        stats = (try? await context.driver.tableStatistics(schema: driverSchema))?[object.name]
    }
}
