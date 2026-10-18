import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// Navicat's Export Wizard, trimmed: pick tables and views, a format and its options, then a folder;
/// one file per object, or one Excel workbook with a sheet per object.
struct ExportWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ExportTarget
    @State private var selected: Set<String> = []
    @AppStorage("export.format") private var format: TableExportFormat = .csv
    @AppStorage("export.csvDelimiter") private var csvDelimiter = ","
    @AppStorage("export.includeHeader") private var includeHeader = true
    @AppStorage("export.sqlStructure") private var sqlStructure = true
    @AppStorage("export.sqlDrop") private var sqlDrop = true
    @AppStorage("export.sqlData") private var sqlData = true
    @AppStorage("export.sqlRowsPerInsert") private var sqlRowsPerInsert = 1
    @AppStorage("export.singleWorkbook") private var singleWorkbook = true
    @State private var progress: String?
    @State private var fraction = 0.0
    @State private var task: Task<Void, Never>?

    private var schema: String? { target.schema ?? target.objects.first?.schema }

    private var candidates: [DatabaseObject] {
        let all = (target.context.objects(in: schema, category: .tables) ?? []) + (target.context.objects(in: schema, category: .views) ?? [])
        return all.isEmpty ? target.objects : all
    }

    private var options: TableExportOptions {
        TableExportOptions(csvDelimiter: csvDelimiter.first ?? ",", includeHeader: includeHeader,
                           sql: SQLDumpOptions(includeDrop: sqlDrop, includeStructure: sqlStructure, includeData: sqlData,
                                               rowsPerInsert: sqlRowsPerInsert))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Export Wizard", systemImage: "square.and.arrow.up", subtitle: target.context.location(schema: schema))
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Format").font(.subheadline.weight(.semibold))
                    Picker("Format", selection: $format) {
                        ForEach(TableExportFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                .frame(width: 180, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Options").font(.subheadline.weight(.semibold))
                    formatOptions
                }
                Spacer(minLength: 0)
            }
            .disabled(task != nil)
            HStack {
                Text("Objects (\(selected.count) of \(candidates.count))").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Select All") { selected = Set(candidates.map(\.id)) }
                Button("Deselect All") { selected = [] }
            }
            .controlSize(.small)
            List(candidates) { object in
                Toggle(isOn: Binding(
                    get: { selected.contains(object.id) },
                    set: { if $0 { selected.insert(object.id) } else { selected.remove(object.id) } }
                )) {
                    Label { Text(object.name) } icon: { AppIcon(name: object.kind.iconName, size: 16) }
                }
            }
            .frame(minHeight: 200)
            .disabled(task != nil)
            if let progress {
                ProgressView(value: fraction) { Text(progress).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || task != nil || (format == .sql && !sqlStructure && !sqlData))
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear { selected = Set(target.objects.map(\.id)) }
        .task {
            // Opened from a database node before its tables were listed.
            if target.context.objects(in: schema) == nil { await target.context.loadObjects(schema: schema) }
            if selected.isEmpty { selected = Set(candidates.map(\.id)) }
        }
    }

    @ViewBuilder
    private var formatOptions: some View {
        switch format {
        case .csv:
            Picker("Field delimiter", selection: $csvDelimiter) {
                Text("Comma ( , )").tag(",")
                Text("Semicolon ( ; )").tag(";")
                Text("Tab").tag("\t")
                Text("Pipe ( | )").tag("|")
            }
            .fixedSize()
            Toggle("Include field names", isOn: $includeHeader)
        case .json, .html, .markdown, .xml:
            Text(format.summary ?? "")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .sql:
            Toggle("CREATE statements (structure)", isOn: $sqlStructure)
            Toggle("DROP … IF EXISTS before CREATE", isOn: $sqlDrop).disabled(!sqlStructure).padding(.leading, 18)
            Toggle("INSERT statements (data)", isOn: $sqlData)
            Stepper("Rows per INSERT: \(sqlRowsPerInsert)", value: $sqlRowsPerInsert, in: 1...1000, step: sqlRowsPerInsert < 10 ? 1 : 50)
                .disabled(!sqlData)
                .padding(.leading, 18)
        case .xlsx:
            Toggle("One workbook, a sheet per object", isOn: $singleWorkbook)
            Toggle("Include field names", isOn: $includeHeader)
            Text("Text cells are limited to 32,767 characters by Excel.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func export() {
        let objects = candidates.filter { selected.contains($0.id) }
        let driver = target.context.driver
        let format = format, options = options
        let workbook = format == .xlsx && singleWorkbook
        let destination: URL
        if workbook {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.nameFieldStringValue = (objects.count == 1 ? objects[0].name : target.context.name) + ".xlsx"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose a folder: each object is written to its own .\(format.fileExtension) file."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        fraction = 0
        task = Task {
            do {
                if workbook {
                    let data = try await TableExporter.workbook(objects, from: driver, includeHeader: options.includeHeader) { index in
                        await MainActor.run {
                            progress = "Reading \(objects[index].name) (\(index + 1) of \(objects.count))…"
                            fraction = Double(index) / Double(objects.count)
                        }
                    }
                    progress = "Writing \(destination.lastPathComponent)…"
                    try data.write(to: destination, options: .atomic)
                } else {
                    for (i, object) in objects.enumerated() {
                        progress = "Exporting \(object.name) (\(i + 1) of \(objects.count))…"
                        fraction = Double(i) / Double(objects.count)
                        let data = try await TableExporter.export(object, from: driver, as: format, options: options)
                        try data.write(to: destination.appending(path: Self.fileName(object.name, extension: format.fileExtension)), options: .atomic)
                    }
                }
                fraction = 1
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                dismiss()
            } catch is CancellationError {
            } catch {
                app.alertMessage = "Export failed: \(error.localizedDescription)"
                progress = nil
                task = nil
            }
        }
    }

    /// A file name for an object, without path separators.
    static func fileName(_ name: String, extension ext: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return "\(safe.isEmpty ? "export" : safe).\(ext)"
    }
}
