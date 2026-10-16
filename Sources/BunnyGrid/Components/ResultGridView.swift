import AppKit
import BunnyGridCore
import SwiftUI

/// Hooks that make the grid editable. Rows are addressed by their index in `rows`.
struct GridEditing {
    /// Changes whenever pending edits change, so the grid redraws states even when values don't.
    var revision: Int
    var cellState: (Int, Int) -> GridCellState
    var onEdit: (Int, Int, CellValue) -> Void
    var onToggleDelete: (IndexSet) -> Void
}

/// Spreadsheet-style grid backed by `NSTableView`, laid out like Navicat's: a row-marker column,
/// two-line headers (name and type), a focused cell and light row selection.
struct ResultGridView: NSViewRepresentable {
    let columns: [String]
    let rows: [[CellValue]]
    var columnTypes: [String: String] = [:]
    var hiddenColumns: Set<String> = []
    var sort: OrderBy?
    var onHeaderClick: ((String) -> Void)?
    var editing: GridEditing?
    var focusedCell: GridCell?
    var onFocusChange: ((GridCell?) -> Void)?
    var onSelectionChange: ((IndexSet) -> Void)?
    var scrollRequest: GridScrollRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.clicked(_:))
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.coordinator = context.coordinator
        tableView.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 24))

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = GridScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var tableView: GridTableView?
        private var columns: [String] = []
        private var rows: [[CellValue]] = []
        private var columnTypes: [String: String] = [:]
        private var revision: Int?
        private var editing: GridEditing?
        private var focusedCell: GridCell?
        private var onHeaderClick: ((String) -> Void)?
        private var onFocusChange: ((GridCell?) -> Void)?
        private var onSelectionChange: ((IndexSet) -> Void)?
        private var lastScrollRequest: GridScrollRequest?

        static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        private static let cellID = NSUserInterfaceItemIdentifier("GridCell")
        private static let markerID = NSUserInterfaceItemIdentifier("__marker")

        var isEditable: Bool { editing != nil }

        /// Columns whose declared type is numeric; their values (e.g. PostgreSQL numeric, decoded as text) align right.
        private var numericColumns: Set<Int> = []

        func update(_ view: ResultGridView) {
            guard let tableView else { return }
            onHeaderClick = view.onHeaderClick
            onFocusChange = view.onFocusChange
            onSelectionChange = view.onSelectionChange
            editing = view.editing
            let typesChanged = view.columnTypes != columnTypes
            let columnsChanged = view.columns != columns || typesChanged
            // Reload only on real changes: an unrelated SwiftUI update must not end an in-progress cell edit.
            let contentChanged = columnsChanged || view.rows != rows || view.editing?.revision != revision
            columns = view.columns
            rows = view.rows
            columnTypes = view.columnTypes
            numericColumns = Set(columns.indices.filter { index in
                columnTypes[columns[index]].map { GridHeaderCell.symbolName(for: $0) == "number" } ?? false
            })
            revision = view.editing?.revision
            if columnsChanged { rebuildColumns(tableView) }
            for column in tableView.tableColumns where column.identifier != Self.markerID {
                column.isHidden = view.hiddenColumns.contains(column.title)
            }
            if contentChanged { tableView.reloadData() }
            if view.focusedCell != focusedCell { setFocus(view.focusedCell, notify: false) }
            updateSortIndicators(tableView, sort: view.sort)
            if let request = view.scrollRequest, request != lastScrollRequest, request.row < rows.count {
                lastScrollRequest = request
                tableView.scrollRowToVisible(request.row)
                tableView.selectRowIndexes(IndexSet(integer: request.row), byExtendingSelection: false)
            }
        }

        private func rebuildColumns(_ tableView: NSTableView) {
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            let twoLine = !columnTypes.isEmpty
            let headerHeight: CGFloat = twoLine ? 40 : 24
            if let header = tableView.headerView as? GridHeaderView, header.height != headerHeight,
               let scrollView = tableView.enclosingScrollView {
                header.height = headerHeight
                // With automatic insets off, tiling places the rows below the (taller) header,
                // but the scroll position keeps the old header's offset; reset it to the top.
                scrollView.tile()
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -headerHeight))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            let marker = NSTableColumn(identifier: Self.markerID)
            marker.title = ""
            marker.width = 16
            marker.minWidth = 16
            marker.maxWidth = 16
            marker.resizingMask = []
            marker.headerCell = GridHeaderCell(textCell: "")
            tableView.addTableColumn(marker)

            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                let header = GridHeaderCell(textCell: name)
                header.typeName = columnTypes[name]
                column.headerCell = header
                column.title = name
                column.headerToolTip = columnTypes[name].map { "\(name) — \($0)" } ?? name
                column.minWidth = 40
                column.width = estimatedWidth(column: index, title: name, type: columnTypes[name])
                tableView.addTableColumn(column)
            }
            tableView.scrollRowToVisible(0)
        }

        private func estimatedWidth(column: Int, title: String, type: String?) -> CGFloat {
            let sample = rows.prefix(50).map { $0.indices.contains(column) ? $0[column].displayString.count : 0 }
            let chars = max(title.count + 2, (type?.count ?? 0) + 4, sample.max() ?? 0)
            return min(360, max(80, CGFloat(chars) * 7.6 + 18))
        }

        private func updateSortIndicators(_ tableView: NSTableView, sort: OrderBy?) {
            for column in tableView.tableColumns where column.identifier != Self.markerID {
                let image: NSImage? = if let sort, sort.column == column.title {
                    NSImage(named: sort.direction == .ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
                } else {
                    nil
                }
                tableView.setIndicatorImage(image, in: column)
            }
        }

        private func value(row: Int, column: Int) -> CellValue {
            rows.indices.contains(row) && rows[row].indices.contains(column) ? rows[row][column] : .null
        }

        private func state(row: Int, column: Int) -> GridCellState {
            editing?.cellState(row, column) ?? .normal
        }

        private func dataColumn(at position: Int) -> Int? {
            guard let tableView, position >= 0, position < tableView.tableColumns.count else { return nil }
            return Int(tableView.tableColumns[position].identifier.rawValue)
        }

        /// Inline editing handles single-line text; long values go through the Cell Editor.
        private func canEdit(row: Int, column: Int) -> Bool {
            guard isEditable, state(row: row, column: column) != .deleted else { return false }
            let value = value(row: row, column: column)
            if case .blob = value { return false }
            return !value.displayString.contains("\n")
        }

        // MARK: Focus

        private func setFocus(_ cell: GridCell?, notify: Bool) {
            guard let tableView else { return }
            let previous = focusedCell
            focusedCell = cell
            var dirtyRows = IndexSet()
            if let previous, previous.row < rows.count { dirtyRows.insert(previous.row) }
            if let cell, cell.row < rows.count { dirtyRows.insert(cell.row) }
            if !dirtyRows.isEmpty {
                tableView.reloadData(forRowIndexes: dirtyRows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
            for column in tableView.tableColumns {
                (column.headerCell as? GridHeaderCell)?.isFocused = cell.map { String($0.column) } == column.identifier.rawValue
            }
            tableView.headerView?.needsDisplay = true
            if notify { onFocusChange?(cell) }
        }

        @objc func clicked(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            if let column = dataColumn(at: tableView.clickedColumn) {
                setFocus(GridCell(row: tableView.clickedRow, column: column), notify: true)
            } else {
                setFocus(GridCell(row: tableView.clickedRow, column: focusedCell?.column ?? 0), notify: true)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            GridRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let field = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField ?? makeField()
            if tableColumn.identifier == Self.markerID {
                configureMarker(field, row: row)
                return field
            }
            guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let value = value(row: row, column: column)
            let state = state(row: row, column: column)
            let isFocused = focusedCell == GridCell(row: row, column: column)
            // Navicat draws NULL as "(Null)" and unset cells of a new record as "(Default)".
            let text = state == .defaultValue ? "(Default)"
                : value.isNull ? "(Null)"
                : value.displayString.replacingOccurrences(of: "\n", with: "⏎")

            let color: NSColor = if isFocused {
                .white
            } else {
                switch state {
                case .edited: .systemOrange
                case .inserted: .systemGreen
                case .defaultValue: .tertiaryLabelColor
                case .deleted: .secondaryLabelColor
                case .normal: value.isNull ? .tertiaryLabelColor : .labelColor
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            if state == .deleted { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = value.isNumeric || numericColumns.contains(column) ? .right : .left
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
            field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
            field.drawsBackground = isFocused
            field.backgroundColor = isFocused ? .controlAccentColor : .clear
            field.isEditable = canEdit(row: row, column: column)
            return field
        }

        private func configureMarker(_ field: NSTextField, row: Int) {
            let marker: (String, NSColor) = switch state(row: row, column: 0) {
            case .inserted, .defaultValue: ("+", .systemGreen)
            case .deleted: ("−", .systemRed)
            default: focusedCell?.row == row ? ("▸", .controlAccentColor) : ("", .clear)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            field.attributedStringValue = NSAttributedString(string: marker.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: marker.1, .paragraphStyle: paragraph,
            ])
            field.drawsBackground = false
            field.isEditable = false
        }

        private func makeField() -> NSTextField {
            let field = PaddedTextField(labelWithString: "")
            field.identifier = Self.cellID
            field.font = Self.font
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.delegate = self
            return field
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard isEditable, !columns.isEmpty else { return }
            switch state(row: row, column: 0) {
            case .deleted: rowView.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
            case .inserted, .defaultValue: rowView.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.10)
            default: break
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard tableColumn.identifier != Self.markerID else { return }
            onHeaderClick?(tableColumn.title)
        }

        func tableView(_ tableView: NSTableView, shouldReorder columnIndex: Int, toColumnIndex newColumnIndex: Int) -> Bool {
            columnIndex != 0 && newColumnIndex != 0
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let selection = tableView.selectedRowIndexes
            onSelectionChange?(selection)
            // Arrow keys move the row selection; keep the focused cell on the selected row.
            if selection.count == 1, let row = selection.first, row != focusedCell?.row {
                setFocus(GridCell(row: row, column: focusedCell?.column ?? 0), notify: true)
            }
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            let position = tableView.clickedColumn
            guard row >= 0, let column = dataColumn(at: position), canEdit(row: row, column: column) else { return }
            tableView.editColumn(position, row: row, with: nil, select: true)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // NULL is drawn as "(Null)"; start from an empty field instead of editing that label.
            guard let field = notification.object as? NSTextField, let (row, column) = position(of: field) else { return }
            field.textColor = .labelColor
            if value(row: row, column: column).isNull || state(row: row, column: column) == .defaultValue {
                field.currentEditor()?.string = ""
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let (row, column) = position(of: field) else { return }
            let newText = field.stringValue
            let current = value(row: row, column: column)
            let state = state(row: row, column: column)
            let unchanged = (current.isNull || state == .defaultValue) ? newText.isEmpty : newText == current.displayString
            if unchanged {
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
            } else {
                editing?.onEdit(row, column, .text(newText))
            }
        }

        private func position(of field: NSTextField) -> (Int, Int)? {
            guard let tableView else { return nil }
            let row = tableView.row(for: field)
            guard row >= 0, let column = dataColumn(at: tableView.column(for: field)) else { return nil }
            return (row, column)
        }

        func deleteSelectedRows() {
            guard let tableView, isEditable, !tableView.selectedRowIndexes.isEmpty else { return }
            editing?.onToggleDelete(tableView.selectedRowIndexes)
        }

        // MARK: Context menu

        /// The rows a context-menu command applies to: the selection if the click was inside it.
        private func targetRows() -> IndexSet {
            guard let tableView else { return [] }
            let clicked = tableView.clickedRow
            if clicked >= 0 && !tableView.selectedRowIndexes.contains(clicked) { return IndexSet(integer: clicked) }
            return tableView.selectedRowIndexes
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, tableView.clickedRow >= 0 else { return }
            let rows = targetRows()
            let column = dataColumn(at: tableView.clickedColumn)
            menu.addItem(item(rows.count > 1 ? "Copy \(rows.count) Rows" : "Copy Row", #selector(copyRows)))
            if column != nil { menu.addItem(item("Copy Cell Value", #selector(copyCell))) }
            guard isEditable else { return }
            menu.addItem(.separator())
            if let column, state(row: tableView.clickedRow, column: column) != .deleted {
                menu.addItem(item("Set to NULL", #selector(setNull)))
            }
            let allDeleted = rows.allSatisfy { state(row: $0, column: 0) == .deleted }
            let plural = rows.count > 1 ? "s" : ""
            menu.addItem(item(allDeleted ? "Restore Record\(plural)" : "Delete Record\(plural)", #selector(toggleDelete)))
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func copyRows() {
            copyToPasteboard(tsv(for: targetRows()))
        }

        @objc private func copyCell() {
            guard let tableView, let column = dataColumn(at: tableView.clickedColumn) else { return }
            copyToPasteboard(value(row: tableView.clickedRow, column: column).displayString)
        }

        @objc private func setNull() {
            guard let tableView, let column = dataColumn(at: tableView.clickedColumn) else { return }
            for row in targetRows() { editing?.onEdit(row, column, .null) }
        }

        @objc private func toggleDelete() {
            editing?.onToggleDelete(targetRows())
        }

        func copyToPasteboard(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Rows as tab-separated text with a header line, ready to paste into a spreadsheet.
        func tsv(for indexes: IndexSet) -> String {
            guard let tableView else { return "" }
            let order = tableView.tableColumns.filter { !$0.isHidden }.compactMap { Int($0.identifier.rawValue) }
            var lines = [order.map { columns[$0] }.joined(separator: "\t")]
            for row in indexes where row < rows.count {
                lines.append(order.map { value(row: row, column: $0).displayString }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        }
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: ResultGridView.Coordinator?

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !selectedRowIndexes.isEmpty else { return }
        coordinator.copyToPasteboard(coordinator.tsv(for: selectedRowIndexes))
    }

    override func keyDown(with event: NSEvent) {
        // Delete / forward delete mark the selected rows for deletion.
        if let coordinator, coordinator.isEditable, event.keyCode == 51 || event.keyCode == 117 {
            coordinator.deleteSelectedRows()
            return
        }
        super.keyDown(with: event)
    }
}

/// Keeps the first row below the header: when the header height changes around the first layout,
/// AppKit can leave the scroll offset at the old height and hide part of row 1.
final class GridScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let header = (documentView as? NSTableView)?.headerView else { return }
        let top = -header.frame.height
        let y = contentView.bounds.origin.y
        // Negative offsets only happen at the top; snap any stale one to the header height.
        if y < 0 && y != top {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: top))
            reflectScrolledClipView(contentView)
        }
    }
}

/// Header view whose height the table can't shrink back to the default.
final class GridHeaderView: NSTableHeaderView {
    var height: CGFloat = 24 {
        didSet { frame.size.height = height }
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            var adjusted = newValue
            adjusted.size.height = height
            super.frame = adjusted
        }
    }

    /// AppKit hands cells a default-height rect aligned to the bottom; use the full height instead.
    override func headerRect(ofColumn column: Int) -> NSRect {
        var rect = super.headerRect(ofColumn: column)
        rect.origin.y = bounds.minY
        rect.size.height = bounds.height
        return rect
    }
}

/// Light-blue row selection, so the focused cell (solid accent) stands out, as in Navicat.
final class GridRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.18 : 0.10).setFill()
        bounds.fill()
    }
}

/// Label with horizontal padding inside the grid cell.
final class PaddedTextField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            backgroundColor?.setFill()
            bounds.fill()
        }
        let inset = bounds.insetBy(dx: 6, dy: 0)
        let size = attributedStringValue.size()
        let rect = NSRect(x: inset.minX, y: (bounds.height - size.height) / 2, width: inset.width, height: size.height)
        if currentEditor() == nil {
            attributedStringValue.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            super.draw(dirtyRect)
        }
    }
}

/// Header cell with the column name on top and its type below ("# int4").
final class GridHeaderCell: NSTableHeaderCell {
    var typeName: String?
    var isFocused = false

    override func drawInterior(withFrame titleFrame: NSRect, in controlView: NSView) {
        // The filler area right of the last column reuses a header cell; draw nothing there.
        guard !stringValue.isEmpty else { return }
        // AppKit passes a vertically centered title rect; lay out against the full header height.
        let cellFrame = NSRect(x: titleFrame.minX, y: controlView.bounds.minY, width: titleFrame.width, height: controlView.bounds.height)
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            cellFrame.fill()
        }
        let inset = cellFrame.insetBy(dx: 6, dy: 0)
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let name = NSAttributedString(string: stringValue, attributes: nameAttributes)
        guard let typeName, !typeName.isEmpty else {
            let size = name.size()
            name.draw(with: NSRect(x: inset.minX, y: cellFrame.midY - size.height / 2, width: inset.width - 10, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        name.draw(with: NSRect(x: inset.minX, y: cellFrame.minY + 4, width: inset.width - 10, height: 16),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        var x = inset.minX
        let typeY = cellFrame.minY + 21
        if let symbol = NSImage(systemSymbolName: Self.symbolName(for: typeName), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor))) {
            symbol.draw(in: NSRect(x: x, y: typeY + 1, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 15
        }
        NSAttributedString(string: typeName, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(with: NSRect(x: x, y: typeY, width: inset.maxX - x - 10, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// "#" for numbers, a clock for dates, and so on, like Navicat's type glyphs.
    static func symbolName(for type: String) -> String {
        let t = type.lowercased()
        if ["int", "serial", "numeric", "decimal", "float", "double", "real", "money", "number", "bit"].contains(where: t.contains) { return "number" }
        if ["time", "date", "interval", "year"].contains(where: t.contains) { return "clock" }
        if ["bool"].contains(where: t.contains) { return "checkmark.square" }
        if ["json", "xml"].contains(where: t.contains) { return "curlybraces" }
        if ["blob", "bytea", "binary", "image"].contains(where: t.contains) { return "doc" }
        if t.contains("uuid") { return "key" }
        if ["geometry", "point", "polygon", "geography"].contains(where: t.contains) { return "map" }
        return "textformat"
    }
}

extension CellValue {
    var isNumeric: Bool {
        switch self {
        case .integer, .double: true
        default: false
        }
    }
}
