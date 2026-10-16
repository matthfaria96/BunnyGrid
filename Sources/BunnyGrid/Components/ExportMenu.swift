import AppKit
import BunnyGridCore
import SwiftUI

/// "Export" menu for a set of rows: writes CSV or JSON through a save panel.
struct ExportMenu: View {
    let columns: [String]
    let rows: [[CellValue]]
    let suggestedName: String

    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button("Export \(rows.count.formatted()) Rows as \(format.displayName)…") {
                    Self.export(columns: columns, rows: rows, suggestedName: suggestedName, format: format)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export")
    }

    static func export(columns: [String], rows: [[CellValue]], suggestedName: String, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ResultExporter.export(columns: columns, rows: rows, as: format).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The "Export" item of the table toolbar, styled like the other toolbar chips.
struct ExportChip: View {
    let columns: [String]
    let rows: [[CellValue]]
    let suggestedName: String

    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button("Export \(rows.count.formatted()) Records as \(format.displayName)…") {
                    ExportMenu.export(columns: columns, rows: rows, suggestedName: suggestedName, format: format)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.teal).frame(width: 16)
                Text("Export")
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export this page")
    }
}
