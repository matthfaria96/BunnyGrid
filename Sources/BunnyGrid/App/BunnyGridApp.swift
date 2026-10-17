import AppKit
import SwiftUI

/// Window appearance chosen in Settings; "system" follows macOS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct BunnyGridApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        Window("BunnyGrid", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { AppearancePreference(rawValue: appearance)?.apply() }
                .onChange(of: appearance) { _, value in AppearancePreference(rawValue: value)?.apply() }
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { model.newConnection() }
                    .keyboardShortcut("n")
                Button("New Query") { model.openQuery() }
                    .keyboardShortcut("t")
                    .disabled(model.currentContext == nil)
                Divider()
                Button("Open SQLite Database…") { model.presentOpenSQLitePanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(model.selectedTab == nil ? "Close Window" : "Close Tab") { model.closeSelectedTabOrWindow() }
                    .keyboardShortcut("w")
                Button("Save") { model.saveCurrent() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveCurrent)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showNavigator ? "Hide Navigation Pane" : "Show Navigation Pane") { model.showNavigator.toggle() }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button(model.showAssistant ? "Hide AI Assistant" : "Show AI Assistant") { model.showAssistant.toggle() }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
                Button("Show Next Tab") { model.selectAdjacentTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { model.selectAdjacentTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
            }
            CommandMenu("Table") {
                let tab = model.selectedTableTab
                Button("Add Record") { tab?.addRow() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(tab?.isEditable != true)
                Button("Delete Records") { if let tab { tab.toggleDelete(tab.selectedRows) } }
                    .disabled(tab?.isEditable != true || tab?.selectedRows.isEmpty == true)
                Divider()
                Button("Apply Changes") { Task { await tab?.applyChanges() } }
                    .disabled(tab?.hasChanges != true)
                Button("Discard Changes") { tab?.discardChanges() }
                    .disabled(tab?.hasChanges != true)
                Button("Refresh") { tab?.requestReload() }
                    .keyboardShortcut("r")
                    .disabled(tab == nil || tab?.hasChanges == true)
                Divider()
                Button("Cell Editor") { tab?.showCellEditor.toggle() }.disabled(tab == nil)
                Button("Filter & Sort") { tab?.showFilterBar.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(tab == nil)
                Button("Locate in Navigation Pane") { model.revealSelectedTab() }.disabled(tab == nil)
                Divider()
                Button("New Table") { if let context = model.currentContext { model.openDesign(table: nil, in: context) } }
                    .disabled(model.currentContext == nil || model.currentContext?.driver.config.readOnly == true)
                Button("Design Table") {
                    if let tab, let context = model.currentContextFor(tab) { model.openDesign(table: tab.object, in: context) }
                }
                .disabled(tab?.object.kind != .table)
                Button("Import Wizard…") {
                    if let tab, let context = model.currentContextFor(tab) { model.importTarget = ImportTarget(context: context, object: tab.object) }
                }
                .disabled(tab?.object.kind != .table || tab?.readOnlyReason != nil)
                Button("Data Generation…") {
                    if let tab, let context = model.currentContextFor(tab) { model.generationTarget = ImportTarget(context: context, object: tab.object) }
                }
                .disabled(tab?.object.kind != .table || tab?.readOnlyReason != nil)
                Divider()
                Button("Begin Transaction") {
                    if let tab { Task { await tab.beginTransaction(session: tab.connectionID.flatMap { model.sessions[$0] }) } }
                }
                .disabled(tab?.canBeginTransaction != true)
                Button("Commit") { Task { await tab?.commitTransaction() } }
                    .disabled(tab?.isInTransaction != true)
                Button("Rollback") { Task { await tab?.rollbackTransaction() } }
                    .disabled(tab?.isInTransaction != true)
            }
            CommandMenu("Favorites") {
                let tab = model.selectedTableTab
                Button(tab.map { model.isFavorite($0.object, connectionID: $0.connectionID ?? UUID(), database: $0.databaseName) } == true
                       ? "Remove from Favorites" : "Add to Favorites") {
                    if let tab, let id = tab.connectionID { model.toggleFavorite(tab.object, connectionID: id, database: tab.databaseName) }
                }
                .keyboardShortcut("d")
                .disabled(tab == nil)
                Divider()
                if model.favorites.isEmpty {
                    Text("No Favorites")
                }
                ForEach(model.favorites) { favorite in
                    Button("\(favorite.name)  —  \(favorite.database)\(favorite.schema.map { ".\($0)" } ?? "")") {
                        model.openFavorite(favorite)
                    }
                }
            }
            CommandMenu("Tools") {
                ForEach(SyncTool.allCases) { tool in
                    Button(tool.title + "…") { model.openSyncWizard(tool) }
                }
                Divider()
                Button("AI Assistant") { model.showAssistant = true; model.rightPane = .ai }
                Button("AI Platform…") { model.showingAccountMenu = true }
                Button("Query History") {
                    if model.selectedQueryTab == nil { model.openQuery() }
                }
                .disabled(model.currentContext == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than a bundled .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        // `--window-size 1037x695` sizes the main window like a reference capture (visual checks).
        if let index = CommandLine.arguments.firstIndex(of: "--window-size"), CommandLine.arguments.indices.contains(index + 1) {
            let parts = CommandLine.arguments[index + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.hasPrefix("main") == true {
                        window.minSize = NSSize(width: 600, height: 400)
                        window.contentMinSize = NSSize(width: 600, height: 400)
                        window.setFrame(NSRect(x: 80, y: 120, width: parts[0], height: parts[1]), display: true)
                    }
                }
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
