import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// Navicat's Data Transfer, Data Synchronization and Structure Synchronization, as one sheet:
/// source and target pickers on top, the tool's objects and options, then the log while it runs.
struct SyncWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: SyncWizardRequest

    @State private var source: SyncEndpoint?
    @State private var target: SyncEndpoint?
    @State private var log: [LogLine] = []
    @State private var fraction: Double?
    @State private var task: Task<Void, Never>?
    @State private var finished = false

    // Data Transfer
    @State private var selectedTables: Set<String> = []
    @State private var toFile = false
    @State private var fileKind: DatabaseKind = .postgresql
    @AppStorage("transfer.createTables") private var createTables = true
    @AppStorage("transfer.dropTarget") private var dropTarget = false
    @AppStorage("transfer.data") private var transferData = true
    @AppStorage("transfer.indexes") private var createIndexes = true
    @AppStorage("transfer.foreignKeys") private var createForeignKeys = true
    @AppStorage("transfer.continueOnError") private var continueOnError = false
    @AppStorage("transfer.rowsPerBatch") private var rowsPerBatch = 500

    // Structure Synchronization
    @State private var structure: StructureComparison?
    @State private var selectedDifferences: Set<String> = []

    // Data Synchronization
    @State private var dataResults: [DataComparison] = []
    @State private var selectedRows: [String: Set<Int>] = [:]

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var isRunning: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: request.tool.title, systemImage: request.tool.symbol)
            Divider()
            if let source, let target {
                HStack(alignment: .top, spacing: 12) {
                    EndpointPicker(title: "Source", endpoint: source)
                    Image(systemName: "arrow.right").font(.title3).foregroundStyle(.secondary).padding(.top, 28)
                    if request.tool == .dataTransfer {
                        // "Target" lines up with "Source"; the Connection / SQL File switch sits on the title row.
                        Group {
                            if toFile {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Target").font(.subheadline.weight(.semibold))
                                    Picker("SQL dialect", selection: $fileKind) {
                                        ForEach([DatabaseKind.postgresql, .mysql, .mariadb, .sqlite], id: \.self) { Text($0.displayName).tag($0) }
                                    }
                                    .fixedSize()
                                    Spacer(minLength: 0)
                                }
                            } else {
                                EndpointPicker(title: "Target", endpoint: target)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .topTrailing) {
                            Picker("", selection: $toFile) {
                                Text("Connection").tag(false)
                                Text("SQL File").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                            .offset(y: -3)
                        }
                    } else {
                        EndpointPicker(title: "Target", endpoint: target)
                    }
                }
                .disabled(isRunning)
                Divider()
                switch request.tool {
                case .dataTransfer: transferContent(source: source)
                case .structureSync: structureContent(source: source, target: target)
                case .dataSync: dataContent(source: source, target: target)
                }
                logView
                buttons(source: source, target: target)
            } else {
                ProgressView()
            }
        }
        .padding(20)
        .frame(width: 820, height: 680)
        .onAppear {
            source = SyncEndpoint(app: app, connectionID: request.connectionID, database: request.database, schema: request.schema)
            target = SyncEndpoint(app: app, connectionID: request.targetConnectionID,
                                  database: request.targetConnectionID == nil ? nil : "main")
            #if DEBUG
            if CommandLine.arguments.contains("--sync-compare") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if let source, let target { primaryAction(source: source, target: target) }
                }
            }
            #endif
        }
    }

    // MARK: - Data Transfer

    @ViewBuilder
    private func transferContent(source: SyncEndpoint) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tables (\(selectedTables.count) of \(source.tables.count))").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Select All") { selectedTables = Set(source.tables.map(\.name)) }
                    Button("Deselect All") { selectedTables = [] }
                }
                .controlSize(.small)
                List(source.tables) { object in
                    Toggle(isOn: binding(object.name, in: $selectedTables)) {
                        Label { Text(object.name) } icon: { AppIcon(name: object.kind.iconName, size: 16) }
                    }
                }
                .task(id: "\(source.label)\(source.isReady)") {
                    await source.loadTables()
                    if selectedTables.isEmpty || !selectedTables.isSubset(of: Set(source.tables.map(\.name))) {
                        selectedTables = Set(source.tables.map(\.name))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Options").font(.subheadline.weight(.semibold))
                Toggle("Create tables", isOn: $createTables)
                Toggle("Drop target tables first", isOn: $dropTarget)
                Toggle("Transfer records", isOn: $transferData)
                Toggle("Create indexes", isOn: $createIndexes)
                Toggle("Create foreign keys", isOn: $createForeignKeys)
                Toggle("Continue on error", isOn: $continueOnError)
                Stepper("Rows per batch: \(rowsPerBatch)", value: $rowsPerBatch, in: 1...5000, step: rowsPerBatch < 50 ? 10 : 100)
            }
            .frame(width: 240, alignment: .leading)
            .disabled(isRunning)
        }
        .frame(maxHeight: .infinity)
    }

    private func runTransfer(source: SyncEndpoint, target: SyncEndpoint) {
        let tables = source.tables.map(\.name).filter(selectedTables.contains)
        let options = DataTransferOptions(createTables: createTables, dropTargetTables: dropTarget, transferData: transferData,
                                          createIndexes: createIndexes, createForeignKeys: createForeignKeys,
                                          continueOnError: continueOnError, rowsPerBatch: rowsPerBatch)
        var fileURL: URL?
        if toFile {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
            panel.nameFieldStringValue = "\(source.database ?? "transfer").sql"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            fileURL = url
        }
        let kind = fileKind
        let sourceSchema = source.driverSchema
        start { report in
            let sourceDriver = try await source.makeDriver()
            defer { Task { await sourceDriver.disconnect() } }
            let destination: TransferDestination
            var targetDriver: (any DatabaseDriver)?
            var handle: FileHandle?
            if let fileURL {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                let file = try FileHandle(forWritingTo: fileURL)
                handle = file
                destination = .script(kind: kind, schema: kind == .postgresql ? "public" : nil, write: { text in file.write(Data(text.utf8)) })
            } else {
                let driver = try await target.makeDriver()
                targetDriver = driver
                destination = .database(driver, schema: await MainActor.run { target.driverSchema })
            }
            defer {
                try? handle?.close()
                if let targetDriver { Task { await targetDriver.disconnect() } }
            }
            let summary = try await DataTransfer(source: sourceDriver, sourceSchema: sourceSchema, tables: tables,
                                                 destination: destination, options: options).run { event in await report(event) }
            await report(.log("Finished: \(countLabel(summary.tables, "table")), \(countLabel(summary.rows, "record")), \(countLabel(summary.errors, "error"))."))
            if let fileURL { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } }
            if await MainActor.run(body: { target.context }) != nil, fileURL == nil {
                await target.context?.loadObjects(schema: target.schema, force: true)
            }
        }
    }

    // MARK: - Structure Synchronization

    @ViewBuilder
    private func structureContent(source: SyncEndpoint, target: SyncEndpoint) -> some View {
        HSplitView {
            List {
                if let structure {
                    if structure.differences.isEmpty { Text("The target already matches the source.").foregroundStyle(.secondary) }
                    ForEach(SchemaDifference.Action.allCases, id: \.self) { action in
                        let items = structure.differences.filter { $0.action == action }
                        if !items.isEmpty {
                            Section(action.title) {
                                ForEach(items) { item in
                                    Toggle(isOn: binding(item.id, in: $selectedDifferences)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Label { Text(item.name) } icon: { AppIcon(name: item.kind == .table ? "table" : "view", size: 16) }
                                            ForEach(item.details.prefix(8), id: \.self) { line in
                                                Text(line).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    ForEach(structure.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("Pick the source and target, then Compare.").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 320)
            ScrollView {
                Text(scriptPreview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(minWidth: 300)
        }
        .frame(maxHeight: .infinity)
    }

    private var scriptPreview: String {
        guard let structure else { return "-- Deployment script" }
        do { return try structure.deployScriptText(for: selectedDifferences) } catch { return "-- \(error.localizedDescription)" }
    }

    private func compareStructure(source: SyncEndpoint, target: SyncEndpoint) {
        let sourceSchema = source.driverSchema, targetSchema = target.driverSchema
        start { report in
            let s = try await source.makeDriver(), t = try await target.makeDriver()
            defer { Task { await s.disconnect(); await t.disconnect() } }
            await report(.log("Reading structures…"))
            let comparison = StructureSync.compare(source: try await SchemaSnapshot.read(from: s, schema: sourceSchema),
                                                   target: try await SchemaSnapshot.read(from: t, schema: targetSchema))
            await MainActor.run {
                structure = comparison
                selectedDifferences = Set(comparison.differences.filter { $0.action != .drop }.map(\.id))
            }
            await report(.log("\(countLabel(comparison.differences.count, "difference"))."))
        }
    }

    private func deployStructure(target: SyncEndpoint) {
        guard let structure else { return }
        let statements: [String]
        do { statements = try structure.deployScript(for: selectedDifferences) } catch {
            log.append(LogLine(text: error.localizedDescription, isError: true)); return
        }
        start { report in
            let t = try await target.makeDriver()
            defer { Task { await t.disconnect() } }
            await report(.log("Running \(countLabel(statements.count, "statement"))…"))
            try await StructureSync.deploy(statements, on: t)
            await report(.log("Deployed."))
            await target.context?.loadObjects(schema: target.schema, force: true)
            await MainActor.run { self.structure = nil }
        }
    }

    // MARK: - Data Synchronization

    @ViewBuilder
    private func dataContent(source: SyncEndpoint, target: SyncEndpoint) -> some View {
        let targetNames = Set(target.tables.map { $0.name.lowercased() })
        let pairs = source.tables.filter { targetNames.contains($0.name.lowercased()) }
        HSplitView {
            VStack(alignment: .leading) {
                Text("Tables in both (\(pairs.count))").font(.subheadline.weight(.semibold))
                List(pairs) { object in
                    Toggle(object.name, isOn: binding(object.name, in: $selectedTables))
                }
            }
            .frame(minWidth: 200, maxWidth: 260)
            .task(id: "\(source.label)\(source.isReady)\(target.label)\(target.isReady)") {
                await source.loadTables()
                await target.loadTables()
                selectedTables = Set(source.tables.filter { t in target.tables.contains { $0.name.lowercased() == t.name.lowercased() } }.map(\.name))
            }
            List {
                if dataResults.isEmpty { Text("Choose tables, then Compare.").foregroundStyle(.secondary) }
                ForEach(dataResults) { result in
                    Section {
                        ForEach(RowDifference.Kind.allCases, id: \.self) { kind in
                            let rows = result.differences.filter { $0.kind == kind }
                            if !rows.isEmpty {
                                DisclosureGroup {
                                    ForEach(rows.prefix(200)) { row in
                                        Toggle(isOn: rowBinding(result.targetTable, row.id)) {
                                            Text(rowText(row, result)).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                        }
                                    }
                                    if rows.count > 200 { Text("… and \(rows.count - 200) more").font(.caption).foregroundStyle(.secondary) }
                                } label: {
                                    Toggle("\(kind.title) \(rows.count)", isOn: kindBinding(result, kind))
                                }
                            }
                        }
                    } header: {
                        Text("\(result.targetTable): \(result.identicalRows) identical, \(result.count(.insert)) insert, \(result.count(.update)) update, \(result.count(.delete)) delete")
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func rowText(_ row: RowDifference, _ result: DataComparison) -> String {
        let key = zip(result.keyColumns, row.key).map { "\($0)=\($1.displayString)" }.joined(separator: ", ")
        switch row.kind {
        case .update:
            let changes = row.changedColumns.compactMap { name -> String? in
                guard let i = result.columns.firstIndex(of: name) else { return nil }
                return "\(name): \(row.target?[i].displayString ?? "") → \(row.source?[i].displayString ?? "")"
            }
            return "[\(key)] " + changes.joined(separator: "; ")
        default:
            return "[\(key)] " + ((row.source ?? row.target) ?? []).map(\.displayString).joined(separator: " | ")
        }
    }

    private func rowBinding(_ table: String, _ id: Int) -> Binding<Bool> {
        Binding(get: { selectedRows[table]?.contains(id) ?? false },
                set: { if $0 { selectedRows[table, default: []].insert(id) } else { selectedRows[table]?.remove(id) } })
    }

    private func kindBinding(_ result: DataComparison, _ kind: RowDifference.Kind) -> Binding<Bool> {
        let ids = Set(result.differences.filter { $0.kind == kind }.map(\.id))
        return Binding(get: { !ids.isEmpty && ids.isSubset(of: selectedRows[result.targetTable] ?? []) },
                       set: { on in
                           if on { selectedRows[result.targetTable, default: []].formUnion(ids) } else { selectedRows[result.targetTable]?.subtract(ids) }
                       })
    }

    private func compareData(source: SyncEndpoint, target: SyncEndpoint) {
        let tables = source.tables.map(\.name).filter(selectedTables.contains)
        let targetTables = target.tables
        let sourceSchema = source.driverSchema, targetSchema = target.driverSchema
        start { report in
            let s = try await source.makeDriver(), t = try await target.makeDriver()
            defer { Task { await s.disconnect(); await t.disconnect() } }
            var results: [DataComparison] = []
            for (index, name) in tables.enumerated() {
                await report(.tableStarted(name, index: index, count: tables.count))
                let targetName = targetTables.first { $0.name.lowercased() == name.lowercased() }?.name ?? name
                do {
                    results.append(try await DataSync.compare(source: s, sourceSchema: sourceSchema, sourceTable: name,
                                                              target: t, targetSchema: targetSchema, targetTable: targetName))
                } catch {
                    await report(.error("\(name): \(error.localizedDescription)"))
                }
            }
            await MainActor.run {
                dataResults = results
                selectedRows = Dictionary(uniqueKeysWithValues: results.map { ($0.targetTable, Set($0.differences.map(\.id))) })
            }
            await report(.log("Compared \(countLabel(results.count, "table")): \(countLabel(results.reduce(0) { $0 + $1.differences.count }, "difference"))."))
        }
    }

    private func applyData(target: SyncEndpoint) {
        let entries = dataResults.map { ($0, selectedRows[$0.targetTable] ?? []) }.filter { !$0.1.isEmpty }
        let schema = target.driverSchema, batch = rowsPerBatch
        start { report in
            let t = try await target.makeDriver()
            defer { Task { await t.disconnect() } }
            let changed = try await DataSync.apply(entries.map { (comparison: $0.0, selection: Optional($0.1)) }, to: t, schema: schema,
                                                   batchSize: batch) { await report($0) }
            await report(.log("Committed: \(countLabel(changed, "row")) changed."))
            await MainActor.run { dataResults = [] }
        }
    }

    private func copyDataScript(target: SyncEndpoint) {
        guard let kind = target.kind else { return }
        let script = dataResults.map { $0.script(for: selectedRows[$0.targetTable], kind: kind, schema: target.driverSchema) }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        log.append(LogLine(text: "Script copied to the clipboard.", isError: false))
    }

    // MARK: - Running

    private func start(_ work: @escaping @Sendable (@escaping @Sendable (TransferEvent) async -> Void) async throws -> Void) {
        finished = false
        fraction = 0
        let report: @Sendable (TransferEvent) async -> Void = { event in await MainActor.run { handle(event) } }
        task = Task {
            do {
                try await work(report)
            } catch is CancellationError {
                log.append(LogLine(text: "Cancelled.", isError: true))
            } catch {
                log.append(LogLine(text: error.localizedDescription, isError: true))
            }
            fraction = nil
            task = nil
            finished = true
        }
    }

    private func handle(_ event: TransferEvent) {
        switch event {
        case .tableStarted(let name, let index, let count):
            log.append(LogLine(text: "[\(index + 1)/\(count)] \(name)", isError: false))
            fraction = Double(index) / Double(max(count, 1))
        case .rowsCopied(let name, let copied, let total):
            let line = "\(name): \(copied)\(total.map { " of \($0)" } ?? "") record\((total ?? copied) == 1 ? "" : "s")"
            if let last = log.last, last.text.hasPrefix("\(name): "), !last.isError { log[log.count - 1] = LogLine(text: line, isError: false) } else {
                log.append(LogLine(text: line, isError: false))
            }
        case .log(let text): log.append(LogLine(text: text, isError: false))
        case .error(let text): log.append(LogLine(text: text, isError: true))
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction { ProgressView(value: fraction) }
            ScrollViewReader { proxy in
                List(log) { line in
                    Text(line.text).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.isError ? .red : .primary).id(line.id)
                }
                .onChange(of: log.count) { if let last = log.last { proxy.scrollTo(last.id) } }
            }
            .frame(height: 110)
        }
    }

    private func buttons(source: SyncEndpoint, target: SyncEndpoint) -> some View {
        HStack {
            if request.tool == .dataSync, !dataResults.isEmpty {
                Button("Copy Script") { copyDataScript(target: target) }
            }
            Spacer()
            if isRunning {
                Button("Stop") { task?.cancel() }
            }
            Button(finished ? "Close" : "Cancel", role: .cancel) { task?.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
            switch request.tool {
            case .dataTransfer:
                Button("Start") { primaryAction(source: source, target: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || !source.isReady || selectedTables.isEmpty || (!toFile && !target.isReady))
            case .structureSync:
                Button("Compare") { compareStructure(source: source, target: target) }
                    .disabled(isRunning || !source.isReady || !target.isReady)
                Button("Deploy") { deployStructure(target: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || structure == nil || selectedDifferences.isEmpty)
            case .dataSync:
                Button("Compare") { compareData(source: source, target: target) }
                    .disabled(isRunning || !source.isReady || !target.isReady || selectedTables.isEmpty)
                Button("Apply") { applyData(target: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || dataResults.isEmpty || selectedRows.values.allSatisfy(\.isEmpty))
            }
        }
    }

    private func primaryAction(source: SyncEndpoint, target: SyncEndpoint) {
        switch request.tool {
        case .dataTransfer: runTransfer(source: source, target: target)
        case .structureSync: compareStructure(source: source, target: target)
        case .dataSync: compareData(source: source, target: target)
        }
    }

    private func binding(_ name: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(name) },
                set: { if $0 { set.wrappedValue.insert(name) } else { set.wrappedValue.remove(name) } })
    }
}

/// Connection → database → schema pickers for one side of a wizard.
private struct EndpointPicker: View {
    @Environment(AppModel.self) private var app
    let title: String
    @Bindable var endpoint: SyncEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Form {
                Picker("Connection", selection: $endpoint.connectionID) {
                    Text("Choose…").tag(UUID?.none)
                    // Data Transfer / Sync work on SQL engines only; Redis and MongoDB aren't offered.
                    ForEach(app.connections.filter { $0.kind != .redis && !$0.kind.isDocumentStore }) { config in
                        Text("\(config.name) (\(config.kind.displayName))").tag(Optional(config.id))
                    }
                }
                if let session = endpoint.session {
                    switch session.state {
                    case .connecting: ProgressView().controlSize(.small)
                    case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
                    case .connected:
                        if endpoint.kind != .sqlite {
                            Picker("Database", selection: $endpoint.database) {
                                Text("Choose…").tag(String?.none)
                                ForEach(endpoint.databases, id: \.self) { Text($0).tag(Optional($0)) }
                            }
                        }
                        if endpoint.usesSchemas, endpoint.context?.isOpen == true {
                            Picker("Schema", selection: $endpoint.schema) {
                                Text("Choose…").tag(String?.none)
                                ForEach(endpoint.schemas, id: \.self) { Text($0).tag(Optional($0)) }
                            }
                        }
                        if case .failed(let message) = endpoint.context?.state {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.columns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
