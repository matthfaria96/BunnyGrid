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
    /// Cells the one-line inline editor shouldn't take (multi-line text, blobs); they open the value editor.
    var prefersEditor: ((Int, Int) -> Bool)?
    var onSetDefault: ((Int, Int) -> Void)?
    var onDuplicate: ((IndexSet) -> Void)?
}

/// The value editor shown in a popover over a cell; `close` dismisses it.
typealias GridEditorContent = (GridCell, _ close: @escaping () -> Void) -> AnyView

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
    /// Columns that can't be edited inline (e.g. masked ones).
    var lockedColumns: Set<Int> = []
    var onFocusChange: ((GridCell?) -> Void)?
    var onSelectionChange: ((IndexSet) -> Void)?
    var scrollRequest: GridScrollRequest?
    /// Enables "Copy As › Insert / Update Statements" for this table.
    var copyTarget: GridCopyTarget?
    /// The value editor (⌥↩, double-click on long values); without it the grid only edits inline.
    var editorContent: GridEditorContent?
    var editorRequest: GridEditorRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GridContainerView {
        let tableView = GridTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        // The vertical lines come from `GridLinesView` (rows) and `GridTableView.drawGrid` (below the last row).
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.drawsVerticalGrid = true
        tableView.gridColor = .gridColor
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
        // Grid font and row shading come from Options › Records.
        context.coordinator.optionsObserver = NotificationCenter.default.addObserver(forName: .optionsDidChange, object: nil, queue: .main) { [weak tableView] _ in
            MainActor.assumeIsolated {
                Coordinator.cachedFont = nil
                tableView?.reloadData()
            }
        }
        return GridContainerView(scrollView: scrollView)
    }

    func updateNSView(_ container: GridContainerView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var tableView: GridTableView?
        var optionsObserver: NSObjectProtocol?
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
        private var lockedColumns: Set<Int> = []
        private var copyTarget: GridCopyTarget?
        private var editorContent: GridEditorContent?
        private var lastEditorRequest: GridEditorRequest?
        private var popover: NSPopover?

        /// Options › Records › Grid Font, or the default grid font.
        static var font: NSFont {
            if let cachedFont { return cachedFont }
            let font = AppOptions.shared.values.gridFont?.nsFont ?? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cachedFont = font
            return font
        }
        /// Resolved once per Options change instead of for every cell.
        static var cachedFont: NSFont?
        private static let leftParagraph = paragraph(.left)
        private static let rightParagraph = paragraph(.right)
        private static let rowID = NSUserInterfaceItemIdentifier("GridRow")

        private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            return style
        }
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
            copyTarget = view.copyTarget
            editorContent = view.editorContent
            let lockedChanged = view.lockedColumns != lockedColumns
            lockedColumns = view.lockedColumns
            let typesChanged = view.columnTypes != columnTypes
            let columnsChanged = view.columns != columns || typesChanged
            // Reload only on real changes: an unrelated SwiftUI update must not end an in-progress cell edit.
            let contentChanged = columnsChanged || lockedChanged || view.rows != rows || view.editing?.revision != revision
            columns = view.columns
            rows = view.rows
            columnTypes = view.columnTypes
            numericColumns = Set(columns.indices.filter { index in
                columnTypes[columns[index]].map { GridHeaderCell.symbolName(for: $0) == "number" } ?? false
            })
            revision = view.editing?.revision
            if columnsChanged { rebuildColumns(tableView) }
            var hiddenChanged = false
            for column in tableView.tableColumns where column.identifier != Self.markerID {
                let hidden = view.hiddenColumns.contains(column.title)
                if column.isHidden != hidden {
                    column.isHidden = hidden
                    hiddenChanged = true
                }
            }
            if hiddenChanged || columnsChanged {
                loadVisibleColumns()
                (tableView as? GridTableView)?.invalidateGridLines()
            }
            if contentChanged {
                tableView.reloadData()
                didReloadAllColumns(tableView)
            }
            if view.focusedCell != focusedCell { setFocus(view.focusedCell, notify: false) }
            updateSortIndicators(tableView, sort: view.sort)
            if let request = view.scrollRequest, request != lastScrollRequest, request.row < rows.count {
                lastScrollRequest = request
                tableView.scrollRowToVisible(request.row)
                tableView.selectRowIndexes(IndexSet(integer: request.row), byExtendingSelection: false)
            }
            if let request = view.editorRequest, request != lastEditorRequest {
                lastEditorRequest = request
                // Wait for the reload and scroll above to lay out the cell the popover points at.
                DispatchQueue.main.async { [weak self] in self?.showEditor(for: request.cell) }
            }
        }

        // MARK: Value editor

        var hasEditor: Bool { editorContent != nil }

        /// Opens the value editor in a popover pointing at the cell.
        func showEditor(for cell: GridCell) {
            guard let tableView, let editorContent, cell.row < rows.count,
                  let position = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(cell.column) }) else { return }
            if tableView.currentEditor() != nil { tableView.window?.makeFirstResponder(tableView) }
            popover?.close()
            setFocus(cell, notify: true)
            tableView.scrollRowToVisible(cell.row)
            tableView.scrollColumnToVisible(position)
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            let host = NSHostingController(rootView: editorContent(cell) { [weak popover, weak tableView] in
                popover?.close()
                if let tableView { tableView.window?.makeFirstResponder(tableView) }
            })
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.show(relativeTo: tableView.frameOfCell(atColumn: position, row: cell.row), of: tableView, preferredEdge: .maxY)
            self.popover = popover
        }

        /// ⌥↩ opens the value editor on the focused cell.
        func showEditorForFocused() {
            guard let cell = focusedCell else { return }
            showEditor(for: cell)
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
            marker.width = 14
            marker.minWidth = 14
            marker.maxWidth = 14
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

        /// Width that fits the header and the widest of the first `sample` values, measured with the grid font.
        private func estimatedWidth(column: Int, title: String, type: String?, sample: Int = 60, cap: CGFloat = 360) -> CGFloat {
            let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            // Header: 6pt inset each side plus room for the sort indicator; type line adds the glyph.
            var width = (title as NSString).size(withAttributes: [.font: headerFont]).width + 34
            if let type { width = max(width, (type as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 50) }
            for row in rows.prefix(sample) where row.indices.contains(column) {
                let text = row[column].isNull ? "(NULL)" : row[column].displayString
                width = max(width, (text as NSString).size(withAttributes: [.font: Self.font]).width + 22)
                if width >= cap { break }
            }
            return min(cap, max(72, ceil(width)))
        }

        /// Double-clicking a header divider fits the column to its content.
        /// The row-marker column stays first: it can't be dragged, and no data column can be dropped in front of it.
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            let columns = tableView.tableColumns
            if columns.indices.contains(columnIndex), columns[columnIndex].identifier == Self.markerID { return false }
            return !(newColumnIndex == 0 && columns.first?.identifier == Self.markerID)
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
            let column = tableView.tableColumns[columnIndex]
            guard let index = Int(column.identifier.rawValue) else { return column.width }
            return estimatedWidth(column: index, title: column.title, type: columnTypes[column.title], sample: 1000, cap: 800)
        }

        // MARK: Column virtualization

        // NSTableView makes a cell for every column of every row it shows: with twenty columns and five on screen, a
        // column resize moved (and a vertical scroll made) four times the cells anyone could see. Here a new row gets
        // cells for the visible columns (and one either side), a column resize first drops the cells that are off
        // screen, and once the grid is idle the other columns are filled in one per run-loop turn, so a horizontal
        // scroll afterwards finds them ready.

        /// Table positions with cells in every row on hand.
        private var loadedColumns = IndexSet()
        /// Columns `viewFor` also makes cells for, while they are being filled in.
        private var backfillColumns = IndexSet()
        private var backfillGeneration = 0

        /// The columns to make cells for, or nil for all of them (before the table has a visible area).
        func columnsToLoad(_ tableView: NSTableView) -> IndexSet? {
            let visible = tableView.visibleRect
            guard !visible.isEmpty, tableView.numberOfColumns > 0 else { return nil }
            let indexes = tableView.columnIndexes(in: visible)
            guard let first = indexes.first, let last = indexes.last else { return IndexSet() }
            return IndexSet(integersIn: max(first - 1, 0)...min(last + 1, tableView.numberOfColumns - 1))
        }

        func makesCell(_ tableView: NSTableView, position: Int) -> Bool {
            guard let wanted = columnsToLoad(tableView) else { return true }
            return wanted.contains(position) || backfillColumns.contains(position)
        }

        private func reloadCells(_ tableView: NSTableView, columns: IndexSet) {
            var rows = IndexSet()
            tableView.enumerateAvailableRowViews { _, row in rows.insert(row) }
            if !rows.isEmpty, !columns.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: columns) }
        }

        /// Fills in the cells of columns that came on screen (horizontal scroll, a wider view, shown columns).
        func loadVisibleColumns() {
            guard let tableView else { return }
            let wanted = columnsToLoad(tableView) ?? IndexSet(integersIn: 0..<tableView.numberOfColumns)
            let missing = wanted.subtracting(loadedColumns)
            if !missing.isEmpty {
                reloadCells(tableView, columns: missing)
                loadedColumns.formUnion(missing)
            }
            scheduleBackfill()
        }

        /// A column resize moves every cell right of the resized column: drop the ones off screen first.
        func columnsDidResize() {
            guard let tableView, let wanted = columnsToLoad(tableView) else { return }
            let offScreen = loadedColumns.subtracting(wanted)
            if !offScreen.isEmpty {
                backfillGeneration += 1
                reloadCells(tableView, columns: offScreen)
                loadedColumns.subtract(offScreen)
            }
            loadVisibleColumns()
        }

        /// A row brought on screen (vertical scroll) has cells for the visible columns only.
        func rowWasAdded() {
            guard let tableView, let wanted = columnsToLoad(tableView) else { return }
            if !loadedColumns.isSubset(of: wanted) { loadedColumns.formIntersection(wanted) }
            scheduleBackfill()
        }

        /// After a full reload every row has exactly the columns `columnsToLoad` returned.
        private func didReloadAllColumns(_ tableView: NSTableView) {
            loadedColumns = columnsToLoad(tableView) ?? IndexSet(integersIn: 0..<tableView.numberOfColumns)
            scheduleBackfill()
        }

        /// Fills in the off-screen columns once nothing has moved for a moment, nearest first.
        private func scheduleBackfill() {
            backfillGeneration += 1
            let generation = backfillGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.backfillStep(generation)
            }
        }

        private func backfillStep(_ generation: Int) {
            guard generation == backfillGeneration, let tableView, tableView.window != nil else { return }
            // Never under an open cell editor: a reload would end the edit.
            if tableView.currentEditor() != nil { return scheduleBackfill() }
            let missing = IndexSet(integersIn: 0..<tableView.numberOfColumns).subtracting(loadedColumns)
            guard let wanted = columnsToLoad(tableView), let center = wanted.first, !missing.isEmpty else { return }
            let next = missing.min { abs($0 - center) < abs($1 - center) } ?? missing.first!
            backfillColumns = [next]
            reloadCells(tableView, columns: [next])
            backfillColumns = []
            loadedColumns.insert(next)
            // One column per run-loop turn, so input and frames keep going in between.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                self?.backfillStep(generation)
            }
        }

        // MARK: Keyboard

        /// ← / → move the focused cell between visible columns.
        func moveFocus(by delta: Int) {
            guard let tableView else { return }
            let visible = tableView.tableColumns.filter { !$0.isHidden }.compactMap { Int($0.identifier.rawValue) }
            guard !visible.isEmpty else { return }
            let row = focusedCell?.row ?? max(tableView.selectedRow, 0)
            let current = focusedCell.flatMap { visible.firstIndex(of: $0.column) } ?? (delta > 0 ? -1 : visible.count)
            let next = visible[min(max(current + delta, 0), visible.count - 1)]
            setFocus(GridCell(row: row, column: next), notify: true)
            if let position = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(next) }) {
                tableView.scrollColumnToVisible(position)
            }
        }

        /// Return edits the focused cell; typing a character starts editing with that character.
        @discardableResult
        func beginEditingFocused(with text: String? = nil) -> Bool {
            if text == nil, let cell = focusedCell, hasEditor, cell.row < rows.count, !canEdit(row: cell.row, column: cell.column),
               isEditable, editing?.prefersEditor?(cell.row, cell.column) == true {
                // Return on a long or binary value opens the full editor instead.
                showEditor(for: cell)
                return true
            }
            guard let tableView, let cell = focusedCell, canEdit(row: cell.row, column: cell.column),
                  let position = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(cell.column) }) else { return false }
            tableView.scrollColumnToVisible(position)
            loadVisibleColumns()
            tableView.editColumn(position, row: cell.row, with: nil, select: true)
            if let text, let editor = tableView.currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
            return true
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

        /// Inline editing handles single-line text; long values, blobs and binary columns go through the value editor.
        private func canEdit(row: Int, column: Int) -> Bool {
            guard isEditable, !lockedColumns.contains(column), state(row: row, column: column) != .deleted else { return false }
            if editing?.prefersEditor?(row, column) == true { return false }
            let value = value(row: row, column: column)
            if case .blob = value { return false }
            return !value.displayString.contains(where: \.isNewline)
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
            // Reused like the cells, instead of a new row view per row scrolled in.
            let view = tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? GridRowView ?? GridRowView()
            view.identifier = Self.rowID
            view.isShaded = GridRowView.isShaded(row: row)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            // Only the columns on screen get cells (see `loadVisibleColumns`).
            if !makesCell(tableView, position: tableView.column(withIdentifier: tableColumn.identifier)) { return nil }
            if tableColumn.identifier == Self.markerID {
                let marker = tableView.makeView(withIdentifier: Self.markerID, owner: nil) as? RowMarkerView ?? {
                    let view = RowMarkerView()
                    view.wantsLayer = true
                    view.identifier = Self.markerID
                    return view
                }()
                marker.mark = switch state(row: row, column: 0) {
                case .inserted, .defaultValue: .inserted
                case .deleted: .deleted
                default: focusedCell?.row == row ? .current : .none
                }
                return marker
            }
            let field = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTextField ?? makeField()
            guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let value = value(row: row, column: column)
            let state = state(row: row, column: column)
            let isFocused = focusedCell == GridCell(row: row, column: column)
            // Navicat draws NULL as "(NULL)" and unset cells of a new record as "(Default)".
            let text: String = if state == .defaultValue || state == .editedDefault {
                "(Default)"
            } else if value.isNull {
                "(NULL)"
            } else if case .blob(let data) = value {
                Self.blobLabel(data)
            } else {
                value.displayString
            }

            let color: NSColor = if isFocused {
                .white
            } else {
                switch state {
                case .edited, .editedDefault: .systemOrange
                case .inserted: .systemGreen
                case .defaultValue: .tertiaryLabelColor
                case .deleted: .secondaryLabelColor
                case .normal: value.isNull || value.isBlob ? .tertiaryLabelColor : .labelColor
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            if state == .deleted { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributes[.paragraphStyle] = value.isNumeric || numericColumns.contains(column) ? Self.rightParagraph : Self.leftParagraph
            field.attributedStringValue = Self.singleLine(text, attributes: attributes, markerColor: color.withAlphaComponent(0.5))
            field.drawsBackground = isFocused
            field.backgroundColor = isFocused ? .controlAccentColor : .clear
            field.isEditable = canEdit(row: row, column: column)
            return field
        }

        /// Multi-line text on one line: each line break becomes a dimmed ⏎ marker. Only the start of
        /// very long values is laid out; the cell truncates it anyway.
        static func singleLine(_ text: String, attributes: [NSAttributedString.Key: Any], markerColor: NSColor) -> NSAttributedString {
            let visible = text.utf16.count > 600 ? String(text.prefix(600)) : text
            guard visible.contains(where: \.isNewline) else { return NSAttributedString(string: visible, attributes: attributes) }
            var marker = attributes
            marker[.foregroundColor] = markerColor
            let result = NSMutableAttributedString()
            var first = true
            for line in visible.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                if !first { result.append(NSAttributedString(string: " ⏎ ", attributes: marker)) }
                result.append(NSAttributedString(string: String(line), attributes: attributes))
                first = false
            }
            return result
        }

        /// "(PNG) 12.3 KB", "(Binary) 16 bytes": what a blob is, instead of its bytes.
        static func blobLabel(_ data: Data) -> String {
            let kind = BlobKind.detect(data)
            let name = switch kind {
            case .binary: "Binary"
            case .utf8Text: "Text"
            default: kind.rawValue.uppercased()
            }
            return "(\(name)) " + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }

        private func makeField() -> NSTextField {
            let field = PaddedTextField(labelWithString: "")
            field.identifier = Self.cellID
            field.font = Self.font
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.delegate = self
            // Its own layer: a column resize or a horizontal scroll moves the cell instead of redrawing it into the
            // row (see `GridRowView`).
            field.wantsLayer = true
            return field
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            rowWasAdded()
            guard isEditable, !columns.isEmpty else { return }
            switch state(row: row, column: 0) {
            case .deleted: rowView.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
            case .inserted, .defaultValue: rowView.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.10)
            default: rowView.backgroundColor = tableView.backgroundColor // a reused row may carry a tint
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
            guard row >= 0, let column = dataColumn(at: position) else { return }
            if canEdit(row: row, column: column) {
                tableView.editColumn(position, row: row, with: nil, select: true)
            } else if hasEditor {
                // Long text, blobs and read-only grids open the full value editor.
                showEditor(for: GridCell(row: row, column: column))
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // NULL is drawn as "(NULL)"; start from an empty field instead of editing that label.
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

        /// ⌥↩ while typing in a cell keeps what was typed and continues in the value editor.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), hasEditor,
                  let field = control as? NSTextField, let (row, column) = position(of: field), let tableView else { return false }
            tableView.window?.makeFirstResponder(tableView)
            showEditor(for: GridCell(row: row, column: column))
            return true
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
            let plural = rows.count > 1 ? "s" : ""
            if column != nil, hasEditor {
                let open = item("Open in Value Editor", #selector(openEditor), image: "square.and.pencil")
                open.keyEquivalent = "\r"
                open.keyEquivalentModifierMask = .option
                menu.addItem(open)
                menu.addItem(.separator())
            }
            menu.addItem(item(rows.count > 1 ? "Copy \(rows.count) Rows" : "Copy Row", #selector(copyRows), image: "doc.on.doc"))
            if column != nil { menu.addItem(item("Copy Cell Value", #selector(copyCell))) }
            menu.addItem(copyAsItem())
            guard isEditable else { return }
            menu.addItem(.separator())
            if let column, state(row: tableView.clickedRow, column: column) != .deleted, !lockedColumns.contains(column) {
                menu.addItem(item("Set to NULL", #selector(setNull)))
                menu.addItem(item("Set to Empty String", #selector(setEmpty)))
                if editing?.onSetDefault != nil { menu.addItem(item("Set to DEFAULT", #selector(setDefault))) }
                menu.addItem(.separator())
            }
            if editing?.onDuplicate != nil {
                menu.addItem(item("Duplicate Record\(plural)", #selector(duplicateRows), image: "plus.square.on.square"))
            }
            let allDeleted = rows.allSatisfy { state(row: $0, column: 0) == .deleted }
            menu.addItem(item(allDeleted ? "Restore Record\(plural)" : "Delete Record\(plural)", #selector(toggleDelete),
                              image: allDeleted ? "arrow.uturn.backward" : "trash"))
        }

        private func item(_ title: String, _ action: Selector, image: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let image { item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            return item
        }

        /// "Copy As ▸": statements (with a table), TSV, CSV, JSON and Markdown of the target rows.
        private func copyAsItem() -> NSMenuItem {
            let submenu = NSMenu()
            for format in RowCopyFormat.allCases {
                if format.needsTable && copyTarget == nil { continue }
                if format == .updateStatements && (copyTarget?.keyColumns.isEmpty ?? true) { continue }
                if format == .tsv { submenu.addItem(.separator()) }
                let entry = item(format.displayName, #selector(copyAs(_:)))
                entry.representedObject = format.rawValue
                submenu.addItem(entry)
            }
            let parent = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            return parent
        }

        @objc private func copyAs(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let format = RowCopyFormat(rawValue: raw), let tableView else { return }
            let order = tableView.tableColumns.filter { !$0.isHidden }.compactMap { Int($0.identifier.rawValue) }
            let selected = targetRows().filter { $0 < rows.count }
            let text = RowCopier.text(format, columns: order.map { columns[$0] },
                                      rows: selected.map { row in order.map { value(row: row, column: $0) } },
                                      table: copyTarget?.table, schema: copyTarget?.schema, kind: copyTarget?.kind ?? .postgresql,
                                      keyColumns: copyTarget?.keyColumns ?? [])
            if let text { copyToPasteboard(text) } else { NSSound.beep() }
        }

        @objc private func openEditor() {
            guard let tableView, let column = dataColumn(at: tableView.clickedColumn) else { return }
            showEditor(for: GridCell(row: tableView.clickedRow, column: column))
        }

        @objc private func setEmpty() {
            guard let tableView, let column = dataColumn(at: tableView.clickedColumn) else { return }
            for row in targetRows() { editing?.onEdit(row, column, .text("")) }
        }

        @objc private func setDefault() {
            guard let tableView, let column = dataColumn(at: tableView.clickedColumn) else { return }
            for row in targetRows() { editing?.onSetDefault?(row, column) }
        }

        @objc private func duplicateRows() {
            editing?.onDuplicate?(targetRows())
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
    private var visibleSpan: (CGFloat, CGFloat)?
    /// Solid vertical grid lines, drawn by the rows' `GridLinesView`s and, under the last row, here.
    var drawsVerticalGrid = false

    // Inside a scroll view the table's own size is all that matters: an intrinsic-size change on every column-width
    // change only made the enclosing SwiftUI host lay itself out again each frame of a resize.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}

    override func drawGrid(inClipRect clipRect: NSRect) {
        super.drawGrid(inClipRect: clipRect)
        guard drawsVerticalGrid else { return }
        let top = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : bounds.minY
        guard clipRect.maxY > top else { return }
        gridColor.setFill()
        var x: CGFloat = 0
        for column in tableColumns where !column.isHidden {
            x += column.width + intercellSpacing.width
            guard x - 1 >= clipRect.minX - 1, x - 1 <= clipRect.maxX else { continue }
            NSRect(x: x - 1, y: max(top, clipRect.minY), width: 1, height: clipRect.maxY - max(top, clipRect.minY)).fill()
        }
    }

    /// Re-places the rows' vertical grid lines (`GridLinesView`) after columns moved, resized or scrolled sideways.
    func invalidateGridLines() {
        enumerateAvailableRowViews { rowView, _ in
            (rowView as? GridRowView)?.needsLayout = true
        }
    }

    // Weak: the clip view owns the table (its document view); a strong reference kept every grid alive.
    private weak var observedClip: NSClipView?
    private var observesColumns = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        let center = NotificationCenter.default
        if !observesColumns {
            observesColumns = true
            for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
                center.addObserver(self, selector: #selector(columnsChanged(_:)), name: name, object: self)
            }
        }
        if let old = observedClip { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old) }
        observedClip = superview as? NSClipView
        if let clip = observedClip {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func columnsChanged(_ notification: Notification) {
        if notification.name == NSTableView.columnDidResizeNotification {
            coordinator?.columnsDidResize()
        } else {
            coordinator?.loadVisibleColumns()
        }
        invalidateGridLines()
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        // Only a horizontal scroll or a new width brings other columns on screen.
        let span = (visibleRect.minX, visibleRect.width)
        guard span.0 != visibleSpan?.0 || span.1 != visibleSpan?.1 else { return }
        visibleSpan = span
        coordinator?.loadVisibleColumns()
        invalidateGridLines()
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !selectedRowIndexes.isEmpty else { return }
        coordinator.copyToPasteboard(coordinator.tsv(for: selectedRowIndexes))
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51 where coordinator.isEditable, 117 where coordinator.isEditable:
            // Delete / forward delete mark the selected rows for deletion.
            coordinator.deleteSelectedRows()
        case 123 where modifiers.isEmpty:
            coordinator.moveFocus(by: -1)
        case 124 where modifiers.isEmpty:
            coordinator.moveFocus(by: 1)
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:
            if !coordinator.beginEditingFocused() { super.keyDown(with: event) }
        case 36 where modifiers == .option, 76 where modifiers == .option:
            // ⌥↩ opens the full value editor (multi-line text, JSON, blobs, dates).
            if coordinator.hasEditor { coordinator.showEditorForFocused() } else { super.keyDown(with: event) }
        default:
            // Typing a printable character starts editing the focused cell, as in a spreadsheet.
            if modifiers.isEmpty, let characters = event.characters, characters.count == 1,
               let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
               scalar.value < 0xF700, coordinator.beginEditingFocused(with: characters) {
                return
            }
            super.keyDown(with: event)
        }
    }
}

/// Keeps the first row below the header: when the header height changes around the first layout,
/// AppKit can leave the scroll offset at the old height and hide part of row 1.
/// The view SwiftUI hosts: a plain frame around the scroll view, so nothing the table does while resizing
/// columns or scrolling (frame, layout and intrinsic-size changes) reaches SwiftUI and re-lays out the whole tab.
final class GridContainerView: NSView {
    let scrollView: NSScrollView

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}
}

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

/// The gray gutter left of the data: a blue bar on the current row, + / − for new and deleted rows (Navicat's record selector).
final class RowMarkerView: NSView {
    enum Mark { case none, current, inserted, deleted }

    var mark: Mark = .none {
        didSet { if mark != oldValue { needsDisplay = true } }
    }

    static let gutterColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.gutterColor.setFill()
        bounds.fill()
        switch mark {
        case .none:
            break
        case .current:
            NSColor.controlAccentColor.setFill()
            NSRect(x: bounds.maxX - 4, y: bounds.minY + 1, width: 3, height: bounds.height - 2).fill()
        case .inserted, .deleted:
            let glyph = mark == .inserted ? "+" : "−"
            let color: NSColor = mark == .inserted ? .systemGreen : .systemRed
            let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}

/// Light-blue row selection, so the focused cell (solid accent) stands out, as in Navicat.
///
/// A row looks the same all along its width (background, shading, selection, the grid line below), so when it gets
/// wider or narrower its layer scales what it drew instead of drawing it again: a row as wide as twenty columns
/// used to redraw and upload its whole bitmap on every frame of a column resize, which is what made that slow. The
/// cells have their own layers and the vertical grid lines are colour layers (`GridLinesView`), so moving columns
/// redraws nothing but the resized column's cells.
final class GridRowView: NSTableRowView {
    var isShaded = false {
        didSet { if isShaded != oldValue { needsDisplay = true } }
    }
    private let lines = GridLinesView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        lines.frame = bounds
        addSubview(lines)
        // Above the cells, which AppKit adds later (a line crosses the grid line below the row, as before).
        lines.layer?.zPosition = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Options › Records › Row Shading: every other or every third row is tinted.
    @MainActor
    static func isShaded(row: Int) -> Bool {
        switch AppOptions.shared.values.rowShading {
        case .none: false
        case .everyOtherRow: row % 2 == 1
        case .everyThirdRow: row % 3 == 2
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isShaded {
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.18 : 0.10).setFill()
        bounds.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let height = frame.height, hadWidth = frame.width > 0
        super.setFrameSize(newSize)
        // Only a new height (or a first real size) needs a new drawing; a new width is a stretch.
        if newSize.height != height || !hadWidth { needsDisplay = true }
        placeGridLines()
    }

    override func layout() {
        super.layout()
        placeGridLines()
    }

    private func placeGridLines() {
        lines.frame = bounds
        lines.needsLayout = true
        lines.layoutSubtreeIfNeeded()
    }
}

/// The vertical grid lines of a row: one colour layer per column edge (no bitmap), moved when columns change.
final class GridLinesView: NSView {
    private var edges: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        let color = ((superview as? NSTableRowView).flatMap { $0.superview as? NSTableView }?.gridColor ?? .gridColor).cgColor
        for edge in edges { edge.backgroundColor = color }
    }

    override func layout() {
        super.layout()
        guard let table = superview?.superview as? GridTableView, table.drawsVerticalGrid else {
            edges.forEach { $0.isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = table.gridColor.cgColor
        var index = 0
        var x: CGFloat = 0
        let visible = table.visibleRect
        for column in table.tableColumns where !column.isHidden {
            x += column.width + table.intercellSpacing.width
            // Only the edges on screen get a layer.
            guard x - 1 >= visible.minX - 1, x - 1 <= visible.maxX + 1 else { continue }
            if index == edges.count {
                let edge = CALayer()
                edge.backgroundColor = color
                layer?.addSublayer(edge)
                edges.append(edge)
            }
            edges[index].isHidden = false
            edges[index].frame = CGRect(x: x - 1, y: 0, width: 1, height: bounds.height)
            index += 1
        }
        for edge in edges[index...] { edge.isHidden = true }
        CATransaction.commit()
    }
}

/// Label with horizontal padding inside the grid cell.
final class PaddedTextField: NSTextField {
    private static var lineHeights: [NSFont: CGFloat] = [:]

    static func lineHeight(for font: NSFont?) -> CGFloat {
        let font = font ?? .systemFont(ofSize: 12)
        if let height = lineHeights[font] { return height }
        let height = NSAttributedString(string: "Xg", attributes: [.font: font]).size().height
        lineHeights[font] = height
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            backgroundColor?.setFill()
            bounds.fill()
        }
        let inset = bounds.insetBy(dx: 6, dy: 0)
        var string = attributedStringValue
        // One line of the cell font: no need to measure the string on every draw.
        let height = Self.lineHeight(for: string.length > 0 ? string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : font)
        let rect = NSRect(x: inset.minX, y: (bounds.height - height) / 2, width: inset.width, height: height)
        if currentEditor() == nil {
            // Truncating lays out the whole string; hand it only what can fit (no glyph is narrower than
            // ~3 pt), so a long value costs the same as a short one. The visible part and the ellipsis are unchanged.
            let fits = Int(inset.width / 3) + 8
            if string.length > fits {
                let cut = (string.string as NSString).rangeOfComposedCharacterSequence(at: fits).location
                string = string.attributedSubstring(from: NSRange(location: 0, length: cut))
            }
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
        if let symbol = Self.symbol(for: typeName) {
            symbol.draw(in: NSRect(x: x, y: typeY + 1, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 15
        }
        NSAttributedString(string: typeName, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemBlue,
        ]).draw(with: NSRect(x: x, y: typeY, width: inset.maxX - x - 10, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Configured type glyphs, one per symbol name: building one (`withSymbolConfiguration`, hierarchical layers) on
    /// every header draw was half the cost of a column-resize frame.
    private static var symbols: [String: NSImage] = [:]

    static func symbol(for typeName: String) -> NSImage? {
        let name = symbolName(for: typeName)
        if let cached = symbols[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(hierarchicalColor: .systemBlue)))
        symbols[name] = image
        return image
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
        return "textformat.abc"
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
