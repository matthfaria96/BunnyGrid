import CoreGraphics
import Foundation

/// Card geometry, automatic layout and line routing for the ER diagram. Positions are each card's top-left
/// corner in diagram points; the canvas draws cards with exactly these sizes, so "no overlap" here holds on screen.
public enum ERLayout {
    public static let headerHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 19
    public static let bottomPadding: CGFloat = 6
    public static let minWidth: CGFloat = 170
    public static let maxWidth: CGFloat = 320
    public static let horizontalGap: CGFloat = 90
    public static let verticalGap: CGFloat = 36
    /// Margin around the diagram.
    public static let margin: CGFloat = 40

    /// Card size: the name header plus one row per column, wide enough for "name  type" at the canvas fonts.
    public static func size(of table: ERTable) -> CGSize {
        let header = CGFloat(table.name.count) * 7.6 + 44
        let widest = table.columns.map { CGFloat($0.name.count + $0.dataType.count) * 6.4 + 62 }.max() ?? 0
        let width = min(maxWidth, max(minWidth, header, widest)).rounded(.up)
        let rows = max(table.columns.count, 1)
        return CGSize(width: width, height: headerHeight + CGFloat(rows) * rowHeight + bottomPadding)
    }

    /// Vertical center of a column's row, relative to the card's top.
    public static func rowCenter(_ index: Int) -> CGFloat {
        headerHeight + (CGFloat(index) + 0.5) * rowHeight
    }

    public static func frames(_ model: ERModel, positions: [String: CGPoint]) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for table in model.tables {
            guard let origin = positions[table.id] else { continue }
            frames[table.id] = CGRect(origin: origin, size: size(of: table))
        }
        return frames
    }

    /// The smallest rectangle holding every frame (zero for none).
    public static func bounds(_ frames: some Collection<CGRect>) -> CGRect {
        guard let first = frames.first else { return .zero }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Auto layout

    /// Lays out every table: each group of related tables is placed in layers, parents (referenced tables) on the
    /// left and the tables that reference them to the right, ordered to keep linked tables level with each other.
    /// Groups are packed in rows by size; tables without relationships fill a grid at the end. Deterministic.
    public static func autoLayout(_ model: ERModel, origin: CGPoint = CGPoint(x: margin, y: margin)) -> [String: CGPoint] {
        let ids = model.tables.map(\.id).sorted()
        guard !ids.isEmpty else { return [:] }
        let sizes = Dictionary(model.tables.map { ($0.id, size(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let known = Set(ids)
        var parents: [String: Set<String>] = [:]
        var undirected: [String: Set<String>] = [:]
        for relation in model.relationships where !relation.isSelfReference && known.contains(relation.fromTable) && known.contains(relation.toTable) {
            parents[relation.fromTable, default: []].insert(relation.toTable)
            undirected[relation.fromTable, default: []].insert(relation.toTable)
            undirected[relation.toTable, default: []].insert(relation.fromTable)
        }

        // Connected components, largest first.
        var seen = Set<String>()
        var components: [[String]] = []
        for id in ids where !seen.contains(id) {
            var queue = [id], members: [String] = []
            seen.insert(id)
            while let next = queue.first {
                queue.removeFirst()
                members.append(next)
                for neighbor in (undirected[next] ?? []).sorted() where !seen.contains(neighbor) {
                    seen.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(members.sorted())
        }
        let linked = components.filter { $0.count > 1 }.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        let loners = components.filter { $0.count == 1 }.map { $0[0] }

        // Each block is laid out at (0, 0), then packed.
        var blocks: [(positions: [String: CGPoint], size: CGSize)] = linked.map { layered($0, parents: parents, undirected: undirected, sizes: sizes) }
        if !loners.isEmpty { blocks.append(grid(loners, sizes: sizes)) }

        let area = blocks.reduce(CGFloat(0)) { $0 + ($1.size.width + horizontalGap) * ($1.size.height + verticalGap) }
        let rowLimit = max(blocks.map(\.size.width).max() ?? 0, (area.squareRoot() * 1.5).rounded())
        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for block in blocks {
            if x > 0 && x + block.size.width > rowLimit {
                x = 0
                y += rowHeight + verticalGap * 2
                rowHeight = 0
            }
            for (id, point) in block.positions {
                result[id] = CGPoint(x: (origin.x + x + point.x).rounded(), y: (origin.y + y + point.y).rounded())
            }
            x += block.size.width + horizontalGap
            rowHeight = max(rowHeight, block.size.height)
        }
        return result
    }

    /// Keeps the saved position of every table still in the model and auto-lays out the new ones below them.
    public static func layout(_ model: ERModel, keeping saved: [String: CGPoint]) -> [String: CGPoint] {
        let known = Set(model.tables.map(\.id))
        let kept = saved.filter { known.contains($0.key) }
        guard !kept.isEmpty else { return autoLayout(model) }
        let missing = model.tables.filter { kept[$0.id] == nil }
        guard !missing.isEmpty else { return kept }
        let missingIDs = Set(missing.map(\.id))
        let sub = ERModel(sourceKind: model.sourceKind, tables: missing,
                          relationships: model.relationships.filter { missingIDs.contains($0.fromTable) && missingIDs.contains($0.toTable) })
        let existing = bounds(frames(model, positions: kept).values)
        let added = autoLayout(sub, origin: CGPoint(x: existing.minX, y: existing.maxY + verticalGap * 2))
        return kept.merging(added) { old, _ in old }
    }

    private static func layered(_ members: [String], parents: [String: Set<String>], undirected: [String: Set<String>],
                                sizes: [String: CGSize]) -> (positions: [String: CGPoint], size: CGSize) {
        let memberSet = Set(members)
        // Break cycles: a DFS over child → parent edges in name order drops the edges that close a cycle.
        var acyclic: [String: [String]] = [:]
        var state: [String: Int] = [:] // 1 visiting, 2 done
        func visit(_ id: String) {
            state[id] = 1
            for parent in (parents[id] ?? []).sorted() where memberSet.contains(parent) {
                switch state[parent] {
                case 1: continue
                case 2: acyclic[id, default: []].append(parent)
                default:
                    acyclic[id, default: []].append(parent)
                    visit(parent)
                }
            }
            state[id] = 2
        }
        for id in members where state[id] == nil { visit(id) }

        // Layer = longest path to a table that references nothing.
        var layerOf: [String: Int] = [:]
        func layer(_ id: String) -> Int {
            if let known = layerOf[id] { return known }
            let value = (acyclic[id] ?? []).map { layer($0) + 1 }.max() ?? 0
            layerOf[id] = value
            return value
        }
        for id in members { _ = layer(id) }
        let layerCount = (layerOf.values.max() ?? 0) + 1
        var layers: [[String]] = Array(repeating: [], count: layerCount)
        for id in members { layers[layerOf[id]!].append(id) }

        // Barycenter sweeps: order each layer by the mean position of its neighbors in the adjacent layer.
        func reorder(_ index: Int, against reference: Int) {
            let positions = Dictionary(layers[reference].enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { first, _ in first })
            let current = layers[index]
            let keyed = current.enumerated().map { offset, id -> (Double, Int, String) in
                let values = (undirected[id] ?? []).compactMap { positions[$0] }
                let center = values.isEmpty ? Double(offset) : values.reduce(0, +) / Double(values.count)
                return (center, offset, id)
            }
            layers[index] = keyed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
        if layerCount > 1 {
            for _ in 0..<4 {
                for index in 1..<layerCount { reorder(index, against: index - 1) }
                for index in stride(from: layerCount - 2, through: 0, by: -1) { reorder(index, against: index + 1) }
            }
        }

        // Columns left to right, each stacked and centered on the tallest.
        let heights = layers.map { column in
            column.reduce(CGFloat(0)) { $0 + sizes[$1]!.height } + CGFloat(max(column.count - 1, 0)) * verticalGap
        }
        let tallest = heights.max() ?? 0
        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for (index, column) in layers.enumerated() {
            var y = ((tallest - heights[index]) / 2).rounded()
            let width = column.map { sizes[$0]!.width }.max() ?? 0
            for id in column {
                positions[id] = CGPoint(x: x, y: y)
                y += sizes[id]!.height + verticalGap
            }
            x += width + horizontalGap
        }
        return (positions, CGSize(width: max(x - horizontalGap, 0), height: tallest))
    }

    private static func grid(_ ids: [String], sizes: [String: CGSize]) -> (positions: [String: CGPoint], size: CGSize) {
        let columns = max(1, Int(Double(ids.count).squareRoot().rounded(.up)))
        let columnWidth = ids.map { sizes[$0]!.width }.max() ?? 0
        var positions: [String: CGPoint] = [:]
        var y: CGFloat = 0
        var maxX: CGFloat = 0
        for start in stride(from: 0, to: ids.count, by: columns) {
            let row = ids[start..<min(start + columns, ids.count)]
            for (offset, id) in row.enumerated() {
                let x = CGFloat(offset) * (columnWidth + horizontalGap)
                positions[id] = CGPoint(x: x, y: y)
                maxX = max(maxX, x + sizes[id]!.width)
            }
            y += (row.map { sizes[$0]!.height }.max() ?? 0) + verticalGap
        }
        return (positions, CGSize(width: maxX, height: max(y - verticalGap, 0)))
    }

    // MARK: - Lines

    /// An orthogonal path for a relationship: from the child's key row to the parent's referenced row.
    /// The first point is on the child card's edge, the last on the parent's.
    public static func route(_ relation: ERRelationship, in model: ERModel, frames: [String: CGRect]) -> [CGPoint]? {
        guard let child = frames[relation.fromTable], let parent = frames[relation.toTable],
              let childTable = model.table(relation.fromTable), let parentTable = model.table(relation.toTable) else { return nil }
        return route(relation, child: childTable, at: child, parent: parentTable, at: parent)
    }

    /// The same route with the tables and their frames already looked up (the canvas keeps them indexed).
    public static func route(_ relation: ERRelationship, child childTable: ERTable, at child: CGRect,
                             parent parentTable: ERTable, at parent: CGRect) -> [CGPoint] {
        let childRow = relation.fromColumns.first.flatMap { name in childTable.columns.firstIndex { $0.name == name } } ?? 0
        let parentRow = relation.toColumns.first.flatMap { name in parentTable.columns.firstIndex { $0.name == name } } ?? 0
        let y1 = child.minY + rowCenter(childRow)
        let y2 = parent.minY + rowCenter(parentRow)
        let stub: CGFloat = 24

        if relation.isSelfReference {
            let x = child.maxX + stub
            let y2 = y1 == y2 ? y1 + rowHeight : y2
            return [CGPoint(x: child.maxX, y: y1), CGPoint(x: x, y: y1), CGPoint(x: x, y: y2), CGPoint(x: child.maxX, y: y2)]
        }
        if child.maxX + stub * 2 <= parent.minX {
            let mid = ((child.maxX + parent.minX) / 2).rounded()
            return [CGPoint(x: child.maxX, y: y1), CGPoint(x: mid, y: y1), CGPoint(x: mid, y: y2), CGPoint(x: parent.minX, y: y2)]
        }
        if parent.maxX + stub * 2 <= child.minX {
            let mid = ((parent.maxX + child.minX) / 2).rounded()
            return [CGPoint(x: child.minX, y: y1), CGPoint(x: mid, y: y1), CGPoint(x: mid, y: y2), CGPoint(x: parent.maxX, y: y2)]
        }
        // Stacked cards: loop around the right side.
        let x = max(child.maxX, parent.maxX) + stub
        return [CGPoint(x: child.maxX, y: y1), CGPoint(x: x, y: y1), CGPoint(x: x, y: y2), CGPoint(x: parent.maxX, y: y2)]
    }
}

/// Saved card positions per connection, database and schema (`model-layouts.json` in the data folder),
/// so a hand-made arrangement survives closing the model.
public struct ERLayoutStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func key(connectionID: UUID, database: String, schema: String?) -> String {
        "\(connectionID.uuidString)/\(database)/\(schema ?? "")"
    }

    private func loadAll() -> [String: [String: CGPoint]] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: [String: CGPoint]].self, from: data) else { return [:] }
        return all
    }

    public func positions(for key: String) -> [String: CGPoint]? {
        loadAll()[key]
    }

    public func save(_ positions: [String: CGPoint], for key: String) throws {
        var all = loadAll()
        all[key] = positions
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }

    public func remove(_ key: String) throws {
        var all = loadAll()
        guard all.removeValue(forKey: key) != nil else { return }
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}
