import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// Model tab, like Navicat Modeling: a zoomable, scrollable ER diagram of a database or schema.
/// Cards can be dragged (positions are saved), clicking one highlights its relationships.
struct ModelTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ModelTabModel
    @State private var viewport: CGSize = .zero
    @State private var pinchBase: CGFloat?

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
        let size = model.canvasSize
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ERDiagram(diagram: diagram, positions: model.positions, selection: model.selection, highlighted: model.highlighted,
                              interactive: true,
                              onSelect: { model.selection = $0 },
                              onMove: { model.move($0, to: $1) },
                              onMoveEnded: { model.savePositions() },
                              onOpen: open,
                              menu: { cardMenu($0) })
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .scaleEffect(model.zoom, anchor: .topLeading)
                        .frame(width: size.width * model.zoom, height: size.height * model.zoom, alignment: .topLeading)
                        .background(alignment: .topLeading) { Color.clear.frame(width: 1, height: 1).id("origin") }
                }
                .onAppear { viewport = geometry.size }
                .onChange(of: geometry.size) { _, new in viewport = new }
                .onChange(of: model.fitRequest) { _, _ in
                    fit(viewport: geometry.size)
                    proxy.scrollTo("origin", anchor: .topLeading)
                }
                .task(id: model.fitRequest) {
                    // The first fit runs once the canvas has a size.
                    if model.fitRequest == 1 { fit(viewport: geometry.size) }
                }
            }
            .gesture(MagnifyGesture()
                .onChanged { value in
                    if pinchBase == nil { pinchBase = model.zoom }
                    model.setZoom((pinchBase ?? 1) * value.magnification)
                }
                .onEnded { _ in pinchBase = nil })
        }
    }

    /// Zooms so the whole diagram fits, never above 100%.
    private func fit(viewport: CGSize) {
        let bounds = ERLayout.bounds(model.frames.values)
        guard bounds.width > 0, viewport.width > 0, viewport.height > 0 else { return }
        let width = bounds.maxX + ERLayout.margin, height = bounds.maxY + ERLayout.margin
        model.setZoom(min(1, viewport.width / width, viewport.height / height))
    }

    @ViewBuilder
    private func cardMenu(_ tableID: String) -> some View {
        Button("Open Table") { open(tableID) }
        Button("Design Table") {
            if let context, let object = object(tableID) { app.openDesign(table: object, in: context) }
        }
        Divider()
        Button("Generate SQL…") {
            model.selection = tableID
            model.showingSQL = true
        }
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
        let bounds = ERLayout.bounds(ERLayout.frames(diagram, positions: positions).values)
        let size = CGSize(width: bounds.maxX + ERLayout.margin, height: bounds.maxY + ERLayout.margin)
        let content = ERDiagram(diagram: diagram, positions: positions, selection: nil, highlighted: [], interactive: false)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        switch format {
        case .png:
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
        case .pdf:
            var failed = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { failed = true; return }
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
                pdf.closePDF()
            }
            if failed { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

// MARK: - Diagram

/// The ER diagram itself: relationship lines under the table cards, in diagram points (unscaled).
/// Also rendered off screen for PNG and PDF export (`interactive: false`).
struct ERDiagram<Menu: View>: View {
    let diagram: ERModel
    let positions: [String: CGPoint]
    let selection: String?
    let highlighted: Set<String>
    var interactive: Bool
    var onSelect: (String?) -> Void = { _ in }
    var onMove: (String, CGPoint) -> Void = { _, _ in }
    var onMoveEnded: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }
    @ViewBuilder var menu: (String) -> Menu
    @State private var dragOrigin: [String: CGPoint] = [:]

    static var coordinateSpace: String { "ERDiagram" }

    var body: some View {
        let frames = ERLayout.frames(diagram, positions: positions)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if interactive { onSelect(nil) } }
            RelationshipLines(diagram: diagram, frames: frames, selection: selection)
                .allowsHitTesting(false)
            ForEach(diagram.tables) { table in
                if let frame = frames[table.id] {
                    card(table, frame: frame)
                }
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }

    @ViewBuilder
    private func card(_ table: ERTable, frame: CGRect) -> some View {
        let isSelected = selection == table.id
        let base = ERTableCard(table: table, size: frame.size, isSelected: isSelected,
                               isRelated: highlighted.contains(table.id) && !isSelected,
                               isDimmed: selection != nil && !highlighted.contains(table.id))
            .offset(x: frame.minX, y: frame.minY)
        if interactive {
            base
                .onTapGesture(count: 2) { onOpen(table.id) }
                .onTapGesture { onSelect(table.id) }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        let origin = dragOrigin[table.id] ?? frame.origin
                        if dragOrigin[table.id] == nil {
                            dragOrigin[table.id] = origin
                            onSelect(table.id)
                        }
                        onMove(table.id, CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height))
                    }
                    .onEnded { _ in
                        dragOrigin[table.id] = nil
                        onMoveEnded()
                    })
                .contextMenu { menu(table.id) }
        } else {
            base
        }
    }
}

extension ERDiagram where Menu == EmptyView {
    init(diagram: ERModel, positions: [String: CGPoint], selection: String?, highlighted: Set<String>, interactive: Bool) {
        self.init(diagram: diagram, positions: positions, selection: selection, highlighted: highlighted,
                  interactive: interactive, menu: { _ in EmptyView() })
    }
}

/// A table card: name header, then one row per column with key / foreign key symbols and the type.
private struct ERTableCard: View {
    let table: ERTable
    let size: CGSize
    let isSelected: Bool
    let isRelated: Bool
    let isDimmed: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "tablecells")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(table.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: ERLayout.headerHeight)
            .background(Color.accentColor.opacity(isSelected ? 0.28 : 0.13))
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.top, -0.5)
            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                row(column)
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : (isRelated ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.18)),
                              lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 6 : 2, y: 1)
        .opacity(isDimmed ? 0.55 : 1)
    }

    private func row(_ column: ERColumn) -> some View {
        HStack(spacing: 5) {
            Group {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").foregroundStyle(.yellow)
                } else if column.isForeignKey {
                    Image(systemName: "link").foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: column.nullable ? "circle" : "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9.5))
            .frame(width: 13)
            .help(column.isPrimaryKey ? "Primary key" : column.isForeignKey ? "Foreign key" : column.nullable ? "Nullable" : "Not null")
            Text(column.name)
                .font(.system(size: 11, weight: column.isPrimaryKey ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(column.dataType.isEmpty ? "—" : column.dataType)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: ERLayout.rowHeight)
    }
}

/// Foreign keys as orthogonal lines with crow's-foot ends: "many" (or "one" for 1:1 keys) at the child,
/// "exactly one" (‖) or "zero or one" (o|, nullable key) at the parent.
private struct RelationshipLines: View {
    let diagram: ERModel
    let frames: [String: CGRect]
    let selection: String?

    var body: some View {
        Canvas { context, _ in
            // Plain lines first, the selection's on top.
            let ordered = diagram.relationships.sorted { isActive($0) == isActive($1) ? $0.id < $1.id : !isActive($0) }
            for relation in ordered {
                guard let points = ERLayout.route(relation, in: diagram, frames: frames), points.count >= 2 else { continue }
                let active = isActive(relation)
                let color: Color = active ? .accentColor : Color.secondary.opacity(selection == nil ? 0.75 : 0.35)
                let style = StrokeStyle(lineWidth: active ? 2 : 1.2, lineCap: .round, lineJoin: .round)
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(color), style: style)
                context.stroke(childEnd(at: points[0], toward: points[1], oneToOne: relation.isOneToOne), with: .color(color), style: style)
                let count = points.count
                context.stroke(parentEnd(at: points[count - 1], toward: points[count - 2], optional: relation.isOptional), with: .color(color), style: style)
            }
        }
    }

    private func isActive(_ relation: ERRelationship) -> Bool {
        selection != nil && (relation.fromTable == selection || relation.toTable == selection)
    }

    private func unit(_ from: CGPoint, _ to: CGPoint) -> (dx: CGFloat, dy: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        return (dx / length, dy / length)
    }

    private func point(_ p: CGPoint, _ d: (dx: CGFloat, dy: CGFloat), along: CGFloat, across: CGFloat = 0) -> CGPoint {
        CGPoint(x: p.x + d.dx * along - d.dy * across, y: p.y + d.dy * along + d.dx * across)
    }

    private func bar(_ path: inout Path, _ p: CGPoint, _ d: (dx: CGFloat, dy: CGFloat), at distance: CGFloat) {
        path.move(to: point(p, d, along: distance, across: -6))
        path.addLine(to: point(p, d, along: distance, across: 6))
    }

    private func circle(_ path: inout Path, _ p: CGPoint, _ d: (dx: CGFloat, dy: CGFloat), at distance: CGFloat) {
        let center = point(p, d, along: distance)
        path.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
    }

    private func childEnd(at p: CGPoint, toward next: CGPoint, oneToOne: Bool) -> Path {
        let d = unit(p, next)
        var path = Path()
        if oneToOne {
            bar(&path, p, d, at: 8)
        } else {
            let joint = point(p, d, along: 12)
            for across in [-6.0, 0, 6] {
                path.move(to: joint)
                path.addLine(to: point(p, d, along: 0, across: across))
            }
        }
        circle(&path, p, d, at: 18)
        return path
    }

    private func parentEnd(at p: CGPoint, toward previous: CGPoint, optional: Bool) -> Path {
        let d = unit(p, previous)
        var path = Path()
        bar(&path, p, d, at: 7)
        if optional { circle(&path, p, d, at: 16) } else { bar(&path, p, d, at: 12) }
        return path
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
