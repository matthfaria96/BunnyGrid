import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// The database an "Execute SQL File" sheet runs against, and optionally a file already chosen.
struct SQLFileTarget: Identifiable {
    let id = UUID()
    let context: DatabaseContext
    var url: URL?
}

/// A .sql file split into statements and run with progress (Navicat's Execute SQL File).
/// Shared by the Execute SQL File sheet and the SQL mode of the Import Wizard.
@MainActor
@Observable
final class SQLScriptRun {
    private(set) var url: URL?
    private(set) var statements: [String] = []
    private(set) var fileSize = 0
    var options = ScriptRunOptions()
    private(set) var report: ScriptRunReport?
    private(set) var isRunning = false
    var loadError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isFinished: Bool { report != nil && !isRunning }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        loadError = nil
        report = nil
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                loadError = "Could not read the file as text."
                return
            }
            self.url = url
            fileSize = data.count
            statements = SQLSplitter.split(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Runs the statements; `onFinish` runs on the main actor afterwards (e.g. to refresh the navigator).
    func start(on driver: any DatabaseDriver, onFinish: @escaping @MainActor () async -> Void) {
        guard !statements.isEmpty, !isRunning else { return }
        isRunning = true
        report = ScriptRunReport(total: statements.count)
        let statements = statements, options = options
        task = Task {
            let final = await driver.runScript(statements, options: options) { [weak self] progress in
                await MainActor.run { self?.report = progress }
            }
            report = final
            isRunning = false
            await onFinish()
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// File, options, progress and errors of a script run, as Form sections.
struct SQLScriptRunSections: View {
    @Bindable var run: SQLScriptRun
    let context: DatabaseContext

    var body: some View {
        Section("SQL File") {
            HStack {
                Text(run.url?.path ?? "No file chosen").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(run.url == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { run.chooseFile() }.disabled(run.isRunning)
            }
            if run.url != nil {
                LabeledContent("Statements", value: run.statements.count.countText)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(run.fileSize), countStyle: .file))
            }
            if let error = run.loadError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        Section("Options") {
            Toggle("Stop on error", isOn: $run.options.stopOnError)
            Toggle("Run in a single transaction", isOn: $run.options.useTransaction)
            if run.options.useTransaction && (context.kind == .mysql || context.kind == .mariadb) {
                Text("MySQL commits implicitly on CREATE, ALTER and DROP, so those can't be rolled back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(run.isRunning)
        if let report = run.report {
            Section("Progress") {
                ProgressView(value: report.fractionDone) {
                    Text("\(report.executed.countText) of \(report.total.countText) statements")
                }
                HStack(spacing: 16) {
                    Label("\(report.succeeded.countText) succeeded", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Label("\(report.errors.count.countText) failed", systemImage: "xmark.circle")
                        .foregroundStyle(report.errors.isEmpty ? Color.secondary : Color.red)
                    if report.affectedRows > 0 {
                        Text("\(report.affectedRows.countText) rows affected").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if run.isFinished {
                    Text(summary(report)).font(.callout.weight(.medium))
                }
            }
            if !report.errors.isEmpty {
                Section("Errors") {
                    ForEach(report.errors.prefix(200)) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Statement \(error.index + 1): \(error.message)").foregroundStyle(.red)
                            Text(error.statement.prefix(300)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func summary(_ report: ScriptRunReport) -> String {
        if report.rolledBack { return "Stopped; the transaction was rolled back." }
        if report.stopped { return "Stopped after \(report.executed.countText) statements." }
        return report.errors.isEmpty ? "Finished without errors." : "Finished with \(report.errors.count.countText) errors."
    }
}

/// Navicat's "Execute SQL File" dialog on a connection or database.
struct ExecuteSQLFileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: SQLFileTarget
    @State private var run = SQLScriptRun()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.text.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading) {
                    Text("Execute SQL File").font(.headline)
                    Text("On \(target.context.location(schema: nil))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            Form { SQLScriptRunSections(run: run, context: target.context) }
                .formStyle(.grouped)
            Divider()
            HStack {
                if run.url != nil && !run.isRunning {
                    Button("Open in Query Editor") { openInEditor() }
                }
                Spacer()
                if run.isRunning {
                    Button("Stop") { run.stop() }
                } else {
                    Button(run.isFinished ? "Close" : "Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Start") {
                    let context = target.context
                    run.start(on: context.driver) { await Self.refresh(context) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(run.statements.isEmpty || run.isRunning || run.isFinished)
            }
            .padding()
        }
        .frame(width: 600, height: 560)
        .onAppear {
            if let url = target.url { run.load(url) }
            #if DEBUG
            if CommandLine.arguments.contains("--run-script") {
                run.options.stopOnError = false
                let context = target.context
                run.start(on: context.driver) { await Self.refresh(context) }
            }
            #endif
        }
    }

    private func openInEditor() {
        guard let url = run.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        app.openQuery(text: text, in: target.context)
        app.selectedQueryTab?.title = url.deletingPathExtension().lastPathComponent
        dismiss()
    }

    /// Reloads the object lists already shown, since the script may have created or dropped objects.
    static func refresh(_ context: DatabaseContext) async {
        for key in context.objectsBySchema.keys {
            await context.loadObjects(schema: key.isEmpty ? nil : key, force: true)
        }
    }
}
