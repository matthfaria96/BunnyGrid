import AppKit
import BunnyGridCore
import SwiftUI

/// Navicat's Export Wizard, trimmed: pick tables and views, a format and a folder; one file per object.
struct ExportWizardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ExportTarget
    @State private var selected: Set<String> = []
    @State private var format: TableExportFormat = .csv
    @State private var progress: String?
    @State private var task: Task<Void, Never>?

    private var candidates: [DatabaseObject] {
        let schema = target.objects.first?.schema
        let all = (target.context.objects(in: schema, category: .tables) ?? []) + (target.context.objects(in: schema, category: .views) ?? [])
        return all.isEmpty ? target.objects : all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Wizard").font(.headline)
            Picker("Format", selection: $format) {
                ForEach(TableExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("Objects").font(.subheadline.weight(.semibold))
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
            .frame(minHeight: 220)
            if let progress { Text(progress).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || task != nil)
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .onAppear { selected = Set(target.objects.map(\.id)) }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let objects = candidates.filter { selected.contains($0.id) }
        let driver = target.context.driver
        let format = format
        task = Task {
            do {
                for (i, object) in objects.enumerated() {
                    progress = "Exporting \(object.name) (\(i + 1) of \(objects.count))…"
                    let data = try await TableExporter.export(object, from: driver, as: format)
                    try data.write(to: folder.appending(path: "\(object.name).\(format.fileExtension)"))
                }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                dismiss()
            } catch is CancellationError {
            } catch {
                app.alertMessage = "Export failed: \(error.localizedDescription)"
                progress = nil
                task = nil
            }
        }
    }
}
