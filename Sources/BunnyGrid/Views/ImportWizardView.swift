import AppKit
import BunnyGridCore
import SwiftUI

/// Imports a CSV/TSV file into an existing table: file → options and preview → field mapping → import.
struct ImportWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ImportTarget

    @State private var fileURL: URL?
    @State private var text = ""
    @State private var delimiter: Character = ","
    @State private var hasHeader = true
    @State private var emptyAsNull = true
    @State private var targetColumns: [BunnyGridCore.TableColumn] = []
    /// Source column index → target column name (nil = skip).
    @State private var mapping: [Int: String] = [:]
    @State private var isImporting = false
    @State private var result: String?
    @State private var error: String?

    private var rows: [[String]] { CSVParser.parse(text, delimiter: delimiter) }
    private var headers: [String] {
        guard let first = rows.first else { return [] }
        return hasHeader ? first : first.indices.map { "Column \($0 + 1)" }
    }
    private var dataRows: [[String]] { hasHeader ? Array(rows.dropFirst()) : rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.teal).font(.title2)
                VStack(alignment: .leading) {
                    Text("Import Wizard").font(.headline)
                    Text("Into \(target.object.qualifiedName) \(target.context.location(schema: target.object.schema))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            Form {
                Section("Source File") {
                    HStack {
                        Text(fileURL?.path ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(fileURL == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…", action: chooseFile)
                    }
                }
                if !text.isEmpty {
                    Section("Options") {
                        Picker("Field delimiter", selection: Binding(get: { String(delimiter) }, set: { delimiter = $0.first ?? "," })) {
                            Text("Comma ( , )").tag(",")
                            Text("Semicolon ( ; )").tag(";")
                            Text("Tab").tag("\t")
                            Text("Pipe ( | )").tag("|")
                        }
                        Toggle("First row contains field names", isOn: $hasHeader)
                        Toggle("Import empty fields as NULL", isOn: $emptyAsNull)
                    }
                    Section("Preview (\(dataRows.count.formatted()) records)") {
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                GridRow {
                                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                                        Text(header).font(.system(size: 11, weight: .semibold))
                                    }
                                }
                                ForEach(Array(dataRows.prefix(5).enumerated()), id: \.offset) { _, row in
                                    GridRow {
                                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                            Text(value.isEmpty ? "—" : value).font(.system(size: 11)).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section("Field Mapping") {
                        ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
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
            .formStyle(.grouped)
            Divider()
            HStack {
                if isImporting { ProgressView().controlSize(.small); Text("Importing…").foregroundStyle(.secondary) }
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(dataRows.count.formatted()) Records") { Task { await runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || mapping.isEmpty || isImporting || result != nil || dataRows.isEmpty)
            }
            .padding()
        }
        .frame(width: 640, height: 600)
        .task { await loadColumns() }
        .onChange(of: hasHeader) { _, _ in autoMap() }
        .onChange(of: delimiter) { _, _ in autoMap() }
    }

    private var driverSchema: String? {
        switch target.context.kind {
        case .postgresql: target.object.schema
        case .mysql, .mariadb: target.context.name
        case .sqlite: nil
        }
    }

    private func loadColumns() async {
        targetColumns = (try? await target.context.driver.listColumns(table: target.object.name, schema: driverSchema)) ?? []
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                error = "Could not read the file as text."
                return
            }
            fileURL = url
            text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
            delimiter = url.pathExtension.lowercased() == "tsv" ? "\t" : CSVParser.detectDelimiter(text)
            result = nil
            error = nil
            autoMap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Maps source columns to target columns with the same name (case-insensitive), or by position without a header row.
    private func autoMap() {
        mapping = [:]
        for (index, header) in headers.enumerated() {
            if hasHeader {
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
        let changes: [RowChange] = dataRows.map { row in
            .insert(values: mapped.map { index, column in
                let raw = row.indices.contains(index) ? row[index] : ""
                return ColumnValue(column, raw.isEmpty && emptyAsNull ? .null : .text(raw))
            })
        }
        do {
            try await target.context.driver.applyChanges(changes, table: target.object.name, schema: driverSchema)
            result = "Imported \(changes.count.formatted()) records into \(target.object.name)."
            for tab in app.tabs {
                if case .table(let model) = tab, model.object == target.object { model.requestReload() }
            }
        } catch {
            self.error = "Nothing was imported: \(error.localizedDescription)"
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
