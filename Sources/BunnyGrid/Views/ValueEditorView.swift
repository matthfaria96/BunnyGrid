import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// Navicat's "Cell Editors": the full editor for one cell, shown in a popover over the grid (⌥↩,
/// double-click on long values) and in the Cell Editor pane. The editor follows the column type:
/// multi-line text, JSON with beautify / minify / validate, hex and image preview for blobs (load from
/// and save to a file), and a date picker for temporal columns. NULL, empty and DEFAULT apply at once.
struct ValueEditorView: View {
    @Bindable var model: TableTabModel
    let cell: GridCell
    /// Set in the popover: applying a value also closes it.
    var onClose: (() -> Void)?

    enum Editor: String, CaseIterable, Identifiable {
        case text = "Text"
        case json = "JSON"
        case date = "Date"
        case hex = "Hex"
        case image = "Image"

        var id: String { rawValue }
    }

    @State private var editor: Editor = .text
    @State private var text = ""
    @State private var data = Data()
    @State private var original: CellValue = .null
    @State private var dirty = false
    @State private var jsonError: String?
    @State private var fileError: String?

    private var category: ColumnTypeCategory { model.category(ofColumn: cell.column) }
    private var columnName: String { model.columnName(cell.column) ?? "" }
    private var isBinary: Bool { category == .binary || original.isBlob }
    private var canEdit: Bool { model.canEditCell(row: cell.row, column: cell.column) }
    private var state: GridCellState { model.cellState(row: cell.row, column: cell.column) }

    private var editors: [Editor] {
        if isBinary { return [.hex, .image, .text] }
        if category.isTemporal { return [.date, .text] }
        if category == .json { return [.json, .text] }
        return [.text, .json]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .onChange(of: cell, initial: true) { _, _ in load(resetEditor: true) }
        .onChange(of: model.revision) { _, _ in if !dirty { load(resetEditor: false) } }
        .onChange(of: text) { _, newValue in
            if editor == .json || category == .json { jsonError = JSONFormatter.validate(newValue) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: GridHeaderCell.symbolName(for: model.columnTypes[columnName] ?? ""))
                .foregroundStyle(.orange)
            Text(columnName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let type = model.columnTypes[columnName] {
                Text(type).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            stateBadge
            Spacer(minLength: 8)
            if editors.count > 1 {
                Picker("Editor", selection: $editor) {
                    ForEach(editors) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if let onClose {
                IconButton(systemImage: "xmark", help: "Close (Esc)") { onClose() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let label: (String, Color)? = switch state {
        case .edited: ("Edited", .orange)
        case .editedDefault, .defaultValue: ("DEFAULT", .secondary)
        case .inserted: ("New", .green)
        case .deleted: ("Deleted", .red)
        case .normal: original.isNull ? ("NULL", .secondary) : nil
        }
        if let label {
            Text(label.0)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(label.1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().strokeBorder(label.1.opacity(0.5)))
        }
    }

    // MARK: Editors

    @ViewBuilder
    private var content: some View {
        switch editor {
        case .text:
            PlainTextEditor(text: isBinary ? binaryTextBinding : textBinding, isEditable: canEdit)
        case .json:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button("Beautify") { reformat { try JSONFormatter.pretty($0) } }
                        .disabled(!canEdit)
                        .help("Indent the JSON, keeping the key order")
                    Button("Minify") { reformat { try JSONFormatter.minify($0) } }
                        .disabled(!canEdit)
                        .help("Remove insignificant whitespace")
                    Spacer()
                    if text.isEmpty {
                        EmptyView()
                    } else if let jsonError {
                        Label(jsonError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(jsonError)
                    } else {
                        Label("Valid JSON", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
                PlainTextEditor(text: textBinding, isEditable: canEdit)
            }
        case .date:
            DateEditor(text: textBinding, category: category, isEditable: canEdit)
        case .hex:
            VStack(spacing: 0) {
                binaryToolbar
                Divider()
                PlainTextEditor(text: .constant(data.isEmpty ? "" : HexFormatter.dump(data)), isEditable: false, wrapsLines: false)
            }
        case .image:
            VStack(spacing: 0) {
                binaryToolbar
                Divider()
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: min(image.size.width, 2000), maxHeight: min(image.size.height, 2000))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(4)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                } else {
                    ContentUnavailableView(data.isEmpty ? "No Data" : "Not an Image", systemImage: "photo",
                                           description: Text(data.isEmpty ? "Load an image from a file." : BlobKind.detect(data).displayName))
                }
            }
        }
    }

    private var binaryToolbar: some View {
        // Labels in the popover; icons only in a narrow Cell Editor pane.
        ViewThatFits(in: .horizontal) {
            binaryToolbarRow(compact: false)
            binaryToolbarRow(compact: true)
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func binaryToolbarRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { loadFromFile() } label: {
                if compact { Image(systemName: "square.and.arrow.down") } else { Label("Load from File…", systemImage: "square.and.arrow.down") }
            }
            .help("Load from File…")
            .disabled(!canEdit)
            Button { saveToFile() } label: {
                if compact { Image(systemName: "square.and.arrow.up") } else { Label("Save to File…", systemImage: "square.and.arrow.up") }
            }
            .help("Save to File…")
            .disabled(data.isEmpty)
            Spacer(minLength: 4)
            if let fileError {
                Text(fileError).foregroundStyle(.red).lineLimit(1).help(fileError)
            } else {
                Text(data.isEmpty ? "Empty" : compact ? BlobKind.detect(data).fileExtension.uppercased()
                     : "\(BlobKind.detect(data).displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: !compact, vertical: false)
    }

    // MARK: Footer

    private var footer: some View {
        // The popover has room for every button; the narrow pane folds NULL / Empty / DEFAULT into a menu.
        ViewThatFits(in: .horizontal) {
            footerRow(compact: false)
            footerRow(compact: true)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            if onClose != nil { Button("") { onClose?() }.keyboardShortcut(.cancelAction).hidden() }
        }
    }

    private func footerRow(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if !compact {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            if canEdit {
                if compact {
                    Menu("Set") {
                        Button("NULL", action: setNull)
                        Button("Empty", action: setEmpty).disabled(!isBinary && !category.acceptsEmptyString)
                        Button("DEFAULT", action: setDefault)
                    }
                    .fixedSize()
                } else {
                    Button("NULL", action: setNull)
                        .help("Set the cell to NULL")
                    Button("Empty", action: setEmpty)
                        .help(isBinary ? "Set the cell to a zero-length value" : "Set the cell to an empty string")
                        .disabled(!isBinary && !category.acceptsEmptyString)
                    Button("DEFAULT", action: setDefault)
                        .help(defaultHelp)
                    Divider().frame(height: 14)
                }
                Button("Revert") { load(resetEditor: false) }
                    .disabled(!dirty)
                Button("Apply") { commit(isBinary ? .blob(data) : .text(text)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
                    .help("Set the cell to this value (⌘↩); Apply Changes in the footer saves it")
            } else {
                Text(readOnlyReason).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: !compact, vertical: false)
    }

    private func setNull() { commit(.null) }

    private func setEmpty() { commit(isBinary ? .blob(Data()) : .text("")) }

    private func setDefault() {
        model.setDefault(row: cell.row, column: cell.column)
        dirty = false
        onClose?()
    }

    private var summary: String {
        if isBinary { return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
        let lines = text.isEmpty ? 0 : text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        return "\(text.count.formatted()) characters · \(lines.formatted()) line\(lines == 1 ? "" : "s")"
    }

    private var defaultHelp: String {
        if let expression = model.columnInfo(cell.column)?.defaultValue { return "Set the cell to the column default: \(expression)" }
        return "Set the cell to the column default (NULL when the column has none)"
    }

    private var readOnlyReason: String {
        if model.maskedColumnIndexes.contains(cell.column) { return "Masked column" }
        if state == .deleted { return "Record marked for deletion" }
        return model.readOnlyReason ?? "Read-only"
    }

    // MARK: Actions

    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { text = $0; dirty = true })
    }

    /// A blob edited as UTF-8 text.
    private var binaryTextBinding: Binding<String> {
        Binding(get: { String(decoding: data, as: UTF8.self) }, set: { data = Data($0.utf8); dirty = true })
    }

    private func load(resetEditor: Bool) {
        let value = model.value(row: cell.row, column: cell.column) ?? .null
        original = value
        switch value {
        case .blob(let bytes):
            data = bytes
            text = ""
        case .null:
            data = Data()
            text = ""
        default:
            text = value.displayString
            data = Data(text.utf8)
        }
        dirty = false
        fileError = nil
        jsonError = text.isEmpty ? nil : JSONFormatter.validate(text)
        if resetEditor || !editors.contains(editor) { editor = preferredEditor() }
    }

    private func preferredEditor() -> Editor {
        if isBinary { return BlobKind.detect(data).isImage ? .image : .hex }
        if category.isTemporal { return .date }
        if category == .json { return .json }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && JSONFormatter.validate(trimmed) == nil { return .json }
        return .text
    }

    private func reformat(_ transform: (String) throws -> String) {
        do {
            text = try transform(text)
            dirty = true
        } catch {
            jsonError = error.localizedDescription
        }
    }

    private func commit(_ value: CellValue) {
        model.setValue(value, row: cell.row, column: cell.column)
        dirty = false
        load(resetEditor: false)
        onClose?()
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to store in \(columnName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try Data(contentsOf: url)
            data = bytes
            // Stored at once: the popover may close while the panel is up.
            model.setValue(.blob(bytes), row: cell.row, column: cell.column)
            dirty = false
            fileError = nil
            if BlobKind.detect(bytes).isImage { editor = .image }
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        let kind = BlobKind.detect(data)
        panel.nameFieldStringValue = "\(model.object.name)-\(columnName).\(kind.fileExtension)"
        if let type = UTType(filenameExtension: kind.fileExtension) { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            fileError = nil
        } catch {
            fileError = error.localizedDescription
        }
    }
}

/// Date, time or both, with a text field holding the canonical form that is sent to the database.
private struct DateEditor: View {
    @Binding var text: String
    let category: ColumnTypeCategory
    let isEditable: Bool

    private var parsed: Date? { TemporalText.parse(text, category: category) }
    private var hasDate: Bool { category != .time && category != .timeWithTimeZone }
    private var hasTime: Bool { category != .date }

    private var date: Binding<Date> {
        Binding(get: { parsed ?? Self.defaultDate(for: category) },
                set: { text = TemporalText.format($0, category: category) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    if hasDate {
                        DatePicker("Date", selection: date, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if hasTime {
                            Text("Time").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            TimeField(date: date)
                                .fixedSize()
                        }
                        Button(hasDate && !hasTime ? "Today" : "Now") { text = TemporalText.format(Date(), category: category) }
                        if category == .dateTimeWithTimeZone || category == .timeWithTimeZone {
                            Text("Shown in \(TimeZone.current.identifier)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!isEditable)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Value", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(!isEditable)
                    if !text.isEmpty && parsed == nil {
                        Label("Not a date the picker understands; it is sent as typed.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func defaultDate(for category: ColumnTypeCategory) -> Date {
        if category == .date { return Calendar.current.startOfDay(for: Date()) }
        return Date()
    }
}

/// Hours, minutes and seconds with a stepper (SwiftUI's macOS DatePicker stops at minutes).
private struct TimeField: NSViewRepresentable {
    @Binding var date: Date

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinuteSecond
        picker.dateValue = date
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>

        init(date: Binding<Date>) {
            self.date = date
        }

        @objc func changed(_ sender: NSDatePicker) {
            date.wrappedValue = sender.dateValue
        }
    }
}

/// A plain-text NSTextView: monospaced, no smart quotes or dashes (they would corrupt JSON and SQL), with undo.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Off for hex dumps, whose columns must stay aligned: long lines scroll sideways instead.
    var wrapsLines = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        if !wrapsLines {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { range in
                let r = range.rangeValue
                return NSValue(range: NSRange(location: min(r.location, length), length: 0))
            }
        }
        textView.isEditable = isEditable
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
