import AppKit
import BunnyGridCore
import SwiftUI

/// The window's chrome, drawn by us under a hidden title bar like Navicat on macOS:
/// a title row beside the traffic lights, then the icon toolbar with View and the account on the right.
struct MainToolbar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            WindowTitleRow()

            HStack(alignment: .top, spacing: 1) {
                Menu {
                    ForEach(DatabaseKind.allCases) { kind in
                        Button(kind.displayName + "…") { app.newConnection(kind: kind) }
                    }
                    Divider()
                    Button("Open SQLite Database…") { app.presentOpenSQLitePanel() }
                } label: {
                    ChromeLabel(title: "Connection") { AppIcon(name: "connection", size: 32) }
                } primaryAction: {
                    app.newConnection()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Connection (⌘N). Hold for database types.")

                if engine == .redis {
                    redisButtons
                } else {
                ChromeButton(title: "New Query", isEnabled: app.currentContext != nil, help: "New Query (⌘T)") {
                    app.openQuery()
                } glyph: {
                    AppIcon(name: "new-query", size: 32, isEnabled: app.currentContext != nil)
                }

                // Engine-specific object buttons, as Navicat shows them (SQLite: Index and Trigger).
                ForEach(ObjectCategory.toolbarCategories(for: app.currentContext?.kind), id: \.self) { category in
                    objectButton(category, isDocumentStore && category == .tables ? "Collection" : category.noun, category.iconName)
                }
                let server = app.currentSession
                if !isDocumentStore {
                ChromeButton(title: "User", isEnabled: server?.state == .connected && server?.config.kind != .sqlite,
                             help: "Users and roles of the server") {
                    app.usersSession = server
                } glyph: {
                    AppIcon(name: "user", size: 32, isEnabled: server?.state == .connected && server?.config.kind != .sqlite)
                }
                }
                if let context = app.currentContext, context.kind != .sqlite, !isDocumentStore {
                    Menu {
                        ForEach(context.driver.dialect.otherObjectQueries, id: \.title) { item in
                            Button(item.title) {
                                app.openQuery(text: item.sql + ";", in: context)
                                app.selectedQueryTab?.title = item.title
                                app.selectedQueryTab?.run()
                            }
                        }
                    } label: {
                        ChromeLabel(title: "Others") {
                            AppIcon(name: "others", size: 32)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary).offset(x: 7, y: 2)
                                }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sequences, types, triggers, indexes and other objects")
                }
                objectButton(.queries, "Query", "query")
                if !isDocumentStore { objectButton(.backups, "Backup", "backup") }
                }
                ChromeButton(title: "Automation", help: "Batch jobs that run queries, exports and backups on a schedule") {
                    app.openAutomation()
                } glyph: {
                    AppIcon(name: "automation", size: 32)
                }
                let modelContext = app.currentContext?.isOpen == true && !isDocumentStore ? app.currentContext : nil
                if engine != .redis && !isDocumentStore {
                ChromeButton(title: "Model", isEnabled: modelContext != nil, help: "Reverse the database to an ER model") {
                    if let modelContext { app.openModel(in: modelContext, schema: app.currentSchema) }
                } glyph: {
                    AppIcon(name: "model", size: 32, isEnabled: modelContext != nil)
                }
                }
                BIToolbarMenu()

                Spacer(minLength: 16)

                ViewControl()
                AccountBadge()
                    .padding(.leading, 16)
                    .padding(.top, -2)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.top, 3)
            .padding(.bottom, 4)
        }
        .background(ChromeBackground())
    }

    /// The engine of the selected connection: the toolbar shows only what applies to it, as Navicat does.
    private var engine: DatabaseKind? { app.currentSession?.config.kind ?? app.currentContext?.kind }
    private var isDocumentStore: Bool { engine?.isDocumentStore == true }

    /// Navicat's Redis toolbar: Key, Console and Server Monitor.
    @ViewBuilder
    private var redisButtons: some View {
        let session = app.currentSession
        let connected = session?.state == .connected
        ChromeButton(title: "Key", isEnabled: connected && session?.config.readOnly != true, help: "New Key") {
            if let session { app.redisNewKey = RedisNewKeyTarget(connectionID: session.id, database: app.redisSelection?.database ?? 0) }
        } glyph: {
            SymbolGlyph(systemImage: "key.horizontal.fill", tint: .orange, isEnabled: connected)
        }
        ChromeButton(title: "Console", isEnabled: connected, help: "Redis Console") {
            if let session { app.openRedisConsole(connectionID: session.id) }
        } glyph: {
            SymbolGlyph(systemImage: "apple.terminal.fill", tint: .gray, isEnabled: connected)
        }
        ChromeButton(title: "Server Monitor", isEnabled: connected, help: "Server info, clients and memory") {
            if let session { app.openRedisServerMonitor(connectionID: session.id) }
        } glyph: {
            SymbolGlyph(systemImage: "gauge.with.dots.needle.67percent", tint: .green, isEnabled: connected)
        }
    }

    /// The object type the toolbar highlights: the Objects tab's category, or the kind of the open tab
    /// (a table or design → Table, a view → View, a query → Query); none for other tabs (BI, Automation, …).
    private var highlightedCategory: ObjectCategory? {
        switch app.selectedTab {
        case nil: app.objectCategory
        case .table(let model): model.object.kind == .view ? .views : .tables
        case .design: .tables
        case .query: .queries
        case .document(let tab) where tab is CollectionTabModel: .tables
        default: nil
        }
    }

    private func objectButton(_ category: ObjectCategory, _ title: String, _ icon: String) -> some View {
        ChromeButton(title: title, isSelected: highlightedCategory == category, help: "Show \(category.rawValue)") {
            app.showCategory(category)
        } glyph: {
            AppIcon(name: icon, size: 32)
        }
    }
}

/// Toolbar area behind the icons: window chrome color, draggable, double-click to zoom like a title bar.
private struct ChromeBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.primary.opacity(0.03))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
            .modifier(WindowDragModifier())
    }
}

private struct WindowDragModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// Icon over label. The selected object type sits in a rounded box that holds both, as in Navicat;
/// in a background window the icons lose their color like the rest of the chrome.
private struct ChromeLabel<Glyph: View>: View {
    let title: String
    var isSelected = false
    var isEnabled = true
    var isHovering = false
    @ViewBuilder let glyph: () -> Glyph
    @Environment(\.controlActiveState) private var activeState

    private var isKey: Bool { activeState != .inactive }

    var body: some View {
        VStack(spacing: 2) {
            glyph()
                .saturation(isKey ? 1 : 0)
                .opacity(isKey ? 1 : 0.7)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.top, 3)
        .padding(.bottom, 2)
        .frame(minWidth: 56)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.1 : (isHovering ? 0.05 : 0)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isSelected ? 0.1 : 0), lineWidth: 1)
                }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contentShape(Rectangle())
    }

    private var labelStyle: HierarchicalShapeStyle {
        if !isEnabled { return .tertiary }
        if isSelected { return .primary }
        return isKey ? .primary : .secondary
    }
}

private struct ChromeButton<Glyph: View>: View {
    let title: String
    var isSelected = false
    var isEnabled = true
    var help: String?
    var comingSoon: String?
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @State private var isHovering = false
    @State private var showingSoon = false

    var body: some View {
        Button {
            if comingSoon != nil { showingSoon = true } else { action() }
        } label: {
            ChromeLabel(title: title, isSelected: isSelected, isEnabled: isEnabled, isHovering: isHovering && isEnabled, glyph: glyph)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help ?? title)
        .popover(isPresented: $showingSoon, arrowEdge: .bottom) { ComingSoonNote(title: title, detail: comingSoon ?? "") }
    }
}

/// "View": a capsule with the left (navigation) and right (info) pane toggles.
private struct ViewControl: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                toggle("sidebar.left", isOn: app.showNavigator, help: "Show/Hide Navigation Pane (⌥⌘1)") { app.showNavigator.toggle() }
                Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 16)
                toggle("sidebar.right", isOn: app.showAssistant, help: "Show/Hide Information Pane (⌥⌘2)") { app.showAssistant.toggle() }
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .glassBackground(in: Capsule(), interactive: true)
            Text("View")
                .font(.system(size: 11))
                .foregroundStyle(activeState == .inactive ? .secondary : .primary)
        }
    }

    private func toggle(_ symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 40, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The title row beside the traffic lights: the open tab's icon and title ("customers@main (My Server)"), as Navicat
/// titles its window, or the app name on the Objects tab.
private struct WindowTitleRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 5) {
            if let tab = app.selectedTab {
                AppIcon(name: tab.systemImage, size: 15)
                    .saturation(activeState == .inactive ? 0 : 1)
                    .opacity(activeState == .inactive ? 0.6 : 1)
                Text(tab.title)
            } else {
                Text("BunnyGrid")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(activeState == .inactive ? .tertiary : .secondary)
        .lineLimit(1)
        .padding(.leading, 82)
        .padding(.trailing, 16)
        .frame(height: 28)
    }
}

/// Main toolbar "BI": a new workspace on the current database, or a saved one.
private struct BIToolbarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("New BI Workspace") { app.newBIWorkspace(in: app.currentContext?.isOpen == true ? app.currentContext : nil) }
            let saved = app.biWorkspaces
            if !saved.isEmpty {
                Section("Open Workspace") {
                    ForEach(saved) { workspace in Button(workspace.name) { app.openBIWorkspace(workspace) } }
                }
            }
        } label: {
            ChromeLabel(title: "BI") {
                AppIcon(name: "bi", size: 32)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Charts and dashboards built from your tables and queries")
    }
}

/// An SF Symbol drawn at the toolbar's 32 pt icon size, for buttons without an illustrated icon.
private struct SymbolGlyph: View {
    let systemImage: String
    var tint: Color = .accentColor
    var isEnabled = true

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
