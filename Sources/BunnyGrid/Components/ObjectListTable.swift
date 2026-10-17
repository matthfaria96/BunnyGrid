import AppKit
import SwiftUI

/// One column of an `ObjectListTable`.
struct ObjectListColumn: Equatable {
    var title: String
    var width: CGFloat = 120
    var minWidth: CGFloat = 50
    var trailing = false
}

/// One row: an illustrated icon and the text of each column (the first column carries the icon).
struct ObjectListRow: Equatable, Identifiable {
    var id: String
    var icon: String
    var cells: [String]
    var dimmed = false
    var starred = false
    /// Columns drawn in the secondary label color.
    var secondaryColumns: IndexSet = []
}

/// Navicat's object list: an AppKit table with 19 pt rows, no separators, inset selection and resizable columns.
/// AppKit rather than SwiftUI's `Table`, which crashed in its outline coordinator when updated while hidden
/// behind another tab, and which can't be made this dense. Stays fast with thousands of rows (cells are reused).
struct ObjectListTable: NSViewRepresentable {
    var columns: [ObjectListColumn]
    var rows: [ObjectListRow]
    @Binding var selection: Set<String>
    var onOpen: (Set<String>) -> Void = { _ in }
    /// Remembers column widths per list kind ("tables-sqlite", …).
    var autosaveName: String?
    /// The right-click menu for the selected rows' ids (a right-click first selects the clicked row). SwiftUI's
    /// `.contextMenu` on this representable never showed: the table's own context-menu handling found no menu
    /// and did not pass the click up to SwiftUI.
    var contextMenu: ((Set<String>) -> AnyView)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ObjectNSTableView()
        table.style = .inset
        table.rowHeight = 19
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = .clear
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        table.menuProvider = { [weak coordinator = context.coordinator] in coordinator?.contextMenu() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Navicat indents the list (header and rows) about 20 pt from the pane edge.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        context.coordinator.table = table
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ObjectListTable
        weak var table: NSTableView?
        private var rows: [ObjectListRow] = []
        private var columns: [ObjectListColumn] = []
        private var updatingSelection = false

        init(_ parent: ObjectListTable) { self.parent = parent }

        func apply(_ parent: ObjectListTable, force: Bool) {
            self.parent = parent
            guard let table else { return }
            if force || parent.columns.map(\.title) != columns.map(\.title) {
                columns = parent.columns
                for column in table.tableColumns { table.removeTableColumn(column) }
                for (index, spec) in columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                    column.title = spec.title
                    column.width = spec.width
                    column.minWidth = spec.minWidth
                    column.headerCell.font = .systemFont(ofSize: 11.5, weight: .medium)
                    if spec.trailing { column.headerCell.alignment = .right }
                    table.addTableColumn(column)
                }
                table.autosaveName = parent.autosaveName
                table.autosaveTableColumns = parent.autosaveName != nil
                rows = parent.rows
                table.reloadData()
            } else if parent.rows != rows {
                rows = parent.rows
                table.reloadData()
            }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if wanted != table.selectedRowIndexes {
                updatingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                updatingSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = tableView.tableColumns.firstIndex(of: tableColumn), row < rows.count else { return nil }
            let item = rows[row]
            let isName = index == 0
            let identifier = NSUserInterfaceItemIdentifier(isName ? "name" : "text")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ObjectCellView) ?? ObjectCellView(withIcon: isName, identifier: identifier)
            let text = index < item.cells.count ? item.cells[index] : ""
            cell.textField?.stringValue = text
            cell.textField?.alignment = index < columns.count && columns[index].trailing ? .right : .left
            cell.textField?.textColor = item.dimmed || item.secondaryColumns.contains(index) ? .secondaryLabelColor : .labelColor
            if isName {
                cell.imageView?.image = IconLibrary.image(item.icon)
                cell.imageView?.alphaValue = item.dimmed ? 0.5 : 1
                cell.star.isHidden = !item.starred
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            if ids != parent.selection { parent.selection = ids }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            openSelection()
        }

        func openSelection() {
            guard let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            if !ids.isEmpty { parent.onOpen(ids) }
        }

        func contextMenu() -> NSMenu? {
            guard let table, let content = parent.contextMenu else { return nil }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            guard !ids.isEmpty else { return nil }
            if #available(macOS 14.4, *) { return NSHostingMenu(rootView: content(ids)) }
            return nil
        }
    }
}

/// Return opens the selection; a right-click selects the clicked row first so the context menu acts on it.
private final class ObjectNSTableView: NSTableView {
    var onReturn: () -> Void = {}
    var menuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?() ?? super.menu(for: event)
    }
}

private final class ObjectCellView: NSTableCellView {
    let star = NSImageView()

    init(withIcon: Bool, identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        var constraints = [field.centerYAnchor.constraint(equalTo: centerYAnchor),
                           field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)]
        if withIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [.systemYellow])))
            star.translatesAutoresizingMaskIntoConstraints = false
            addSubview(star)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                star.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
                star.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            constraints += [field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
