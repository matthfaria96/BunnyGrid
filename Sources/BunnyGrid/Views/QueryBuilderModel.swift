import AppKit
import BunnyGridCore
import SwiftUI

/// State of one Query Builder sheet opened from a query tab: the SELECT being built, where each table box
/// sits on the canvas, and the columns / foreign keys read for the tables on it.
@MainActor
@Observable
final class QueryBuilderModel {
    var query = BuilderQuery()
    var positions: [Int: CGPoint] = [:]
    private(set) var columns: [Int: [BunnyGridCore.TableColumn]] = [:]
    private(set) var keys: [Int: [TableForeignKey]] = [:]
    /// Set when the statement under the cursor couldn't be read into the builder.
    var parseError: String?
    var objects: [DatabaseObject] = []
    var objectFilter = ""
    let kind: DatabaseKind
    @ObservationIgnored private weak var context: DatabaseContext?
    /// The editor range OK replaces: the selection or the statement the builder was opened on.
    @ObservationIgnored let target: NSRange?

    init(query tab: QueryTabModel) {
        context = tab.context
        kind = tab.context?.kind ?? .sqlite
        var source = ""
        var range: NSRange?
        if tab.hasSelection {
            source = tab.selectedText
            range = tab.textView?.selectedRange()
        } else if let statement = tab.currentStatement, !statement.sql.isEmpty {
            source = statement.sql
            range = NSRange(location: statement.range.lowerBound, length: statement.range.count)
        }
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                query = try QueryBuilderParser.parse(source)
            } catch {
                parseError = error.localizedDescription
                range = nil
            }
        }
        target = range
        if let context {
            objects = (context.objects(in: context.defaultSchema) ?? []).filter { $0.kind == .table || $0.kind == .view }
        }
        for (index, table) in query.tables.enumerated() {
            positions[table.id] = CGPoint(x: 30 + CGFloat(index % 4) * 230, y: 24 + CGFloat(index / 4) * 250)
            load(table)
        }
    }

    var sql: String { QueryBuilderSQL(kind: kind).sql(query) }

    var filteredObjects: [DatabaseObject] {
        let filter = objectFilter.trimmingCharacters(in: .whitespaces)
        return filter.isEmpty ? objects : objects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Adds `object` at `point` (canvas coordinates), joined to the others along foreign keys once they load.
    func add(_ object: DatabaseObject, at point: CGPoint? = nil) {
        let schema = object.schema == context?.defaultSchema || !(kind == .postgresql || kind == .sqlserver) ? nil : object.schema
        let id = query.addTable(name: object.name, schema: schema)
        let count = query.tables.count - 1
        positions[id] = point ?? CGPoint(x: 30 + CGFloat(count % 4) * 230, y: 24 + CGFloat(count / 4) * 250)
        if query.tables.count == 1, query.columns.isEmpty {
            query.columns = [BuilderColumn(tableID: id, column: "*")]
        }
        load(query.tables.last!, joinForeignKeys: true)
    }

    func add(named name: String, at point: CGPoint) {
        guard let object = objects.first(where: { $0.name == name }) else { return }
        add(object, at: point)
    }

    func remove(_ id: Int) {
        query.removeTable(id)
        positions[id] = nil
        columns[id] = nil
        keys[id] = nil
    }

    func columnNames(_ id: Int) -> [String] {
        columns[id]?.map(\.name) ?? []
    }

    /// Every `table.column` the clause menus offer.
    var allColumns: [(table: BuilderTable, column: String)] {
        query.tables.flatMap { table in columnNames(table.id).map { (table, $0) } }
    }

    func label(_ operand: BuilderOperand) -> String {
        switch operand {
        case .column(let id, let name):
            guard let table = query.table(id), query.tables.count > 1 else { return name }
            return "\(table.reference).\(name)"
        case .aggregate(let function, let id, let column):
            let inner = label(.column(tableID: id, name: column))
            return function == .countDistinct ? "COUNT(DISTINCT \(inner))" : "\(function.rawValue)(\(inner))"
        case .text(let text): return text
        case .number(let text), .parameter(let text): return text
        case .null: return "NULL"
        }
    }

    private func load(_ table: BuilderTable, joinForeignKeys: Bool = false) {
        guard let context else { return }
        let driver = context.driver
        let schema = context.driverSchema(table.schema ?? context.defaultSchema)
        let id = table.id
        let name = table.name
        Task {
            let loadedColumns = (try? await driver.listColumns(table: name, schema: schema)) ?? []
            let loadedKeys = (try? await driver.listForeignKeys(table: name, schema: schema)) ?? []
            guard query.table(id) != nil else { return }
            columns[id] = loadedColumns
            keys[id] = loadedKeys
            if joinForeignKeys { query.addForeignKeyJoins(for: id, keys: keys) }
        }
    }
}

extension QueryTabModel {
    /// Writes the builder's SQL back: over the range it was opened on, otherwise at the cursor
    /// (replacing everything when the editor is blank). Goes through the text view so ⌘Z undoes it.
    func applyQueryBuilder(_ sql: String, range: NSRange?) {
        guard let textView, let range, NSMaxRange(range) <= (textView.string as NSString).length else {
            insert(sql, mode: isBlank ? .replaceAll : .atCursor)
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: sql) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: sql)
        textView.didChangeText()
        let inserted = NSRange(location: range.location, length: (sql as NSString).length)
        textView.setSelectedRange(inserted)
        textView.scrollRangeToVisible(inserted)
        textView.window?.makeFirstResponder(textView)
    }
}

// MARK: - Condition paths

extension BuilderGroup {
    /// The group at `path` (indexes of nested groups from this one).
    subscript(group path: [Int]) -> BuilderGroup {
        get {
            guard let first = path.first, items.indices.contains(first), case .group(let child) = items[first] else { return self }
            return child[group: Array(path.dropFirst())]
        }
        set {
            guard let first = path.first else { self = newValue; return }
            guard items.indices.contains(first), case .group(var child) = items[first] else { return }
            child[group: Array(path.dropFirst())] = newValue
            items[first] = .group(child)
        }
    }
}
