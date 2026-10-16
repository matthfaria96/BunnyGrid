import AppKit
import BunnyGridCore
import SwiftUI

/// The window's chrome, drawn by us under a hidden title bar like Navicat on macOS:
/// a title row beside the traffic lights, then the icon toolbar with View and the account on the right.
struct MainToolbar: View {
    @Environment(AppModel.self) private var app

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
                    ChromeLabel(title: "Connection") {
                        ToolbarGlyph(systemImage: "powerplug.fill", style: .symbol([Color(white: 0.62)]), badge: .plus)
                    }
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
                    ToolbarGlyph(systemImage: "doc.text.fill", style: .tile([Color(red: 0.98, green: 0.55, blue: 0.40), Color(red: 0.86, green: 0.28, blue: 0.26)]), badge: .plus)
                }

                objectButton(.tables, "Table", ToolbarGlyph(systemImage: "tablecells", style: .tile([Color(red: 0.42, green: 0.70, blue: 1.0), Color(red: 0.13, green: 0.45, blue: 0.92)])))
                objectButton(.views, "View", ToolbarGlyph(systemImage: "eyeglasses", style: .tile([Color(red: 0.55, green: 0.78, blue: 1.0), Color(red: 0.22, green: 0.52, blue: 0.90)])))
                if app.currentContext?.kind == .postgresql {
                    objectButton(.materializedViews, "Materialized View", ToolbarGlyph(systemImage: "eyeglasses", style: .tile([Color(red: 1.0, green: 0.70, blue: 0.40), Color(red: 0.93, green: 0.42, blue: 0.20)])))
                }
                objectButton(.functions, "Function", ToolbarGlyph(systemImage: "function", style: .symbol([Color(red: 0.25, green: 0.55, blue: 1.0)])))
                ChromeButton(title: "User", comingSoon: "Manage users, roles and privileges on the server.") {} glyph: {
                    ToolbarGlyph(systemImage: "person.fill", style: .symbol([Color(red: 1.0, green: 0.72, blue: 0.20)]))
                }
                ChromeButton(title: "Others", comingSoon: "Triggers, sequences, types, events and other objects.") {} glyph: {
                    ToolbarGlyph(systemImage: "wrench.and.screwdriver.fill", style: .symbol([Color(red: 0.25, green: 0.55, blue: 0.95)]), badge: .chevron)
                }
                objectButton(.queries, "Query", ToolbarGlyph(systemImage: "doc.on.doc.fill", style: .symbol([Color(red: 0.98, green: 0.45, blue: 0.35), Color(red: 0.30, green: 0.60, blue: 1.0)])))
                objectButton(.backups, "Backup", ToolbarGlyph(systemImage: "arrow.counterclockwise", style: .tile([Color(white: 0.62), Color(white: 0.40)])))
                ChromeButton(title: "Automation", comingSoon: "Batch jobs that run queries, exports and backups on a schedule.") {} glyph: {
                    ToolbarGlyph(systemImage: "gearshape.2.fill", style: .symbol([Color(red: 0.20, green: 0.75, blue: 0.70), Color(red: 0.55, green: 0.60, blue: 0.65)]))
                }
                ChromeButton(title: "Model", comingSoon: "ER diagrams, reverse engineering and model-to-database sync.") {} glyph: {
                    ToolbarGlyph(systemImage: "square.on.square.squareshape.controlhandles", style: .symbol([Color(red: 1.0, green: 0.62, blue: 0.20)]))
                }
                ChromeButton(title: "BI", comingSoon: "Charts and dashboards built from your queries.") {} glyph: {
                    ToolbarGlyph(systemImage: "chart.bar.xaxis", style: .symbol([Color(red: 0.92, green: 0.30, blue: 0.75), Color(red: 0.55, green: 0.35, blue: 0.95)]))
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

    private func objectButton(_ category: ObjectCategory, _ title: String, _ glyph: ToolbarGlyph) -> some View {
        ChromeButton(title: title, isSelected: app.objectCategory == category, help: "Show \(category.rawValue)") {
            app.showCategory(category)
        } glyph: {
            glyph
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
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.13) : (isHovering ? Color.primary.opacity(0.07) : .clear))
                )
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
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
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

/// Where Navicat shows the signed-in account: a generic avatar with the macOS user's name.
private struct AccountBadge: View {
    var body: some View {
        Menu {
            Text("Signed in locally as \(NSFullUserName())")
            Divider()
            SettingsLink { Text("Settings…") }
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white.opacity(0.9), Color.gray.opacity(0.75))
                .font(.system(size: 32))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSFullUserName())
    }
}
