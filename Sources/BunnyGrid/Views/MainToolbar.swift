import AppKit
import BunnyGridCore
import SwiftUI

/// The large icon toolbar across the top of the window, laid out like Navicat's:
/// Connection, New Query | object types | Query, Backup, Automation, Model, BI | help, AI, account.
struct MainToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(DatabaseKind.allCases) { kind in
                    Button(kind.displayName + "…") { app.newConnection(kind: kind) }
                }
                Divider()
                Button("Open SQLite Database…") { app.presentOpenSQLitePanel() }
            } label: {
                BigToolbarLabel(title: "Connection", systemImage: "powerplug.portrait.fill", colors: [.green, .gray])
            } primaryAction: {
                app.newConnection()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Connection (⌘N). Hold the button for database types.")

            BigToolbarButton(title: "New Query", systemImage: "plus.rectangle.on.rectangle", colors: [.orange, .red],
                             isEnabled: app.currentContext != nil, help: "New Query (⌘T)") {
                app.openQuery()
            }

            separator

            objectButton(.tables, "Table", "tablecells.fill", [.blue])
            objectButton(.views, "View", "eyeglasses", [.blue])
            if app.currentContext?.kind != .sqlite && app.currentContext?.kind != .mysql && app.currentContext?.kind != .mariadb {
                objectButton(.materializedViews, "Materialized View", "eyeglasses", [.orange])
            }
            objectButton(.functions, "Function", "function", [.indigo])
            BigToolbarButton(title: "Role", systemImage: "person.fill", colors: [.orange], isEnabled: false) {}
            Menu {
                Text("Triggers, sequences, types and other objects are coming soon")
            } label: {
                BigToolbarLabel(title: "Others", systemImage: "wrench.and.screwdriver.fill", colors: [.blue, .gray], isEnabled: false, showsMenuIndicator: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(true)

            separator

            objectButton(.queries, "Query", "doc.text.magnifyingglass", [.orange])
            objectButton(.backups, "Backup", "clock.arrow.circlepath", [.gray])
            BigToolbarButton(title: "Automation", systemImage: "gearshape.2.fill", colors: [.teal], isEnabled: false) {}
            BigToolbarButton(title: "Model", systemImage: "square.grid.3x3.topleft.filled", colors: [.orange], isEnabled: false) {}
            BigToolbarButton(title: "BI", systemImage: "chart.bar.fill", colors: [.pink], isEnabled: false) {}

            Spacer(minLength: 12)

            IconButton(systemImage: "info.circle", help: "About BunnyGrid", tint: .secondary) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            .font(.system(size: 18))
            .scaleEffect(1.4)
            .padding(.horizontal, 6)

            IconButton(systemImage: "sparkle", help: "AI Assistant", isOn: app.showAssistant, tint: .blue) {
                app.showAssistant.toggle()
            }
            .scaleEffect(1.4)
            .padding(.horizontal, 6)

            AccountBadge()
                .padding(.leading, 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 40).padding(.horizontal, 4)
    }

    private func objectButton(_ category: ObjectCategory, _ title: String, _ symbol: String, _ colors: [Color]) -> some View {
        BigToolbarButton(title: title, systemImage: symbol, colors: colors, isSelected: app.objectCategory == category,
                         help: "Show \(category.rawValue)") {
            app.showCategory(category)
        }
    }
}

/// Initials of the macOS user, where Navicat shows the signed-in account.
private struct AccountBadge: View {
    private var initials: String {
        let parts = NSFullUserName().split(separator: " ")
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Menu {
            Text("Signed in locally as \(NSFullUserName())")
            Divider()
            SettingsLink { Text("Settings…") }
        } label: {
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
