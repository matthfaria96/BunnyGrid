import AppKit
import BunnyGridCore
import SwiftUI

/// Tools menu entries for Automation.
struct AutomationMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("Automation") { model.openAutomation() }
            .keyboardShortcut("j", modifiers: [.command, .shift])
        Button("New Backup…") {
            if let context = model.currentContext { model.automation.backupTarget = BackupTarget(context: context, schema: model.currentSchema) }
        }
        .disabled(model.currentContext == nil)
    }
}

/// Navicat's Automation: batch jobs on the left; the selected job's steps, schedule and history on the right.
struct AutomationView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var draft: BatchJob?
    @State private var pane: Pane = .steps
    @State private var selectedStep: UUID?
    @State private var selectedRun: UUID?

    enum Pane: String, CaseIterable { case steps = "Steps", schedule = "Schedule", history = "History" }

    private var automation: AutomationCenter { app.automation }
    private var saved: BatchJob? { automation.jobs.first { $0.id == selection } }
    private var isDirty: Bool { draft != nil && draft != saved }

    var body: some View {
        HSplitView {
            jobList.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            Group {
                if draft != nil { editor } else {
                    ContentUnavailableView("No Batch Job", systemImage: "gearshape.2",
                                           description: Text("Create a batch job to run queries, SQL files, backups and exports, by hand or on a schedule — also while BunnyGrid is closed."))
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Automation")
        .onAppear {
            automation.startWatching()
            if selection == nil { select(automation.jobs.first?.id) }
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "-automationPane"), CommandLine.arguments.indices.contains(index + 1),
               let p = Pane(rawValue: CommandLine.arguments[index + 1].capitalized) { pane = p }
            #endif
        }
        .onDisappear { automation.stopWatching() }
        .alert("Automation", isPresented: Binding(get: { automation.errorMessage != nil }, set: { if !$0 { automation.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(automation.errorMessage ?? "") }
    }

    private func select(_ id: UUID?) {
        selection = id
        draft = automation.jobs.first { $0.id == id }
        selectedStep = draft?.steps.first?.id
        selectedRun = nil
    }

    // MARK: - Job list

    private var jobList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selection }, set: { id in
                if isDirty, let draft { automation.save(draft) }
                select(id)
            })) {
                ForEach(automation.jobs) { job in
                    HStack {
                        Image(systemName: "gearshape.2").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name)
                            Text(job.runsOnSchedule ? job.schedule.summary() : "Manual only").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if automation.running[job.id] != nil {
                            ProgressView().controlSize(.small)
                        } else if let last = automation.runs(for: job.id).first {
                            statusIcon(last.status)
                        }
                    }
                    .tag(job.id)
                    .contextMenu {
                        Button("Run Now") { automation.run(job, app: app) }
                        Button("Delete", role: .destructive) { delete(job) }
                    }
                }
            }
            Divider()
            HStack(spacing: 2) {
                Button { let job = automation.newJob(); select(job.id) } label: { Image(systemName: "plus") }
                    .help("New Batch Job")
                Button { if let saved { delete(saved) } } label: { Image(systemName: "minus") }
                    .disabled(saved == nil).help("Delete Batch Job")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func delete(_ job: BatchJob) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(job.name)”?"
        alert.informativeText = "Its schedule and history are removed too."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        automation.delete(job.id)
        select(automation.jobs.first?.id)
    }

    @ViewBuilder
    private func statusIcon(_ status: JobRunStatus) -> some View {
        switch status {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .running: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .cancelled, .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - Editor

    private var draftBinding: Binding<BatchJob> {
        Binding(get: { draft ?? BatchJob(name: "") }, set: { draft = $0 })
    }

    private var editor: some View {
        let job = draftBinding
        let isRunning = automation.running[job.wrappedValue.id] != nil
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Name", text: job.name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("", selection: $pane) { ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                if isRunning {
                    Button { automation.cancel(job.wrappedValue.id) } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button {
                        if isDirty, let draft { automation.save(draft) }
                        automation.run(job.wrappedValue, app: app)
                        pane = .history
                        selectedRun = nil
                    } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(job.wrappedValue.steps.isEmpty)
                }
                Button("Save") { if let draft { automation.save(draft) } }
                    .keyboardShortcut("s")
                    .disabled(!isDirty)
            }
            .padding(10)
            Divider()
            switch pane {
            case .steps: StepsEditor(job: job, selection: $selectedStep)
            case .schedule: ScheduleEditor(job: job, installed: saved.map(automation.isScheduleInstalled) ?? false)
            case .history: HistoryView(runs: automation.runs(for: job.wrappedValue.id), selection: $selectedRun)
            }
        }
    }
}

// MARK: - Steps

private struct StepsEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var job: BatchJob
    @Binding var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($job.steps) { $step in
                        HStack {
                            Toggle("", isOn: $step.enabled).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: step.action.kind.systemImage).foregroundStyle(.secondary).frame(width: 18)
                            Text(JobRunner.title(of: step.action, connections: app.connections, savedQueries: app.savedQueries)).lineLimit(1)
                        }
                        .tag(step.id)
                    }
                    .onMove { job.steps.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(JobAction.Kind.allCases) { kind in
                            Button { add(kind) } label: { Label(kind.displayName, systemImage: kind.systemImage) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("Add Step")
                    Button {
                        job.steps.removeAll { $0.id == selection }
                        selection = job.steps.first?.id
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil).help("Remove Step")
                    Spacer()
                    Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 240, idealWidth: 300)
            Group {
                if let index = job.steps.firstIndex(where: { $0.id == selection }) {
                    ScrollView { StepForm(action: $job.steps[index].action).padding(16) }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add steps with +. They run in order.").foregroundStyle(.secondary)
                        Toggle("Continue with the next step when one fails", isOn: $job.continueOnError)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var defaultTarget: JobTarget {
        if let context = app.currentContext, let id = context.session?.id {
            return JobTarget(connectionID: id, database: context.name, schema: context.usesSchemas ? app.currentSchema : nil)
        }
        let first = app.connections.first
        return JobTarget(connectionID: first?.id ?? UUID(), database: first.map { $0.kind == .sqlite ? "main" : $0.database } ?? "")
    }

    private func add(_ kind: JobAction.Kind) {
        let target = defaultTarget
        let action: JobAction = switch kind {
        case .savedQuery: .savedQuery(queryID: app.savedQueries.first?.id ?? UUID())
        case .sql: .sql(target: target, sql: "")
        case .sqlFile: .sqlFile(target: target, path: "", options: ScriptRunOptions())
        case .backup: .backup(target: target, options: BackupOptions())
        case .export: .export(Self.exportDefaults(target))
        case .dataTransfer: .dataTransfer(DataTransferStepSettings(source: target, destination: target))
        }
        let step = JobStep(action: action)
        job.steps.append(step)
        selection = step.id
    }

    /// A new export step starts from the Export Wizard's last settings.
    static func exportDefaults(_ target: JobTarget) -> ExportStepSettings {
        let d = UserDefaults.standard
        return ExportStepSettings(
            target: target,
            format: d.string(forKey: "export.format").flatMap(TableExportFormat.init) ?? .csv,
            csvDelimiter: d.string(forKey: "export.csvDelimiter") ?? ",",
            includeHeader: d.object(forKey: "export.includeHeader") as? Bool ?? true,
            sqlStructure: d.object(forKey: "export.sqlStructure") as? Bool ?? true,
            sqlDrop: d.object(forKey: "export.sqlDrop") as? Bool ?? true,
            sqlData: d.object(forKey: "export.sqlData") as? Bool ?? true,
            rowsPerInsert: d.object(forKey: "export.sqlRowsPerInsert") as? Int ?? 1,
            singleWorkbook: d.object(forKey: "export.singleWorkbook") as? Bool ?? true,
            outputDirectory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/BunnyGrid Exports").path)
    }
}

/// The form of one step, by kind.
private struct StepForm: View {
    @Environment(AppModel.self) private var app
    @Binding var action: JobAction

    var body: some View {
        Form {
            switch action {
            case .savedQuery(let id):
                Picker("Saved query", selection: Binding(get: { id }, set: { action = .savedQuery(queryID: $0) })) {
                    if !app.savedQueries.contains(where: { $0.id == id }) { Text("Choose a query").tag(id) }
                    ForEach(app.savedQueries) { query in
                        Text("\(query.name) — \(app.connection(id: query.connectionID)?.displayName ?? "?") › \(query.database)").tag(query.id)
                    }
                }
                if app.savedQueries.isEmpty { Text("Save a query with ⌘S in a query tab first.").font(.caption).foregroundStyle(.secondary) }
            case .sql(let target, let sql):
                TargetFields(target: Binding(get: { target }, set: { action = .sql(target: $0, sql: sql) }))
                Section("SQL") {
                    TextEditor(text: Binding(get: { sql }, set: { action = .sql(target: target, sql: $0) }))
                        .font(.system(size: 12, design: .monospaced)).frame(minHeight: 160)
                }
            case .sqlFile(let target, let path, let options):
                TargetFields(target: Binding(get: { target }, set: { action = .sqlFile(target: $0, path: path, options: options) }))
                HStack {
                    TextField("SQL file", text: Binding(get: { path }, set: { action = .sqlFile(target: target, path: $0, options: options) }))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText, .plainText]
                        if panel.runModal() == .OK, let url = panel.url { action = .sqlFile(target: target, path: url.path, options: options) }
                    }
                }
                Toggle("Stop at the first error", isOn: Binding(get: { options.stopOnError }, set: {
                    action = .sqlFile(target: target, path: path, options: ScriptRunOptions(stopOnError: $0, useTransaction: options.useTransaction))
                }))
                Toggle("Run in a single transaction", isOn: Binding(get: { options.useTransaction }, set: {
                    action = .sqlFile(target: target, path: path, options: ScriptRunOptions(stopOnError: options.stopOnError, useTransaction: $0))
                }))
            case .backup(let target, let options):
                let set = { (o: BackupOptions) in action = .backup(target: target, options: o) }
                TargetFields(target: Binding(get: { target }, set: { action = .backup(target: $0, options: options) }), showsSchema: true)
                TextField("Comment", text: Binding(get: { options.comment }, set: { var o = options; o.comment = $0; set(o) }))
                if app.connection(id: target.connectionID)?.kind == .sqlite {
                    Picker("Method", selection: Binding(get: { options.method }, set: { var o = options; o.method = $0; set(o) })) {
                        ForEach(BackupMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                if options.method == .sql {
                    Toggle("Structure", isOn: Binding(get: { options.includeStructure }, set: { var o = options; o.includeStructure = $0; set(o) }))
                    Toggle("Data", isOn: Binding(get: { options.includeData }, set: { var o = options; o.includeData = $0; set(o) }))
                    ObjectNamesField(names: Binding(get: { options.objects?.map(\.name) ?? [] }, set: { names in
                        var o = options
                        o.objects = names.isEmpty ? nil : names.map { BackupObject(schema: target.schema, name: $0, kind: .table) }
                        set(o)
                    }))
                }
            case .export(let settings):
                ExportStepForm(settings: Binding(get: { settings }, set: { action = .export($0) }))
            case .dataTransfer(let settings):
                TransferStepForm(settings: Binding(get: { settings }, set: { action = .dataTransfer($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ObjectNamesField: View {
    @Binding var names: [String]

    var body: some View {
        TextField("Objects", text: Binding(get: { names.joined(separator: ", ") }, set: {
            names = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }), prompt: Text("All tables and views"))
        .help("Comma-separated names; empty means every table and view")
    }
}

private struct ExportStepForm: View {
    @Binding var settings: ExportStepSettings

    var body: some View {
        TargetFields(target: $settings.target, showsSchema: true)
        Picker("Format", selection: $settings.format) {
            ForEach(TableExportFormat.allCases) { Text($0.displayName).tag($0) }
        }
        switch settings.format {
        case .csv:
            Picker("Field delimiter", selection: $settings.csvDelimiter) {
                Text("Comma ( , )").tag(",")
                Text("Semicolon ( ; )").tag(";")
                Text("Tab").tag("\t")
                Text("Pipe ( | )").tag("|")
            }
            Toggle("Include field names", isOn: $settings.includeHeader)
        case .json: EmptyView()
        case .sql:
            Toggle("CREATE statements (structure)", isOn: $settings.sqlStructure)
            Toggle("DROP … IF EXISTS before CREATE", isOn: $settings.sqlDrop)
            Toggle("INSERT statements (data)", isOn: $settings.sqlData)
            Stepper("Rows per INSERT: \(settings.rowsPerInsert)", value: $settings.rowsPerInsert, in: 1...1000)
        case .xlsx:
            Toggle("One workbook, a sheet per object", isOn: $settings.singleWorkbook)
            Toggle("Include field names", isOn: $settings.includeHeader)
        }
        ObjectNamesField(names: Binding(get: { settings.objects.map(\.name) }, set: {
            settings.objects = $0.map { BackupObject(schema: settings.target.schema, name: $0, kind: .table) }
        }))
        HStack {
            TextField("Output folder", text: $settings.outputDirectory)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { settings.outputDirectory = url.path }
            }
        }
        Toggle("New dated folder on every run", isOn: $settings.timestampedFolder)
    }
}

private struct TransferStepForm: View {
    @Binding var settings: DataTransferStepSettings

    var body: some View {
        Section("Source") { TargetFields(target: $settings.source, showsSchema: true) }
        Section("Target") { TargetFields(target: $settings.destination, showsSchema: true) }
        Section("Options") {
            ObjectNamesField(names: $settings.tables)
            Toggle("Create tables", isOn: $settings.createTables)
            Toggle("Drop target tables first", isOn: $settings.dropTargetTables)
            Toggle("Transfer records", isOn: $settings.transferData)
            Toggle("Create indexes", isOn: $settings.createIndexes)
            Toggle("Create foreign keys", isOn: $settings.createForeignKeys)
            Toggle("Continue on error", isOn: $settings.continueOnError)
        }
    }
}

/// Connection and database (and schema on PostgreSQL) of a step.
private struct TargetFields: View {
    @Environment(AppModel.self) private var app
    @Binding var target: JobTarget
    var showsSchema = false

    var body: some View {
        let kind = app.connection(id: target.connectionID)?.kind
        Picker("Connection", selection: Binding(get: { target.connectionID }, set: { id in
            target.connectionID = id
            if let config = app.connection(id: id) {
                target.database = config.kind == .sqlite ? "main" : config.database
                target.schema = config.kind == .postgresql ? "public" : nil
            }
        })) {
            if kind == nil { Text("Missing connection").tag(target.connectionID) }
            ForEach(app.connections) { Text($0.displayName).tag($0.id) }
        }
        if kind != .sqlite {
            let known = app.sessions[target.connectionID]?.databases ?? []
            if known.isEmpty {
                TextField("Database", text: $target.database)
            } else {
                Picker("Database", selection: $target.database) {
                    if !known.contains(target.database) { Text(target.database.isEmpty ? "Choose" : target.database).tag(target.database) }
                    ForEach(known, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        if showsSchema && kind == .postgresql {
            TextField("Schema", text: Binding(get: { target.schema ?? "public" }, set: { target.schema = $0.isEmpty ? nil : $0 }))
        }
    }
}

// MARK: - Schedule

private struct ScheduleEditor: View {
    @Binding var job: BatchJob
    let installed: Bool
    @State private var cronError: String?

    var body: some View {
        Form {
            Section {
                Picker("Run", selection: Binding(get: { job.schedule.kind }, set: { job.schedule = Self.schedule(for: $0, from: job.schedule) })) {
                    ForEach(JobSchedule.Kind.allCases) { Text($0.displayName).tag($0) }
                }
                fields
                if job.schedule.isScheduled {
                    Toggle("Schedule active", isOn: $job.scheduleEnabled)
                }
            } footer: {
                Text(installed ? "Installed as a launch agent: it runs while BunnyGrid is closed. Save to apply changes."
                     : "Saving an active schedule installs a launch agent (~/Library/LaunchAgents) that runs the job while BunnyGrid is closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.schedule.isScheduled {
                Section("Next runs") {
                    let next = job.schedule.nextRuns(after: Date(), count: 5)
                    if next.isEmpty { Text(cronError ?? "None").foregroundStyle(.secondary) }
                    ForEach(next, id: \.self) { Text($0.formatted(date: .complete, time: .shortened)) }
                }
            }
            Section("Notifications") {
                Toggle("Notify when the job succeeds", isOn: $job.notifyOnSuccess)
                Toggle("Notify when the job fails", isOn: $job.notifyOnFailure)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var fields: some View {
        switch job.schedule {
        case .manual: EmptyView()
        case .once(let date):
            DatePicker("At", selection: Binding(get: { date }, set: { job.schedule = .once($0) }))
        case .hourly(let minute):
            Stepper("At minute \(minute)", value: Binding(get: { minute }, set: { job.schedule = .hourly(minute: $0) }), in: 0...59)
        case .daily(let h, let m):
            timePicker(h, m) { job.schedule = .daily(hour: $0, minute: $1) }
        case .weekly(let days, let h, let m):
            HStack {
                Text("On")
                Spacer()
                ForEach(1...7, id: \.self) { day in
                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(get: { days.contains(day) }, set: { on in
                        let updated = on ? days + [day] : days.filter { $0 != day }
                        job.schedule = .weekly(weekdays: updated.sorted(), hour: h, minute: m)
                    }))
                    .toggleStyle(.button)
                }
            }
            timePicker(h, m) { job.schedule = .weekly(weekdays: days, hour: $0, minute: $1) }
        case .monthly(let d, let h, let m):
            Stepper("On day \(d)", value: Binding(get: { d }, set: { job.schedule = .monthly(day: $0, hour: h, minute: m) }), in: 1...31)
            timePicker(h, m) { job.schedule = .monthly(day: d, hour: $0, minute: $1) }
        case .cron(let text):
            TextField("Expression", text: Binding(get: { text }, set: { job.schedule = .cron($0) }), prompt: Text("minute hour day month weekday"))
                .font(.system(.body, design: .monospaced))
            Text(cronMessage(text)).font(.caption).foregroundStyle(cronMessage(text).hasPrefix("e.g.") ? Color.secondary : Color.red)
        }
    }

    private func cronMessage(_ text: String) -> String {
        do {
            _ = try CronExpression(text).launchdCalendarIntervals()
            return "e.g. “0 3 * * 1-5” (03:00 on weekdays), “*/15 9-17 * * *”"
        } catch {
            return error.localizedDescription
        }
    }

    private func timePicker(_ hour: Int, _ minute: Int, set: @escaping (Int, Int) -> Void) -> some View {
        DatePicker("At", selection: Binding(get: {
            Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            set(c.hour ?? 0, c.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }

    static func schedule(for kind: JobSchedule.Kind, from current: JobSchedule) -> JobSchedule {
        guard kind != current.kind else { return current }
        switch kind {
        case .manual: return .manual
        case .once: return .once(Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date())
        case .hourly: return .hourly(minute: 0)
        case .daily: return .daily(hour: 3, minute: 0)
        case .weekly: return .weekly(weekdays: [2], hour: 3, minute: 0)
        case .monthly: return .monthly(day: 1, hour: 3, minute: 0)
        case .cron: return .cron((try? current.cronExpression())??.text ?? "0 3 * * *")
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    @Environment(AppModel.self) private var app
    let runs: [JobRun]
    @Binding var selection: UUID?

    private var shown: JobRun? { runs.first { $0.id == selection } ?? runs.first }

    var body: some View {
        VSplitView {
            Table(runs, selection: $selection) {
                TableColumn("Started") { run in Text(run.startedAt.formatted(date: .numeric, time: .standard)) }
                    .width(min: 150, ideal: 180)
                TableColumn("Status") { run in Text(run.status.displayName).foregroundStyle(run.status == .failed ? .red : .primary) }
                    .width(min: 70, ideal: 90)
                TableColumn("Trigger") { run in Text(run.trigger == .scheduled ? "Schedule" : "Manual").foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn("Duration") { run in Text(run.duration.map { String(format: "%.1f s", $0) } ?? "…").monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Result") { run in Text(run.summary).lineLimit(1).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Delete", role: .destructive) { for id in ids { app.automation.deleteRun(id) } }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .overlay { if runs.isEmpty { Text("Not run yet").foregroundStyle(.tertiary) } }
            .frame(minHeight: 140)
            ScrollView {
                Text(shown?.log ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 120)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
