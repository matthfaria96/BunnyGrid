import AppKit
import BunnyGridCore
import SwiftUI

/// The right pane, as in Navicat for macOS: an ⓘ Info tab describing the selection, and the AI tab.
struct RightPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    tab(.info) {
                        Image(systemName: "info.circle").font(.system(size: 14, weight: .medium))
                    }
                    tab(.ai) {
                        Text("AI").font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassBackground(in: Capsule(), interactive: true)
                HStack {
                    Spacer()
                    IconButton(systemImage: app.assistant.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: app.assistant.isExpanded ? "Narrow" : "Widen", tint: .accentColor) {
                        app.assistant.isExpanded.toggle()
                    }
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 38)
            Divider()
            switch app.rightPane {
            case .info: InfoContent()
            case .ai: AssistantPanel()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tab<Label: View>(_ pane: AppModel.RightPane, @ViewBuilder label: () -> Label) -> some View {
        Button {
            app.rightPane = pane
        } label: {
            label()
                .foregroundStyle(app.rightPane == pane ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pane == .info ? "Information" : "AI Assistant")
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
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
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
            InfoHeader(title: config.displayName, subtitle: config.kind.displayName, actionTitle: "Edit Connection", action: { app.edit(config.id) }) {
                DatabaseBadge(kind: config.kind, size: 56, isActive: session?.isFailed != true)
            }
            InfoField(label: "Status", value: status)
            InfoField(label: "Server Version", value: session?.serverVersion ?? "")
            InfoField(label: "Sessions", value: String(session?.contexts.count ?? 0))
            if config.kind.isFileBased {
                InfoField(label: "Database File", value: config.filePath)
            } else {
                InfoField(label: "Host", value: config.host)
                InfoField(label: "Port", value: String(config.port))
                InfoField(label: "User Name", value: config.username)
                InfoField(label: "SSL", value: config.tls.displayName)
            }
            InfoField(label: "Group", value: config.group ?? "")
            InfoField(label: "Read-only", value: config.readOnly ? "Yes" : "No")
            InfoField(label: "Settings Location", value: AppModel.dataDirectory.appending(path: "connections.json").path)
        }
    }

    private var status: String {
        switch session?.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed(let message): "Failed: \(message)"
        case nil: "Not connected"
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
            InfoHeader(title: database, subtitle: "Database · \(config.displayName)") {
                AppIcon(name: context?.isOpen == true ? "database-open" : "database-closed", size: 56)
            }
            InfoField(label: "Status", value: context?.isOpen == true ? "Open" : "Closed")
            if let context, context.usesSchemas {
                InfoField(label: "Schemas", value: String(context.schemas.count))
            }
            if let objects = context?.objects(in: context?.defaultSchema) {
                InfoField(label: "Tables", value: String(objects.filter { $0.kind == .table }.count))
                InfoField(label: "Views", value: String(objects.filter { $0.kind == .view || $0.kind == .materializedView }.count))
                InfoField(label: "Functions", value: String(objects.filter { $0.kind == .routine }.count))
            }
            InfoField(label: "Connection", value: "\(config.kind.displayName) · \(config.kind.isFileBased ? config.filePath : "\(config.host):\(config.port)")")
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
            InfoHeader(title: object.name, subtitle: kindName) {
                AppIcon(name: object.kind.iconName, size: 56)
            }
            if let rows = stats?.rows { InfoField(label: "Rows", value: rows.formatted()) }
            if let size = stats?.sizeBytes, size > 0 { InfoField(label: "Data Length", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            if let engine = stats?.engine { InfoField(label: "Engine", value: engine) }
            InfoField(label: context?.usesSchemas == true ? "Schema" : "Database", value: object.schema ?? context?.name ?? "")
            if !columns.isEmpty {
                InfoField(label: "Fields", value: String(columns.count))
                InfoField(label: "Primary Key", value: columns.filter(\.isPrimaryKey).map(\.name).joined(separator: ", "))
            }
            InfoField(label: "Comment", value: stats?.comment ?? "")
            if !columns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Columns").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(columns) { column in
                        HStack(spacing: 6) {
                            Image(systemName: GridHeaderCell.symbolName(for: column.dataType)).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
                            Text(column.name).font(.system(size: 12))
                            Spacer()
                            Text(column.dataType).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
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
