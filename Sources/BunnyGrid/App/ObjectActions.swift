import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// A destructive or naming action on a table or view, confirmed in an alert hosted by ContentView.
struct PendingObjectAction: Identifiable {
    enum Kind { case drop, empty, truncate, rename }
    let id = UUID()
    let kind: Kind
    let object: DatabaseObject
    let context: DatabaseContext

    var title: String {
        switch kind {
        case .drop: "Delete “\(object.name)”?"
        case .empty: "Empty “\(object.name)”?"
        case .truncate: "Truncate “\(object.name)”?"
        case .rename: "Rename “\(object.name)”"
        }
    }

    var message: String {
        switch kind {
        case .drop: "This permanently drops the \(object.kind == .table ? "table" : "view") from the database."
        case .empty: "Deletes every row. Auto-increment counters are kept."
        case .truncate: "Deletes every row and resets auto-increment counters."
        case .rename: "Enter the new name."
        }
    }

    var confirmTitle: String {
        switch kind {
        case .drop: "Delete"
        case .empty: "Empty"
        case .truncate: "Truncate"
        case .rename: "Rename"
        }
    }
}

/// Objects the Export Wizard writes, one file each.
struct ExportTarget: Identifiable {
    let id = UUID()
    let context: DatabaseContext
    let objects: [DatabaseObject]
}

extension AppModel {
    /// Runs a confirmed action. `text` is the new name for a rename.
    func perform(_ action: PendingObjectAction, text: String = "") {
        let object = action.object, context = action.context, d = context.driver.dialect
        let statements: [String]
        switch action.kind {
        case .drop: statements = [d.dropObject(object)]
        case .empty: statements = [d.emptyTable(object)]
        case .truncate: statements = d.truncateTable(object)
        case .rename:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != object.name else { return }
            statements = [d.renameObject(object, to: name)]
        }
        Task {
            do {
                for sql in statements { _ = try await context.driver.executeTimed(sql) }
                switch action.kind {
                case .drop, .rename:
                    for tab in tabs where tab.tableObject == object { closeTab(tab.id) }
                    await context.loadObjects(schema: object.schema, force: true)
                case .empty, .truncate:
                    for case .table(let model) in tabs where model.object == object { await model.reload() }
                }
            } catch {
                alertMessage = "\(action.confirmTitle) failed: \(error.localizedDescription)"
            }
        }
    }

    func duplicate(_ object: DatabaseObject, in context: DatabaseContext, withData: Bool) {
        let existing = Set((context.objects(in: object.schema, category: .tables) ?? []).map(\.name))
        let name = SQLDialect.copyName(for: object.name, existing: existing)
        Task {
            do {
                try await context.driver.duplicateTable(object, as: name, withData: withData)
                await context.loadObjects(schema: object.schema, force: true)
            } catch {
                alertMessage = "Could not duplicate “\(object.name)”: \(error.localizedDescription)"
            }
        }
    }

    /// Dump SQL File: asks where to save, then writes the DDL (and rows) of the objects.
    func dumpSQL(_ objects: [DatabaseObject], in context: DatabaseContext, includeData: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = (objects.count == 1 ? objects[0].name : context.name) + ".sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let header = "BunnyGrid SQL dump\nDatabase: \(context.name) (\(context.kind.displayName))\nDate: \(Date().formatted(.iso8601))"
                let script = try await SQLDumper.dump(objects, from: context.driver, includeData: includeData, header: header)
                try script.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                alertMessage = "Dump failed: \(error.localizedDescription)"
            }
        }
    }

    /// Every object of a database or schema, for "Dump SQL File" on the database node.
    func dumpDatabase(_ context: DatabaseContext, schema: String?, includeData: Bool) {
        Task {
            await context.loadObjects(schema: schema)
            let objects = (context.objects(in: schema, category: .tables) ?? []) + (context.objects(in: schema, category: .views) ?? [])
            dumpSQL(objects, in: context, includeData: includeData)
        }
    }

    /// Opens the SQL file in a query tab and runs it against the database.
    func executeSQLFile(in context: DatabaseContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        openQuery(text: text, in: context)
        selectedQueryTab?.title = url.deletingPathExtension().lastPathComponent
        selectedQueryTab?.run()
    }
}

/// The table/view actions shared by the navigator's and the Objects tab's context menus.
struct ObjectActionItems: View {
    @Environment(AppModel.self) private var app
    let object: DatabaseObject
    let context: DatabaseContext

    var body: some View {
        let writable = !context.driver.config.readOnly
        if object.kind == .table {
            Button("Open Table") { app.openTable(object, in: context) }
            Button("Design Table") { app.openDesign(table: object, in: context) }
            if writable { Button("New Table") { app.openDesign(table: nil, in: context) } }
        } else if object.kind != .routine {
            Button("Open View") { app.openTable(object, in: context) }
        }
        if object.kind != .routine {
            Button("Select Top 100 in New Query") {
                app.openQuery(text: context.driver.dialect.selectPage(table: object.name, schema: object.schema, offset: 0, limit: 100) + ";", in: context)
            }
        }
        if writable && object.kind != .routine {
            Divider()
            Button(object.kind == .table ? "Delete Table" : "Delete View") { ask(.drop) }
            if object.kind == .table {
                Button("Empty Table") { ask(.empty) }
                Button("Truncate Table") { ask(.truncate) }
                Menu("Duplicate Table") {
                    Button("Structure and Data") { app.duplicate(object, in: context, withData: true) }
                    Button("Structure Only") { app.duplicate(object, in: context, withData: false) }
                }
            }
            Button("Rename…") { ask(.rename) }
        }
        if object.kind != .routine {
            Divider()
            if object.kind == .table && writable {
                Button("Import Wizard…") { app.importTarget = ImportTarget(context: context, object: object) }
                Button("Data Generation…") { app.generationTarget = ImportTarget(context: context, object: object) }
            }
            Button("Export Wizard…") { app.exportTarget = ExportTarget(context: context, objects: [object]) }
            Menu("Dump SQL File") {
                Button("Structure and Data…") { app.dumpSQL([object], in: context, includeData: true) }
                Button("Structure Only…") { app.dumpSQL([object], in: context, includeData: false) }
            }
        }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(object.name, forType: .string)
        }
        Button("Refresh") { Task { await context.loadObjects(schema: object.schema, force: true) } }
    }

    private func ask(_ kind: PendingObjectAction.Kind) {
        app.pendingObjectAction = PendingObjectAction(kind: kind, object: object, context: context)
    }
}

/// Confirmation alert for PendingObjectAction, with the name prompt for rename and the safe-confirm field for drop.
struct ObjectActionAlert: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var text = ""

    func body(content: Content) -> some View {
        let action = app.pendingObjectAction
        let safe = AppOptions.shared.values.useSafeConfirmDialog && action?.kind == .drop
        content.alert(action?.title ?? "", isPresented: Binding(
            get: { app.pendingObjectAction != nil },
            set: { if !$0 { app.pendingObjectAction = nil } }
        )) {
            if action?.kind == .rename {
                TextField("New name", text: $text)
            } else if safe {
                TextField("Object name", text: $text)
            }
            Button(action?.confirmTitle ?? "OK", role: action?.kind == .rename ? nil : .destructive) {
                if let action, !safe || text == action.object.name { app.perform(action, text: text) }
                app.pendingObjectAction = nil
            }
            Button("Cancel", role: .cancel) { app.pendingObjectAction = nil }
        } message: {
            Text(safe ? "\(action?.message ?? "") Type “\(action?.object.name ?? "")” to confirm." : action?.message ?? "")
        }
        .onChange(of: action?.id) { text = action?.kind == .rename ? action?.object.name ?? "" : "" }
    }
}
