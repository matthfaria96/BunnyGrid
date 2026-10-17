import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// The Backup wizard and Restore sheets, attached once to the main window.
struct BackupSheets: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var automation = app.automation
        content
            .sheet(item: $automation.backupTarget) { BackupWizardView(target: $0) }
            .sheet(item: $automation.restoreTarget) { RestoreBackupView(target: $0) }
            #if DEBUG
            // `--automation` opens the Automation window for screenshots.
            .task { if CommandLine.arguments.contains("--automation") { openWindow(id: "automation") } }
            #endif
    }

    @Environment(\.openWindow) private var openWindow
}

/// Objects toolbar for the Backups folder: New Backup, Restore, Extract SQL, Delete, Show in Finder.
struct BackupToolbarItems: View {
    @Environment(AppModel.self) private var app
    let context: DatabaseContext?
    let schema: String?

    private var selected: BackupEntry? {
        guard let context, let id = app.automation.selectedBackupID else { return nil }
        return app.automation.backups(for: BackupTarget(context: context, schema: schema)).first { $0.id == id }
    }

    var body: some View {
        let automation = app.automation
        let selected = selected
        BackupIcon("plus.circle", .green, "New Backup", isEnabled: context != nil) {
            if let context { automation.backupTarget = BackupTarget(context: context, schema: schema) }
        }
        BackupIcon("arrow.uturn.backward.circle", .blue, "Restore Backup", isEnabled: selected != nil && context?.driver.config.readOnly == false) {
            if let selected, let context { automation.restoreTarget = RestoreTarget(entry: selected, context: context) }
        }
        BackupIcon("doc.text", .orange, "Extract SQL", isEnabled: selected != nil) {
            if let selected { BackupActions.extract(selected, app: app) }
        }
        BackupIcon("minus.circle", .red, "Delete Backup", isEnabled: selected != nil) {
            if let selected { BackupActions.delete(selected, app: app) }
        }
        BackupIcon("folder", .secondary, "Show in Finder", isEnabled: selected != nil) {
            if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.fileURL]) }
        }
    }
}

enum BackupActions {
    @MainActor static func extract(_ entry: BackupEntry, app: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(entry.manifest.database)-\(entry.name).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = app.automation.backupStore
        Task {
            do {
                let sql = try await BackupEngine.extractSQL(entry, store: store)
                try Data(sql.utf8).write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                app.alertMessage = "Could not extract the backup: \(error.localizedDescription)"
            }
        }
    }

    @MainActor static func delete(_ entry: BackupEntry, app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Delete backup “\(entry.name)”?"
        alert.informativeText = "The backup file is moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
        } catch {
            app.alertMessage = "Could not delete the backup: \(error.localizedDescription)"
        }
        app.automation.selectedBackupID = nil
        app.automation.backupsChanged()
    }
}

private struct BackupIcon: View {
    let systemImage: String
    let tint: Color
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ systemImage: String, _ tint: Color, _ help: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tint = tint
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

/// The Backups folder in the Objects tab: one row per backup of this database (or schema).
struct BackupListView: View {
    @Environment(AppModel.self) private var app
    let context: DatabaseContext
    let schema: String?
    let search: String
    @State private var entries: [BackupEntry] = []
    @State private var editingComment: BackupEntry?
    @State private var comment = ""

    private var shown: [BackupEntry] {
        search.isEmpty ? entries : entries.filter { $0.name.contains(search) || $0.manifest.comment.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var automation = app.automation
        Table(shown, selection: $automation.selectedBackupID) {
            TableColumn("Name") { entry in
                Label { Text(entry.name) } icon: { AppIcon(name: "backup", size: 16) }
            }
            .width(min: 140, ideal: 170)
            TableColumn("Created") { entry in
                Text(entry.manifest.createdAt, format: .dateTime.year().month().day().hour().minute().second()).foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160)
            TableColumn("Size") { entry in
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.fileSize), countStyle: .file)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Objects") { entry in
                Text("\(entry.manifest.objects.count)\(entry.manifest.rowCount.map { " · \($0.formatted()) rows" } ?? "")").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Type") { entry in Text(entry.manifest.method.displayName).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 150)
            TableColumn("Comment") { entry in Text(entry.manifest.comment).lineLimit(1) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) {
                Button("Restore Backup…") { automation.restoreTarget = RestoreTarget(entry: entry, context: context) }
                    .disabled(context.driver.config.readOnly)
                Button("Extract SQL…") { BackupActions.extract(entry, app: app) }
                Button("Edit Comment…") { comment = entry.manifest.comment; editingComment = entry }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                Divider()
                Button("Delete Backup", role: .destructive) { BackupActions.delete(entry, app: app) }
            }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }), !context.driver.config.readOnly {
                automation.restoreTarget = RestoreTarget(entry: entry, context: context)
            }
        }
        .overlay {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "No backups" : "No matches").foregroundStyle(.tertiary)
                    if search.isEmpty {
                        Button("New Backup…") { automation.backupTarget = BackupTarget(context: context, schema: schema) }
                    }
                }
            }
        }
        .task(id: "\(context.session?.id.uuidString ?? "")/\(context.name)/\(schema ?? "")/\(app.automation.backupRevision)") {
            entries = app.automation.backups(for: BackupTarget(context: context, schema: schema))
            app.listedItemCount = entries.count
        }
        .sheet(item: $editingComment) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text("Comment for \(entry.name)").font(.headline)
                TextField("Comment", text: $comment).frame(width: 320)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { editingComment = nil }
                    Button("Save") {
                        _ = try? app.automation.backupStore.setComment(comment, of: entry)
                        editingComment = nil
                        app.automation.backupsChanged()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }
}

/// Navicat's Backup wizard: comment, object selection, structure/data, and (SQLite) a file-level copy.
struct BackupWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: BackupTarget
    @State private var comment = ""
    @State private var selected: Set<String> = []
    @State private var includeStructure = true
    @State private var includeData = true
    @State private var method: BackupMethod = .sql
    @State private var progress: String?
    @State private var task: Task<Void, Never>?

    private var candidates: [DatabaseObject] {
        (target.context.objects(in: target.schema) ?? []).filter { $0.kind != .routine }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.gray).font(.title2)
                VStack(alignment: .leading) {
                    Text("New Backup").font(.headline)
                    Text(target.context.location(schema: target.schema)).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Comment", text: $comment, prompt: Text("Comment (optional)"))
            if target.context.kind == .sqlite {
                Picker("Method", selection: $method) {
                    ForEach(BackupMethod.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if method == .sql {
                HStack(spacing: 16) {
                    Toggle("Structure", isOn: $includeStructure)
                    Toggle("Data", isOn: $includeData)
                }
                HStack {
                    Text("Objects (\(selected.count) of \(candidates.count))").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Select All") { selected = Set(candidates.map(\.id)) }
                    Button("Deselect All") { selected = [] }
                }
                .controlSize(.small)
                List(candidates) { object in
                    Toggle(isOn: Binding(get: { selected.contains(object.id) },
                                         set: { if $0 { selected.insert(object.id) } else { selected.remove(object.id) } })) {
                        Label { Text(object.name) } icon: { AppIcon(name: object.kind.iconName, size: 16) }
                    }
                }
                .frame(minHeight: 220)
            } else {
                Text("Copies the whole database file page by page with SQLite's backup API, safe while it is open.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity, alignment: .top)
            }
            if let progress { ProgressView { Text(progress).font(.caption) } }
            HStack {
                Text("Saved in BunnyGrid's data folder, compressed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task != nil || (method == .sql && (selected.isEmpty || (!includeStructure && !includeData))))
            }
        }
        .disabled(task != nil && progress == nil)
        .padding(20)
        .frame(width: 520, height: 560)
        .task {
            if target.context.objects(in: target.schema) == nil { await target.context.loadObjects(schema: target.schema) }
            selected = Set((target.objects.isEmpty ? candidates : target.objects).map(\.id))
        }
    }

    private func start() {
        guard let session = target.context.session else { return }
        let all = selected.count == candidates.count
        let options = BackupOptions(objects: all ? nil : candidates.filter { selected.contains($0.id) }.map(BackupObject.init),
                                    includeStructure: includeStructure, includeData: includeData, method: method, comment: comment)
        let driver = target.context.driver, config = session.config, database = target.context.name
        let schema = target.context.driverSchema(target.schema)
        let store = app.automation.backupStore
        task = Task {
            do {
                _ = try await BackupEngine.create(from: driver, connection: config, database: database, schema: schema,
                                                  options: options, store: store) { text in await MainActor.run { progress = text } }
                app.automation.backupsChanged()
                app.showCategory(.backups)
                dismiss()
            } catch {
                app.alertMessage = "Backup failed: \(error.localizedDescription)"
                progress = nil
                task = nil
            }
        }
    }
}

/// Restore Backup: into this or another open database, with drop / continue-on-error / transaction options.
struct RestoreBackupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: RestoreTarget
    @State private var destination: String = ""
    @State private var dropExisting = true
    @State private var continueOnError = false
    @State private var useTransaction = false
    @State private var report: ScriptRunReport?
    @State private var task: Task<Void, Never>?
    @State private var finished = false

    /// Open databases of the backup's engine, keyed "connection id/database".
    private var destinations: [(key: String, title: String, context: DatabaseContext)] {
        app.sessions.values.filter { $0.config.kind == target.entry.manifest.engine || ($0.config.kind == .mariadb && target.entry.manifest.engine == .mysql) }
            .flatMap { session in
                session.contexts.values.filter(\.isOpen).map { ("\(session.id.uuidString)/\($0.name)", "\(session.config.displayName) › \($0.name)", $0) }
            }
            .sorted { $0.title < $1.title }
    }

    private var chosen: DatabaseContext? { destinations.first { $0.key == destination }?.context }

    var body: some View {
        let m = target.entry.manifest
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.blue).font(.title2)
                VStack(alignment: .leading) {
                    Text("Restore Backup \(target.entry.name)").font(.headline)
                    Text("\(m.connectionName) › \(m.database)\(m.schema.map { ".\($0)" } ?? "") · \(m.objects.count) objects · \(m.method.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !m.comment.isEmpty { Text(m.comment).font(.callout) }
            Picker("Restore into", selection: $destination) {
                ForEach(destinations, id: \.key) { Text($0.title).tag($0.key) }
            }
            if m.method == .sql {
                Toggle("Drop existing objects before creating them", isOn: $dropExisting)
                Toggle("Continue on error", isOn: $continueOnError)
                Toggle("Run in a single transaction", isOn: $useTransaction)
            } else {
                Text("The database file's content is replaced by the copy.").font(.caption).foregroundStyle(.secondary)
            }
            if let report {
                ProgressView(value: report.fractionDone) {
                    Text("\(report.executed) of \(report.total) statements · \(report.errors.count) errors\(report.rolledBack ? " · rolled back" : "")")
                        .font(.caption)
                }
                if !report.errors.isEmpty {
                    List(report.errors) { error in
                        VStack(alignment: .leading) {
                            Text(error.message).foregroundStyle(.red)
                            Text(error.statement.prefix(200)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 120)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(finished ? "Close" : "Cancel", role: .cancel) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if !finished {
                    Button("Restore") { start() }.keyboardShortcut(.defaultAction)
                        .disabled(chosen == nil || task != nil || chosen?.driver.config.readOnly == true)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear {
            let own = "\(target.context.session?.id.uuidString ?? "")/\(target.context.name)"
            destination = destinations.contains { $0.key == own } ? own : destinations.first?.key ?? ""
        }
    }

    private func start() {
        guard let context = chosen else { return }
        let alert = NSAlert()
        alert.messageText = "Restore “\(target.entry.name)” into \(context.name)?"
        alert.informativeText = dropExisting || target.entry.manifest.method == .sqliteFile
            ? "Objects in the backup are replaced with the backup's structure and rows." : "Objects in the backup are created and filled."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = RestoreOptions(dropExisting: dropExisting, continueOnError: continueOnError, useTransaction: useTransaction)
        let entry = target.entry, store = app.automation.backupStore, driver = context.driver
        report = ScriptRunReport(total: 0)
        task = Task {
            do {
                let result = try await BackupEngine.restore(entry, store: store, into: driver, options: options) { r in
                    await MainActor.run { report = r }
                }
                report = result
                await context.refresh()
            } catch {
                app.alertMessage = "Restore failed: \(error.localizedDescription)"
            }
            finished = true
            task = nil
        }
    }
}
