import AppKit
import SwiftUI

@main
struct BunnyGridApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("BunnyGrid", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 860)
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
                Button("AI Assistant") { model.showAssistant = true }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
