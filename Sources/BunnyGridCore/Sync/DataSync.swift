import Foundation

/// One row that differs between the source and target tables.
public struct RowDifference: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case insert, update, delete

        public var title: String {
            switch self {
            case .insert: "Insert"
            case .update: "Update"
            case .delete: "Delete"
            }
        }
    }

    public var id: Int
    public var kind: Kind
    /// The row's key values, as the target reads them (or the source, for inserts).
    public var key: [CellValue]
    /// The source row in `DataComparison.columns` order (nil for deletes).
    public var source: [CellValue]?
    /// The target row in `DataComparison.columns` order (nil for inserts).
    public var target: [CellValue]?
    /// Columns whose values differ (updates).
    public var changedColumns: [String]
}

/// Two tables with the same primary key, compared row by row (Navicat Data Synchronization).
public struct DataComparison: Sendable, Identifiable {
    public var sourceTable: String
    public var targetTable: String
    /// The columns both tables have, named as on the target.
    public var columns: [String]
    public var keyColumns: [String]
    /// Target columns, for typed parameters.
    public var targetColumns: [TableColumn]
    public var differences: [RowDifference]
    public var identicalRows: Int

    public var id: String { targetTable }

    public func count(_ kind: RowDifference.Kind) -> Int { differences.count { $0.kind == kind } }

    /// The grid-style changes for the chosen differences (all when nil): deletes, then updates, then inserts.
    public func changes(for selection: Set<Int>? = nil) -> [RowChange] {
        let chosen = differences.filter { selection?.contains($0.id) ?? true }
        let keyIndexes = keyColumns.compactMap { columns.firstIndex(of: $0) }
        func key(_ row: [CellValue]) -> [ColumnValue] { keyIndexes.map { ColumnValue(columns[$0], row[$0]) } }
        var deletes: [RowChange] = [], updates: [RowChange] = [], inserts: [RowChange] = []
        for item in chosen {
            switch item.kind {
            case .delete:
                if let target = item.target { deletes.append(.delete(key: key(target))) }
            case .update:
                guard let source = item.source, let target = item.target else { continue }
                let values = item.changedColumns.compactMap { name in columns.firstIndex(of: name).map { ColumnValue(name, source[$0]) } }
                updates.append(.update(key: key(target), values: values))
            case .insert:
                if let source = item.source { inserts.append(.insert(values: zip(columns, source).map { ColumnValue($0, $1) })) }
            }
        }
        return deletes + updates + inserts
    }

    /// The changes as a SQL script for `kind`, values as literals.
    public func script(for selection: Set<Int>? = nil, kind: DatabaseKind, schema: String?) -> String {
        let d = SQLDialect(kind: kind)
        return changes(for: selection).map { d.sql(for: $0, table: targetTable, schema: schema, columns: targetColumns) + ";" }.joined(separator: "\n")
    }
}

public enum DataSync {
    /// Reads both tables and compares them by the target's primary key. Values are compared by meaning
    /// (1 and true, 12.5 and "12.50", "2026-10-17T09:30:00" and "2026-10-17 09:30:00"), so tables on different engines compare.
    public static func compare(source: any DatabaseDriver, sourceSchema: String?, sourceTable: String,
                               target: any DatabaseDriver, targetSchema: String?, targetTable: String) async throws -> DataComparison {
        let targetColumns = try await target.listColumns(table: targetTable, schema: targetSchema)
        let sourceColumns = try await source.listColumns(table: sourceTable, schema: sourceSchema)
        let targetKey = try await SchemaSnapshot.readTable(targetTable, from: target, schema: targetSchema).primaryKey
        guard !targetKey.isEmpty else {
            throw DatabaseError.unsupported("Data synchronization of “\(targetTable)”, which has no primary key,")
        }
        let sourceNames = Set(sourceColumns.map { $0.name.lowercased() })
        let common = targetColumns.sorted { $0.ordinal < $1.ordinal }.filter { sourceNames.contains($0.name.lowercased()) }
        if let missing = targetKey.first(where: { !sourceNames.contains($0.lowercased()) }) {
            throw DatabaseError.queryFailed("The source table “\(sourceTable)” has no column “\(missing)” of the target's primary key.")
        }
        let columns = common.map(\.name)
        let categories = common.map { ColumnTypeCategory.classify($0.dataType, kind: target.config.kind) }
        let keyIndexes = targetKey.compactMap { key in columns.firstIndex { $0.lowercased() == key.lowercased() } }

        let sourcePage = try await source.fetchAllRows(table: sourceTable, schema: sourceSchema)
        let targetPage = try await target.fetchAllRows(table: targetTable, schema: targetSchema)
        let sourceRows = project(sourcePage, onto: columns)
        let targetRows = project(targetPage, onto: columns)

        func normalized(_ row: [CellValue]) -> [CellValue] { zip(row, categories).map { comparable($0, $1) } }
        func key(_ row: [CellValue]) -> [CellValue] { keyIndexes.map { row[$0] } }

        var targetByKey: [[CellValue]: (raw: [CellValue], normalized: [CellValue])] = [:]
        var targetOrder: [[CellValue]] = []
        for row in targetRows {
            let values = normalized(row)
            let k = key(values)
            if targetByKey[k] == nil { targetOrder.append(k) }
            targetByKey[k] = (row, values)
        }
        var differences: [RowDifference] = []
        var matched = Set<[CellValue]>()
        var identical = 0
        for row in sourceRows {
            let values = normalized(row)
            let k = key(values)
            guard let existing = targetByKey[k] else {
                differences.append(RowDifference(id: differences.count, kind: .insert, key: key(row), source: row, target: nil, changedColumns: []))
                continue
            }
            matched.insert(k)
            let changed = columns.indices.filter { values[$0] != existing.normalized[$0] }.map { columns[$0] }
            if changed.isEmpty {
                identical += 1
            } else {
                differences.append(RowDifference(id: differences.count, kind: .update, key: key(existing.raw), source: row,
                                                 target: existing.raw, changedColumns: changed))
            }
        }
        for k in targetOrder where !matched.contains(k) {
            guard let existing = targetByKey[k] else { continue }
            differences.append(RowDifference(id: differences.count, kind: .delete, key: key(existing.raw), source: nil,
                                             target: existing.raw, changedColumns: []))
        }
        return DataComparison(sourceTable: sourceTable, targetTable: targetTable, columns: columns,
                              keyColumns: keyIndexes.map { columns[$0] }, targetColumns: targetColumns,
                              differences: differences, identicalRows: identical)
    }

    /// The page's rows with only `columns`, in that order (matched by name, ignoring case).
    private static func project(_ page: TablePage, onto columns: [String]) -> [[CellValue]] {
        let positions = columns.map { name in page.columns.firstIndex(of: name) ?? page.columns.firstIndex { $0.lowercased() == name.lowercased() } }
        return page.rows.map { row in positions.map { $0.map { $0 < row.count ? row[$0] : .null } ?? .null } }
    }

    /// Applies the chosen differences of each comparison to the target in one transaction: deletes and updates one
    /// statement per row, inserts `batchSize` rows per statement, all values as typed parameters. Rolls everything
    /// back on the first failure. Returns the rows changed.
    @discardableResult
    public static func apply(_ comparisons: [(comparison: DataComparison, selection: Set<Int>?)], to target: any DatabaseDriver,
                             schema: String?, batchSize: Int = 500,
                             onEvent: @escaping @Sendable (TransferEvent) async -> Void = { _ in }) async throws -> Int {
        if target.config.readOnly { throw DatabaseError.readOnly }
        let d = target.dialect
        var changed = 0
        _ = try await target.executeStatement(d.beginTransaction)
        do {
            for (index, entry) in comparisons.enumerated() {
                let comparison = entry.comparison
                let changes = comparison.changes(for: entry.selection)
                await onEvent(.tableStarted(comparison.targetTable, index: index, count: comparisons.count))
                var done = 0
                var inserts: [[ColumnValue]] = []
                let byName = Dictionary(comparison.targetColumns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                func flush() async throws {
                    guard let first = inserts.first else { return }
                    let names = first.map(\.column)
                    let parameters = inserts.flatMap { row in
                        row.map { SQLParameter($0.value, category: ColumnTypeCategory.classify(byName[$0.column]?.dataType, kind: d.kind)) }
                    }
                    let sql = d.multiRowInsert(into: comparison.targetTable, schema: schema, columns: names, rowCount: inserts.count)
                    _ = try await target.executeStatement(sql, parameters: parameters)
                    done += inserts.count
                    inserts = []
                    await onEvent(.rowsCopied(comparison.targetTable, copied: done, total: changes.count))
                }
                let perStatement = max(1, min(batchSize, d.maxParameters / max(1, comparison.columns.count)))
                for change in changes {
                    try Task.checkCancellation()
                    if case .insert(let values) = change {
                        inserts.append(values)
                        if inserts.count >= perStatement { try await flush() }
                        continue
                    }
                    let bound = d.boundStatement(for: change, table: comparison.targetTable, schema: schema, columns: comparison.targetColumns)
                    let result = try await target.executeStatement(bound.sql, parameters: bound.parameters)
                    if let affected = result.affectedRows, affected == 0 {
                        await onEvent(.log("\(comparison.targetTable): a row changed on the target meanwhile and was skipped."))
                    }
                    done += 1
                    if done % 200 == 0 { await onEvent(.rowsCopied(comparison.targetTable, copied: done, total: changes.count)) }
                }
                try await flush()
                await onEvent(.rowsCopied(comparison.targetTable, copied: done, total: changes.count))
                changed += done
            }
            _ = try await target.executeStatement("COMMIT")
        } catch {
            _ = try? await target.executeStatement("ROLLBACK")
            throw error
        }
        return changed
    }

    /// A value in a form that compares equal across engines for a column of `category`.
    public static func comparable(_ value: CellValue, _ category: ColumnTypeCategory) -> CellValue {
        switch value {
        case .null: return .null
        case .blob(let data): return .blob(data)
        default: break
        }
        switch category {
        case .boolean:
            switch value {
            case .bool(let v): return .bool(v)
            case .integer(let v): return .bool(v != 0)
            case .double(let v): return .bool(v != 0)
            case .text(let t):
                switch t.trimmingCharacters(in: .whitespaces).lowercased() {
                case "1", "t", "true", "y", "yes", "on": return .bool(true)
                case "0", "f", "false", "n", "no", "off": return .bool(false)
                default: return .text(t)
                }
            default: return value
            }
        case .integer:
            switch value {
            case .bool(let v): return .integer(v ? 1 : 0)
            case .double(let v) where v.rounded() == v && abs(v) < 9e18: return .integer(Int64(v))
            case .text(let t): return Int64(t.trimmingCharacters(in: .whitespaces)).map(CellValue.integer) ?? .text(t)
            default: return value
            }
        case .real, .decimal:
            let text: String = switch value {
            case .integer(let v): String(v)
            case .double(let v): String(v)
            case .text(let t): t.trimmingCharacters(in: .whitespaces)
            case .bool(let v): v ? "1" : "0"
            default: value.displayString
            }
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).map { .text("\($0)") } ?? .text(text)
        case .date, .time, .timeWithTimeZone, .dateTime, .dateTimeWithTimeZone:
            var text = value.displayString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
            text = text.replacing(/\.0+(?=$|[+\-Z])/, with: "")
            if text.hasSuffix("Z") { text = String(text.dropLast()) + "+00:00" }
            return .text(text)
        case .uuid:
            return .text(value.displayString.lowercased())
        case .binary:
            if case .text(let t) = value { return .blob(Data(t.utf8)) }
            return value
        case .text, .json, .other:
            switch value {
            case .text: return value
            default: return .text(value.displayString)
            }
        }
    }
}
