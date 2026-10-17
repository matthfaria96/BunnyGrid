#if DEBUG
import AppKit
import BunnyGridCore

/// UI scenario anchors on any table / outline view (the result grid, the Objects list, the navigator):
/// "cell:ROW,COLUMN", "row:ROW", "header:NAME" (a column header, by title or identifier), "headerEdge:NAME"
/// (its right edge, to resize), "rowTitled:TEXT" (the first row whose cell shows TEXT).
extension NSTableView: UIHarnessAnchors {
    func harnessAnchor(_ name: String) -> NSRect? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "cell":
            let numbers = parts[1].split(separator: ",").compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] < numberOfRows, numbers[1] < numberOfColumns else { return nil }
            scrollRowToVisible(numbers[0])
            return frameOfCell(atColumn: numbers[1], row: numbers[0])
        case "row":
            guard let row = Int(parts[1]), row < numberOfRows else { return nil }
            scrollRowToVisible(row)
            return rect(ofRow: row)
        case "header", "headerEdge":
            guard let headerView, let index = tableColumns.firstIndex(where: { $0.title == parts[1] || $0.identifier.rawValue == parts[1] || $0.headerCell.stringValue == parts[1] })
            else { return nil }
            var rect = convert(headerView.headerRect(ofColumn: index), from: headerView)
            if parts[0] == "headerEdge" { rect = NSRect(x: rect.maxX - 2, y: rect.minY, width: 3, height: rect.height) }
            return rect
        case "rowTitled":
            for row in 0..<numberOfRows {
                for column in 0..<max(numberOfColumns, 1) {
                    guard let cell = view(atColumn: column, row: row, makeIfNecessary: true) else { continue }
                    var texts: [String] = []
                    func collect(_ view: NSView) {
                        if let field = view as? NSTextField { texts.append(field.stringValue) }
                        for subview in view.subviews { collect(subview) }
                    }
                    collect(cell)
                    if texts.contains(parts[1]) {
                        scrollRowToVisible(row)
                        return rect(ofRow: row)
                    }
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Column order and widths, then the first visible row: "id:80 name:120 … | top:0".
    var harnessValue: String? {
        tableColumns.map { "\($0.title.isEmpty ? $0.identifier.rawValue : $0.title):\(Int($0.width))" }.joined(separator: " ")
            + " | top:\(rows(in: visibleRect).location)"
    }
}

extension TableTabModel: UIHarnessProbing {
    func harnessProbe(_ key: String) -> Any? {
        switch key {
        case "changeCount": return changeCount
        case "rowCount": return displayRows.count
        case "lastRow": return displayRows.count - 1
        case "hasChanges": return hasChanges
        default:
            // "value:ROW,COLUMN" → the displayed value.
            if key.hasPrefix("value:") {
                let numbers = key.dropFirst(6).split(separator: ",").compactMap { Int($0) }
                guard numbers.count == 2, displayRows.indices.contains(numbers[0]), displayRows[numbers[0]].indices.contains(numbers[1]) else { return "nil" }
                return "\(displayRows[numbers[0]][numbers[1]])"
            }
            return nil
        }
    }
}
#endif
