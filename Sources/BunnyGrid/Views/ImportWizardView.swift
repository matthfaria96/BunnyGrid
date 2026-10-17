import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// What the Import Wizard reads.
enum ImportSourceKind: String, CaseIterable, Identifiable {
    case csv, json, sql
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .csv: "CSV / TSV"
        case .json: "JSON"
        case .sql: "SQL File"
        }
    }
}

/// Imports a CSV/TSV or JSON file into an existing table (file → options and preview → field mapping → import),
/// or runs a .sql file against the table's database.
struct ImportWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ImportTarget

    @State private var kind: ImportSourceKind = .csv
    @State private var fileURL: URL?
    @State private var csvText = ""
    @State private var jsonTable: ImportedTable?
    @State private var delimiter: Character = ","
    @State private var hasHeader = true
    @State private var emptyAsNull = true
    /// The parsed source: headers and rows (CSV cells are text).
    @State private var source = ImportedTable(columns: [], rows: [])
    @State private var targetColumns: [BunnyGridCore.TableColumn] = []
    /// Source column index → target column name (nil = skip).
    @State private var mapping: [Int: String] = [:]
    @State private var isImporting = false
    @State private var result: String?
    @State private var error: String?
    @State private var sqlRun = SQLScriptRun()

    private var hasFile: Bool { kind == .csv ? !csvText.isEmpty : jsonTable != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.teal).font(.title2)
                VStack(alignment: .leading) {
                    Text("Import Wizard").font(.headline)
                    Text(kind == .sql
                         ? "Runs a script on \(target.context.location(schema: target.object.schema))"
                         : "Into \(target.object.qualifiedName) \(target.context.location(schema: target.object.schema))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Import type", selection: $kind) {
                    ForEach(ImportSourceKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isImporting || sqlRun.isRunning)
            }
            .padding()
            Divider()
            Form {
                if kind == .sql {
                    SQLScriptRunSections(run: sqlRun, context: target.context)
                } else {
                    dataSections
                }
            }
            .formStyle(.grouped)
            Divider()
            footer.padding()
        }
        .frame(width: 660, height: 620)
        .task {
            await loadColumns()
            #if DEBUG
            // --import-wizard csv|json|sql [FILE]
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--import-wizard"), args.indices.contains(index + 1),
               let debugKind = ImportSourceKind(rawValue: args[index + 1]) {
                kind = debugKind
                if args.indices.contains(index + 2), !args[index + 2].hasPrefix("-") {
                    try? await Task.sleep(for: .milliseconds(50))
                    let url = URL(fileURLWithPath: args[index + 2])
                    if debugKind == .sql { sqlRun.load(url) } else { load(url) }
                }
            }
            #endif
        }
        .onChange(of: kind) { _, _ in resetFile() }
        .onChange(of: hasHeader) { _, _ in reparse() }
        .onChange(of: delimiter) { _, _ in reparse() }
    }

    @ViewBuilder
    private var dataSections: some View {
        Section("Source File") {
            HStack {
                Text(fileURL?.path ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(fileURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…", action: chooseFile)
            }
            if kind == .json {
                Text("An array of objects, an object holding one such array, or one object per line (JSON Lines). Nested values are imported as JSON text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if hasFile {
            Section("Options") {
                if kind == .csv {
                    Picker("Field delimiter", selection: Binding(get: { String(delimiter) }, set: { delimiter = $0.first ?? "," })) {
                        Text("Comma ( , )").tag(",")
                        Text("Semicolon ( ; )").tag(";")
                        Text("Tab").tag("\t")
                        Text("Pipe ( | )").tag("|")
                    }
                    Toggle("First row contains field names", isOn: $hasHeader)
                }
                Toggle("Import empty fields as NULL", isOn: $emptyAsNull)
            }
            Section("Preview (\(source.rows.count.formatted()) records)") {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            ForEach(Array(source.columns.enumerated()), id: \.offset) { _, header in
                                Text(header).font(.system(size: 11, weight: .semibold))
                            }
                        }
                        ForEach(Array(source.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                    Text(preview(value)).font(.system(size: 11)).lineLimit(1)
                                        .foregroundStyle(value.isNull ? .secondary : .primary)
                                }
                            }
                        }
                    }
                }
            }
            Section("Field Mapping") {
                ForEach(Array(source.columns.enumerated()), id: \.offset) { index, header in
                    Picker(header, selection: Binding(
                        get: { mapping[index] ?? "" },
                        set: { mapping[index] = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("(skip)").tag("")
                        ForEach(targetColumns) { column in
                            Text("\(column.name)  \(column.dataType)").tag(column.name)
                        }
                    }
                }
            }
        }
        if let result {
            Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        if let error {
            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if kind == .sql {
                Spacer()
                if sqlRun.isRunning {
                    Button("Stop") { sqlRun.stop() }
                } else {
                    Button(sqlRun.isFinished ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button("Start") {
                    let context = target.context, object = target.object
                    sqlRun.start(on: context.driver) {
                        await ExecuteSQLFileView.refresh(context)
                        reloadTabs(showing: object)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sqlRun.statements.isEmpty || sqlRun.isRunning || sqlRun.isFinished)
            } else {
                if isImporting { ProgressView().controlSize(.small); Text("Importing…").foregroundStyle(.secondary) }
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(source.rows.count.formatted()) Records") { Task { await runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasFile || mapping.isEmpty || isImporting || result != nil || source.rows.isEmpty)
            }
        }
    }

    private func preview(_ value: CellValue) -> String {
        switch value {
        case .null: "(Null)"
        case .text(let s) where s.isEmpty: "—"
        default: value.displayString
        }
    }

    private var driverSchema: String? {
        switch target.context.kind {
        case .postgresql: target.object.schema
        case .mysql, .mariadb, .mongodb: target.context.name
        case .sqlite: nil
        }
    }

    private func loadColumns() async {
        targetColumns = (try? await target.context.driver.listColumns(table: target.object.name, schema: driverSchema)) ?? []
    }

    private func resetFile() {
        fileURL = nil
        csvText = ""
        jsonTable = nil
        source = ImportedTable(columns: [], rows: [])
        mapping = [:]
        result = nil
        error = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind == .json
            ? [.json, .plainText, .text]
            : [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        resetFile()
        do {
            let data = try Data(contentsOf: url)
            switch kind {
            case .json:
                jsonTable = try JSONTableReader.read(data)
            case .csv, .sql:
                guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    error = "Could not read the file as text."
                    return
                }
                csvText = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
                delimiter = url.pathExtension.lowercased() == "tsv" ? "\t" : CSVParser.detectDelimiter(csvText)
            }
            fileURL = url
            reparse()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Rebuilds the source table from the file and the CSV options, then maps fields again.
    private func reparse() {
        switch kind {
        case .json:
            source = jsonTable ?? ImportedTable(columns: [], rows: [])
        case .csv, .sql:
            let rows = CSVParser.parse(csvText, delimiter: delimiter)
            let headers = rows.first.map { first in hasHeader ? first : first.indices.map { "Column \($0 + 1)" } } ?? []
            let data = hasHeader ? Array(rows.dropFirst()) : rows
            source = ImportedTable(columns: headers, rows: data.map { $0.map(CellValue.text) })
        }
        autoMap()
    }

    /// Maps source columns to target columns with the same name (case-insensitive), or by position without a header row.
    private func autoMap() {
        mapping = [:]
        let byName = kind == .json || hasHeader
        for (index, header) in source.columns.enumerated() {
            if byName {
                if let column = targetColumns.first(where: { $0.name.caseInsensitiveCompare(header.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                    mapping[index] = column.name
                }
            } else if targetColumns.indices.contains(index) {
                mapping[index] = targetColumns[index].name
            }
        }
    }

    private func runImport() async {
        isImporting = true
        error = nil
        defer { isImporting = false }
        let mapped = mapping.sorted { $0.key < $1.key }
        let changes: [RowChange] = source.rows.map { row in
            .insert(values: mapped.map { index, column in
                let value = row.indices.contains(index) ? row[index] : .null
                if case .text(let raw) = value, raw.isEmpty { return ColumnValue(column, emptyAsNull ? .null : value) }
                return ColumnValue(column, value)
            })
        }
        do {
            try await target.context.driver.applyChanges(changes, table: target.object.name, schema: driverSchema, columns: targetColumns)
            result = "Imported \(changes.count.formatted()) records into \(target.object.name)."
            reloadTabs(showing: target.object)
        } catch {
            self.error = "Nothing was imported: \(error.localizedDescription)"
        }
    }

    private func reloadTabs(showing object: DatabaseObject) {
        for tab in app.tabs {
            if case .table(let model) = tab, model.object == object { model.requestReload() }
        }
    }
}

/// Asks for a name the first time a query is saved.
struct SaveQuerySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let tab: QueryTabModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Query").font(.headline)
            Text("Saved queries appear in the Queries folder of \(tab.location).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Query name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear { name = tab.title.hasPrefix("Query ") ? "" : tab.title }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.saveQuery(tab, name: name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}
