import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// Model tab, like Navicat Modeling: a zoomable, scrollable ER diagram of a database or schema.
/// Cards can be dragged (positions are saved), clicking one highlights its relationships.
struct ModelTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ModelTabModel

    private var context: DatabaseContext? {
        model.connectionID.flatMap { app.sessions[$0]?.context(model.databaseName) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if let diagram = model.model {
                    if diagram.tables.isEmpty {
                        ContentUnavailableView("No Tables", systemImage: "rectangle.connected.to.line.below",
                                               description: Text("\(model.displayName) has no tables to put in a model."))
                    } else {
                        canvas(diagram)
                    }
                } else if let error = model.error {
                    ContentUnavailableView("Couldn't Read the Schema", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Reverse engineering \(model.displayName)…").controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task {
            if model.model == nil { await model.load() }
            #if DEBUG
            // --model-select TABLE highlights a table; --model-export PATH.png|pdf writes the diagram; --model-sql opens Generate SQL.
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            if let table = value("--model-select") { model.selection = table }
            if let path = value("--model-export"), let diagram = model.model {
                try? Self.render(diagram, positions: model.positions, format: path.hasSuffix(".pdf") ? .pdf : .png, to: URL(fileURLWithPath: path))
            }
            if args.contains("--model-sql") { model.showingSQL = true }
            // --model-zoom 1.0: after the first fit (for captures at a given scale).
            if let zoom = value("--model-zoom").flatMap(Double.init) {
                try? await Task.sleep(for: .milliseconds(600))
                model.setZoom(zoom)
            }
            #endif
        }
        .sheet(isPresented: $model.showingSQL) {
            GenerateSQLSheet(model: model, context: context)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolIconButton(systemImage: "arrow.clockwise", help: "Refresh: read the schema again") { Task { await model.load() } }
                .disabled(model.isLoading)
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolbarChip(title: "Auto Layout", systemImage: "square.grid.3x1.below.line.grid.1x2", help: "Arrange every table again, keeping related tables together") {
                model.autoLayout()
            }
            .disabled(model.model == nil)
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "minus.magnifyingglass", help: "Zoom Out (⌘-)") { model.setZoom(model.zoom / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
            Menu {
                ForEach([25, 50, 75, 100, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") { model.setZoom(CGFloat(percent) / 100) }
                }
                Divider()
                Button("Zoom to Fit") { model.zoomToFit() }
            } label: {
                Text("\(Int((model.zoom * 100).rounded()))%").font(.system(size: 12).monospacedDigit())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .frame(minWidth: 44)
            ToolIconButton(systemImage: "plus.magnifyingglass", help: "Zoom In (⌘+)") { model.setZoom(model.zoom * 1.25) }
                .keyboardShortcut("=", modifiers: .command)
            ToolIconButton(systemImage: "arrow.up.left.and.down.right.magnifyingglass", help: "Zoom to Fit") { model.zoomToFit() }
            Divider().frame(height: 16).padding(.horizontal, 6)
            Menu {
                Button("PNG Image…") { export(.png) }
                Button("PDF Document…") { export(.pdf) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 12.5))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(model.model?.tables.isEmpty ?? true)
            .help("Export the diagram as an image or PDF")
            ToolbarChip(title: "Generate SQL", systemImage: "chevron.left.forwardslash.chevron.right",
                        help: "Forward engineering: CREATE TABLE and foreign keys for a database type") {
                model.showingSQL = true
            }
            .disabled(model.model?.tables.isEmpty ?? true)
            Spacer()
            if let selection = model.selection, let table = model.model?.table(selection) {
                let count = model.model?.relationships(touching: selection).count ?? 0
                Text("\(table.name): \(table.columns.count) fields, \(count) relationship\(count == 1 ? "" : "s")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    // MARK: - Canvas

    private func canvas(_ diagram: ERModel) -> some View {
        ERCanvasRepresentable(
            diagram: diagram, frames: model.frames, canvasSize: model.canvasSize, selection: model.selection,
            highlighted: model.highlighted, zoom: model.zoom, fitRequest: model.fitRequest,
            callbacks: .init(select: { model.selection = $0 },
                             move: { model.move($0, to: $1) },
                             moveEnded: { model.savePositions() },
                             open: open,
                             menu: cardMenu),
            fit: fit(viewport:),
            zoomChanged: { model.setZoom($0) })
    }

    /// Zooms so the whole diagram fits, never above 100%.
    private func fit(viewport: CGSize) {
        let bounds = ERLayout.bounds(model.frames.values)
        guard bounds.width > 0, viewport.width > 0, viewport.height > 0 else { return }
        let width = bounds.maxX + ERLayout.margin, height = bounds.maxY + ERLayout.margin
        model.setZoom(min(1, viewport.width / width, viewport.height / height))
    }

    private func cardMenu(_ tableID: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ERMenuItem("Open Table") { open(tableID) })
        menu.addItem(ERMenuItem("Design Table") {
            if let context, let object = object(tableID) { app.openDesign(table: object, in: context) }
        })
        menu.addItem(.separator())
        menu.addItem(ERMenuItem("Generate SQL…") {
            model.selection = tableID
            model.showingSQL = true
        })
        return menu
    }

    private func object(_ tableID: String) -> DatabaseObject? {
        guard let context, let table = model.model?.table(tableID) else { return nil }
        return context.objects(in: model.schema)?.first { $0.name == table.name && $0.kind == .table }
            ?? DatabaseObject(schema: context.driverSchema(model.schema), name: table.name, kind: .table)
    }

    private func open(_ tableID: String) {
        guard let context, let object = object(tableID) else { return }
        app.openTable(object, in: context)
    }

    // MARK: - Export

    private enum ExportFormat { case png, pdf }

    private func export(_ format: ExportFormat) {
        guard let diagram = model.model else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        panel.nameFieldStringValue = "\(model.displayName) Model.\(format == .png ? "png" : "pdf")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.render(diagram, positions: model.positions, format: format, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @MainActor
    private static func render(_ diagram: ERModel, positions: [String: CGPoint], format: ExportFormat, to url: URL) throws {
        guard let data = ERCanvasView.export(diagram, positions: positions, pdf: format == .pdf) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Generate SQL

/// Forward engineering: the model as CREATE TABLE + foreign key statements for a chosen database type.
private struct GenerateSQLSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ModelTabModel
    let context: DatabaseContext?
    @State private var kind: DatabaseKind
    @State private var selectedOnly: Bool
    @State private var includeDrop = false

    init(model: ModelTabModel, context: DatabaseContext?) {
        self.model = model
        self.context = context
        _kind = State(initialValue: model.kind)
        _selectedOnly = State(initialValue: false)
    }

    private var sql: String { model.generateSQL(for: kind, selectedOnly: selectedOnly, includeDrop: includeDrop) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate SQL").font(.headline)
            HStack(spacing: 16) {
                Picker("Database Type:", selection: $kind) {
                    ForEach(DatabaseKind.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                Toggle("Selected table only", isOn: $selectedOnly)
                    .disabled(model.selection == nil)
                    .help(model.selection.flatMap { model.model?.table($0)?.name }.map { "Only “\($0)”" } ?? "Select a table in the diagram first")
                Toggle("Include DROP TABLE", isOn: $includeDrop)
            }
            ScrollView {
                Text(SQLSyntax.highlight(sql))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            if kind != model.kind {
                Label("Types are translated from \(model.kind.displayName) to \(kind.displayName); check the script before running it.",
                      systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
                Button("Save…") { save() }
                Button("Open in New Query") {
                    guard let context else { return }
                    app.openQuery(text: sql, in: context)
                    dismiss()
                }
                .disabled(context == nil || kind != model.kind)
                .help("Opens the script in a query tab of this database, without running it")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear { selectedOnly = false }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "\(model.displayName).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sql.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
