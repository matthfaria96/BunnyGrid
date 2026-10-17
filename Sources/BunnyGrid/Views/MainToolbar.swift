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
            HStack {
                Text("BunnyGrid")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 84)
                Spacer()
            }
            .frame(height: 28)

            HStack(alignment: .top, spacing: 0) {
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

                ChromeButton(title: "New Query", isEnabled: app.currentContext != nil, help: "New Query (⌘T)") {
                    app.openQuery()
                } glyph: {
                    AppIcon(name: "new-query", size: 32, isEnabled: app.currentContext != nil)
                }

                // Engine-specific object buttons, as Navicat shows them (SQLite: Index and Trigger).
                ForEach(ObjectCategory.toolbarCategories(for: app.currentContext?.kind), id: \.self) { category in
                    objectButton(category, category.noun, category.iconName)
                }
                let server = app.currentSession
                ChromeButton(title: "User", isEnabled: server?.state == .connected && server?.config.kind != .sqlite,
                             help: "Users and roles of the server") {
                    app.usersSession = server
                } glyph: {
                    AppIcon(name: "user", size: 32, isEnabled: server?.state == .connected && server?.config.kind != .sqlite)
                }
                if let context = app.currentContext, context.kind != .sqlite {
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
                objectButton(.backups, "Backup", "backup")
                ChromeButton(title: "Automation", help: "Batch jobs that run queries, exports and backups on a schedule") {
                    openWindow(id: "automation")
                } glyph: {
                    AppIcon(name: "automation", size: 32)
                }
                let modelContext = app.currentContext?.isOpen == true ? app.currentContext : nil
                ChromeButton(title: "Model", isEnabled: modelContext != nil, help: "Reverse the database to an ER model") {
                    if let modelContext { app.openModel(in: modelContext, schema: app.currentSchema) }
                } glyph: {
                    AppIcon(name: "model", size: 32, isEnabled: modelContext != nil)
                }
                ChromeButton(title: "BI", comingSoon: "Charts and dashboards built from your queries.") {} glyph: {
                    AppIcon(name: "bi", size: 32)
                }

                Spacer(minLength: 16)

                ViewControl()
                AccountBadge()
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .background(ChromeBackground())
    }

    private func objectButton(_ category: ObjectCategory, _ title: String, _ icon: String) -> some View {
        ChromeButton(title: title, isSelected: app.objectCategory == category, help: "Show \(category.rawValue)") {
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

/// Icon over label, with Navicat's rounded highlight for the selected object type.
private struct ChromeLabel<Glyph: View>: View {
    let title: String
    var isSelected = false
    var isEnabled = true
    var isHovering = false
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        VStack(spacing: 2) {
            glyph()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    if isSelected {
                        // The selected object type sits on a pane of glass, as in Navicat on macOS 26+.
                        Color.clear.glassBackground(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07))
                    }
                }
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : (isEnabled ? Color.secondary : Color.secondary.opacity(0.5)))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 52)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
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

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                toggle("sidebar.left", isOn: app.showNavigator, help: "Show/Hide Navigation Pane (⌥⌘1)") { app.showNavigator.toggle() }
                Divider().frame(height: 16)
                toggle("sidebar.right", isOn: app.showAssistant, help: "Show/Hide Information Pane (⌥⌘2)") { app.showAssistant.toggle() }
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .glassBackground(in: Capsule(), interactive: true)
            Text("View").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 34, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
