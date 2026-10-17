import AppKit
import BunnyGridCore
import SwiftUI

/// The Query Builder's diagram: table boxes with column checkboxes and the join lines between them,
/// drawn by one NSView. Drag a header to move a box, a column onto another table's column to join them,
/// click a line's badge to change the join type, drop a table from the object list to add it.
struct QueryBuilderCanvas: NSViewRepresentable {
    let model: QueryBuilderModel

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = QueryBuilderCanvasView()
        canvas.model = model
        #if DEBUG
        UIHarness.register("qb", model)
        #endif
        let scroll = QueryBuilderScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        canvas.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading the model here makes SwiftUI call this again whenever it changes.
        _ = model.query
        _ = model.positions
        _ = model.columns
        guard let canvas = scroll.documentView as? QueryBuilderCanvasView else { return }
        canvas.fitContent(minimum: scroll.contentSize)
        canvas.needsDisplay = true
    }
}

/// Keeps the diagram at least as large as the visible area. The canvas used to be sized only in
/// updateNSView, which can run before the scroll view has a size: it then stayed 0×0 and the first
/// table dropped from the list landed on the clip view (refused) until the model changed.
final class QueryBuilderScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? QueryBuilderCanvasView)?.fitContent(minimum: contentSize)
    }
}

final class QueryBuilderCanvasView: NSView {
    weak var model: QueryBuilderModel?

    static let tableDragPrefix = "bunnygrid.querybuilder.table:"
    private let boxWidth: CGFloat = 190
    private let headerHeight: CGFloat = 24
    private let rowHeight: CGFloat = 19
    private let maxRows = 14

    private enum Drag {
        case move(Int, offset: CGPoint)
        case link(Int, String, to: CGPoint)
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fitContent(minimum: NSSize) {
        guard let model else { return }
        var size = minimum
        for table in model.query.tables {
            let box = frame(for: table.id)
            size.width = max(size.width, box.maxX + 40)
            size.height = max(size.height, box.maxY + 40)
        }
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: Geometry

    /// "*" first, then the table's columns.
    private func rows(_ id: Int) -> [String] {
        ["*"] + (model?.columnNames(id) ?? [])
    }

    private func frame(for id: Int) -> NSRect {
        let origin = model?.positions[id] ?? .zero
        let count = min(rows(id).count, maxRows)
        return NSRect(x: origin.x, y: origin.y, width: boxWidth, height: headerHeight + CGFloat(count) * rowHeight + 4)
    }

    private func rowRect(_ id: Int, _ index: Int) -> NSRect {
        let box = frame(for: id)
        return NSRect(x: box.minX, y: box.minY + headerHeight + CGFloat(index) * rowHeight, width: box.width, height: rowHeight)
    }

    /// Where a join line meets column `name` of table `id`: the box side facing `toward`.
    private func anchor(_ id: Int, _ name: String, toward x: CGFloat) -> CGPoint {
        let box = frame(for: id)
        let index = rows(id).firstIndex(of: name).map { min($0, maxRows - 1) } ?? 0
        let row = rowRect(id, index)
        return CGPoint(x: x > box.midX ? box.maxX : box.minX, y: row.midY)
    }

    private func hitTable(_ point: CGPoint) -> Int? {
        model?.query.tables.reversed().first { frame(for: $0.id).contains(point) }?.id
    }

    private func hitRow(_ id: Int, _ point: CGPoint) -> String? {
        let box = frame(for: id)
        let index = Int((point.y - box.minY - headerHeight) / rowHeight)
        let names = rows(id)
        guard point.y >= box.minY + headerHeight, index >= 0, index < min(names.count, maxRows) else { return nil }
        return names[index]
    }

    private func linePoints(_ join: BuilderJoin) -> (CGPoint, CGPoint) {
        let a = frame(for: join.leftTable), b = frame(for: join.rightTable)
        return (anchor(join.leftTable, join.leftColumn, toward: b.midX), anchor(join.rightTable, join.rightColumn, toward: a.midX))
    }

    private func badgeRect(_ join: BuilderJoin) -> NSRect {
        let (p, q) = linePoints(join)
        return NSRect(x: (p.x + q.x) / 2 - 22, y: (p.y + q.y) / 2 - 8, width: 44, height: 16)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let model else { return }
        if model.query.tables.isEmpty {
            let text = "Drag tables or views here from the list on the left" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
            let size = text.size(withAttributes: attributes)
            let visible = visibleRect
            text.draw(at: CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2), withAttributes: attributes)
            return
        }
        for table in model.query.tables { drawBox(table, model: model) }
        drawJoins(model)
        if case .link(let id, let name, let to) = drag {
            let from = anchor(id, name, toward: to.x)
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func drawJoins(_ model: QueryBuilderModel) {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        for join in model.query.joins {
            let (p, q) = linePoints(join)
            let path = NSBezierPath()
            path.move(to: p)
            let bend: CGFloat = 18
            let pOut = CGPoint(x: p.x + (p.x >= frame(for: join.leftTable).maxX - 0.5 ? bend : -bend), y: p.y)
            let qOut = CGPoint(x: q.x + (q.x >= frame(for: join.rightTable).maxX - 0.5 ? bend : -bend), y: q.y)
            path.line(to: pOut)
            path.line(to: qOut)
            path.line(to: q)
            path.lineWidth = 1.5
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
            for point in [p, q] {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            }
            let badge = NSRect(x: (pOut.x + qOut.x) / 2 - 22, y: (pOut.y + qOut.y) / 2 - 8, width: 44, height: 16)
            NSColor.controlBackgroundColor.setFill()
            let shape = NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8)
            shape.fill()
            NSColor.controlAccentColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            let title = (join.kind == .full ? "FULL" : String(join.kind.rawValue.prefix { $0 != " " })) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlAccentColor]
            let size = title.size(withAttributes: attributes)
            title.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawBox(_ table: BuilderTable, model: QueryBuilderModel) {
        let box = frame(for: table.id)
        let shape = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let header = NSRect(x: box.minX, y: box.minY, width: box.width, height: headerHeight)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        header.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        if let icon = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            icon.draw(in: NSRect(x: header.minX + 7, y: header.midY - 6, width: 14, height: 12))
        }
        var title = table.name
        if let alias = table.alias, !alias.isEmpty { title += " (\(alias))" }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        (title as NSString).draw(in: NSRect(x: header.minX + 26, y: header.minY + 4, width: header.width - 32, height: 16), withAttributes: titleAttributes)

        let names = rows(table.id)
        let font = NSFont.systemFont(ofSize: 11.5)
        let keys = Set(model.columns[table.id]?.filter(\.isPrimaryKey).map(\.name) ?? [])
        for (index, name) in names.prefix(maxRows).enumerated() {
            let row = rowRect(table.id, index)
            if index == maxRows - 1, names.count > maxRows {
                let more = "\(names.count - maxRows + 1) more columns… (use SELECT below)" as NSString
                more.draw(at: CGPoint(x: row.minX + 10, y: row.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor])
                continue
            }
            let checked = model.query.isSelected(table: table.id, column: name)
            let check = NSRect(x: row.minX + 8, y: row.midY - 6, width: 12, height: 12)
            let checkShape = NSBezierPath(roundedRect: check, xRadius: 3, yRadius: 3)
            if checked {
                NSColor.controlAccentColor.setFill()
                checkShape.fill()
                let mark = NSBezierPath()
                mark.move(to: CGPoint(x: check.minX + 2.5, y: check.midY))
                mark.line(to: CGPoint(x: check.minX + 5, y: check.maxY - 3))
                mark.line(to: CGPoint(x: check.maxX - 2.5, y: check.minY + 3))
                mark.lineWidth = 1.6
                NSColor.white.setStroke()
                mark.stroke()
            } else {
                NSColor.textBackgroundColor.setFill()
                checkShape.fill()
                NSColor.tertiaryLabelColor.setStroke()
                checkShape.lineWidth = 1
                checkShape.stroke()
            }
            let label = name == "*" ? "* (All Columns)" : name
            let attributes: [NSAttributedString.Key: Any] = [
                .font: keys.contains(name) ? NSFont.systemFont(ofSize: 11.5, weight: .semibold) : font,
                .foregroundColor: name == "*" ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            (label as NSString).draw(in: NSRect(x: row.minX + 26, y: row.minY + 2, width: row.width - 48, height: rowHeight - 2), withAttributes: attributes)
            if keys.contains(name), let keyIcon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [.systemOrange]))) {
                keyIcon.draw(in: NSRect(x: row.maxX - 20, y: row.midY - 5, width: 11, height: 10))
            }
        }
        if model.columns[table.id] == nil {
            ("Loading…" as NSString).draw(at: CGPoint(x: box.minX + 26, y: box.minY + headerHeight + rowHeight + 2),
                                           withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let join = model.query.joins.last(where: { joinBadge($0).contains(point) }) {
            showJoinMenu(join, at: point)
            return
        }
        guard let id = hitTable(point) else { return }
        let box = frame(for: id)
        if point.y < box.minY + headerHeight {
            if event.clickCount == 2 { return }
            drag = .move(id, offset: CGPoint(x: point.x - box.minX, y: point.y - box.minY))
            // Bring to front.
            if let index = model.query.tables.firstIndex(where: { $0.id == id }), index != model.query.tables.count - 1 {
                let table = model.query.tables.remove(at: index)
                model.query.tables.append(table)
            }
            return
        }
        guard let name = hitRow(id, point), !(name != "*" && rows(id).count > maxRows && rows(id).firstIndex(of: name) == maxRows - 1) else { return }
        if point.x < box.minX + 24 || name == "*" {
            model.query.setSelected(!model.query.isSelected(table: id, column: name), table: id, column: name)
        } else {
            drag = .link(id, name, to: point)
        }
    }

    private func joinBadge(_ join: BuilderJoin) -> NSRect {
        let (p, q) = linePoints(join)
        let bend: CGFloat = 18
        let pOut = CGPoint(x: p.x + (p.x >= frame(for: join.leftTable).maxX - 0.5 ? bend : -bend), y: p.y)
        let qOut = CGPoint(x: q.x + (q.x >= frame(for: join.rightTable).maxX - 0.5 ? bend : -bend), y: q.y)
        return NSRect(x: (pOut.x + qOut.x) / 2 - 24, y: (pOut.y + qOut.y) / 2 - 10, width: 48, height: 20)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let id, let offset):
            model.positions[id] = CGPoint(x: max(0, point.x - offset.x), y: max(0, point.y - offset.y))
        case .link(let id, let name, _):
            self.drag = .link(id, name, to: point)
            needsDisplay = true
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard let model, case .link(let id, let name, _) = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let target = hitTable(point), target != id, let column = hitRow(target, point), column != "*" else { return }
        model.query.addJoin(BuilderJoin(kind: .inner, leftTable: id, leftColumn: name, rightTable: target, rightColumn: column))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if let join = model.query.joins.last(where: { joinBadge($0).contains(point) }) { return joinMenu(join) }
        guard let id = hitTable(point) else { return nil }
        let menu = NSMenu()
        menu.addItem(QBMenuItem(title: "Select All Columns") { [weak model] in
            guard let model else { return }
            for name in model.columnNames(id) { model.query.setSelected(true, table: id, column: name) }
            model.query.setSelected(false, table: id, column: "*")
        })
        menu.addItem(QBMenuItem(title: "Deselect All Columns") { [weak model] in
            model?.query.columns.removeAll { $0.tableID == id && $0.aggregate == nil }
        })
        menu.addItem(.separator())
        menu.addItem(QBMenuItem(title: "Remove Table") { [weak model] in model?.remove(id) })
        return menu
    }

    private func joinMenu(_ join: BuilderJoin) -> NSMenu {
        let menu = NSMenu()
        guard let model else { return menu }
        let left = model.query.table(join.leftTable)?.reference ?? "", right = model.query.table(join.rightTable)?.reference ?? ""
        let header = NSMenuItem(title: "\(left).\(join.leftColumn) = \(right).\(join.rightColumn)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for kind in BuilderJoinKind.allCases {
            let item = QBMenuItem(title: kind.title) { [weak model] in
                guard let model, let index = model.query.joins.firstIndex(of: join) else { return }
                model.query.joins[index].kind = kind
            }
            item.state = join.kind == kind ? .on : .off
            if kind == .full, model.kind == .mysql || model.kind == .mariadb { item.isEnabled = false }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(QBMenuItem(title: "Delete Join") { [weak model] in model?.query.joins.removeAll { $0 == join } })
        return menu
    }

    private func showJoinMenu(_ join: BuilderJoin, at point: CGPoint) {
        joinMenu(join).popUp(positioning: nil, at: point, in: self)
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        tableName(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        tableName(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let name = tableName(sender), let model else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        model.add(named: name, at: CGPoint(x: max(0, point.x - 40), y: max(0, point.y - 10)))
        return true
    }

    private func tableName(_ sender: NSDraggingInfo) -> String? {
        guard let text = sender.draggingPasteboard.string(forType: .string), text.hasPrefix(Self.tableDragPrefix) else { return nil }
        return String(text.dropFirst(Self.tableDragPrefix.count))
    }
}

/// An NSMenuItem that runs a closure.
final class QBMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

#if DEBUG
/// UI scenarios: "table:NAME" (header), "column:NAME.COLUMN" (row), "check:NAME.COLUMN" (its checkbox), "badge:N" (join N).
extension QueryBuilderCanvasView: UIHarnessAnchors {
    func harnessAnchor(_ name: String) -> NSRect? {
        guard let model else { return nil }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        func table(_ reference: String) -> Int? {
            model.query.tables.first { $0.reference == reference || $0.name == reference }?.id
        }
        switch parts[0] {
        case "table":
            guard let id = table(parts[1]) else { return nil }
            let box = frame(for: id)
            return NSRect(x: box.minX, y: box.minY, width: box.width, height: headerHeight)
        case "column", "check":
            guard let dot = parts[1].firstIndex(of: "."), let id = table(String(parts[1][..<dot])) else { return nil }
            let column = String(parts[1][parts[1].index(after: dot)...])
            guard let index = rows(id).firstIndex(of: column), index < maxRows else { return nil }
            let row = rowRect(id, index)
            return parts[0] == "check" ? NSRect(x: row.minX + 2, y: row.minY, width: 18, height: row.height)
                : NSRect(x: row.minX + 40, y: row.minY, width: row.width - 60, height: row.height)
        case "badge":
            guard let index = Int(parts[1]), model.query.joins.indices.contains(index) else { return nil }
            return joinBadge(model.query.joins[index])
        default:
            return nil
        }
    }

    var harnessValue: String? {
        guard let model else { return nil }
        return model.query.tables.map { "\($0.reference)@\(Int(model.positions[$0.id]?.x ?? 0)),\(Int(model.positions[$0.id]?.y ?? 0))" }.joined(separator: " ")
    }
}
#endif
