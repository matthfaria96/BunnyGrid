import Foundation

/// Documents as grid rows: columns are the union of top-level keys (`_id` first, then in order of first
/// appearance), nested documents and arrays become compact shell text, and each column's type is the BSON type
/// most of its values have (shown in the grid's second header line).
public struct FlattenedDocuments: Sendable {
    public var columns: [String]
    public var columnTypes: [String: String]
    public var rows: [[CellValue]]

    public var result: QueryResult { QueryResult(statement: "", columns: columns, rows: rows) }
}

public enum DocumentFlattener {
    public static func flatten(_ documents: [BSONDocument]) -> FlattenedDocuments {
        var columns: [String] = []
        var seen = Set<String>()
        if documents.contains(where: { $0["_id"] != nil }) {
            columns.append("_id")
            seen.insert("_id")
        }
        for document in documents {
            for key in document.keys where !seen.contains(key) {
                seen.insert(key)
                columns.append(key)
            }
        }
        var typeCounts: [String: [String: Int]] = [:]
        let rows = documents.map { document -> [CellValue] in
            columns.map { column in
                guard let value = document[column] else { return .null }
                if value != .null { typeCounts[column, default: [:]][value.typeName, default: 0] += 1 }
                return cell(value)
            }
        }
        var types: [String: String] = [:]
        for (column, counts) in typeCounts {
            types[column] = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }
        return FlattenedDocuments(columns: columns, columnTypes: types, rows: rows)
    }

    /// One value as a grid cell.
    public static func cell(_ value: BSON) -> CellValue {
        switch value {
        case .null, .undefined: .null
        case .int32(let v): .integer(Int64(v))
        case .int64(let v): .integer(v)
        case .double(let v): .double(v)
        case .bool(let b): .bool(b)
        case .string(let s): .text(s)
        case .binary(let b) where b.uuid == nil: .blob(b.data)
        default: .text(BSONFormat.display(value))
        }
    }

    /// Turns text typed into a cell back into BSON, keeping the field's previous type where the text fits it
    /// (an Int32 stays Int32, an ObjectId stays an ObjectId). Documents, arrays and shell syntax are parsed.
    public static func value(fromText text: String, original: BSON?) -> BSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch original {
        case .int32?: if let v = Int32(trimmed) { return .int32(v) }
        case .int64?: if let v = Int64(trimmed) { return .int64(v) }
        case .double?: if let v = Double(trimmed) { return .double(v) }
        case .decimal128?: if let v = BSONDecimal128(trimmed) { return .decimal128(v) }
        case .bool?:
            if trimmed.lowercased() == "true" { return .bool(true) }
            if trimmed.lowercased() == "false" { return .bool(false) }
        case .objectId?: if let id = ObjectId(trimmed) { return .objectId(id) }
        case .date?: if let ms = BSONFormat.parseISODate(trimmed) { return .date(ms) }
        case .string?: return .string(text)
        default: break
        }
        if let first = trimmed.first, "{[/".contains(first) || trimmed.hasSuffix(")"), let parsed = try? MongoShellParser.parseValue(trimmed) {
            return parsed
        }
        if original == nil || original == .null {
            if let v = Int64(trimmed) { return MongoShellParserIntegers.integer(v) }
            if let v = Double(trimmed), trimmed.contains(".") { return .double(v) }
            if trimmed == "true" { return .bool(true) }
            if trimmed == "false" { return .bool(false) }
        }
        return .string(text)
    }

    /// A grid cell edit as BSON, from the edited cell and the document's previous value.
    public static func value(from cell: CellValue, original: BSON?) -> BSON {
        switch cell {
        case .null: .null
        case .integer(let v): original.map { if case .int64 = $0 { BSON.int64(v) } else { MongoShellParserIntegers.integer(v) } } ?? MongoShellParserIntegers.integer(v)
        case .double(let v): .double(v)
        case .bool(let b): .bool(b)
        case .blob(let d): .binary(BSONBinary(subtype: 0, data: d))
        case .text(let s): value(fromText: s, original: original)
        }
    }
}

enum MongoShellParserIntegers {
    static func integer(_ value: Int64) -> BSON {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(value)
    }
}

/// `explain` output as a plan tree: `queryPlanner.winningPlan` with its `inputStage(s)`, plus the execution
/// counts when the explain ran with `executionStats`.
public enum MongoExplain {
    public static func plan(_ explain: BSONDocument) -> [QueryPlanNode] {
        var counter = 0
        var roots: [QueryPlanNode] = []
        if let planner = explain["queryPlanner"]?.documentValue ?? firstStage(explain)?["queryPlanner"]?.documentValue,
           let winning = planner["winningPlan"]?.documentValue {
            // 7.0+ with the slot-based engine nests the stages under queryPlan.
            let stage = winning["queryPlan"]?.documentValue ?? winning
            var root = node(stage, counter: &counter)
            if let ns = planner["namespace"]?.stringValue { root.details.insert(.init("namespace", ns), at: 0) }
            if let stats = explain["executionStats"]?.documentValue {
                for key in ["nReturned", "executionTimeMillis", "totalKeysExamined", "totalDocsExamined"] {
                    if let v = stats[key] { root.details.append(.init(key, BSONFormat.display(v))) }
                }
            }
            roots.append(root)
        } else if case .array(let stages)? = explain["stages"] {
            // Aggregations with stages beyond the cursor: one node per stage.
            for case .document(let stage) in stages {
                guard let first = stage.elements.first else { continue }
                counter += 1
                if first.key == "$cursor", let inner = first.value.documentValue {
                    roots.append(contentsOf: plan(inner))
                } else {
                    roots.append(QueryPlanNode(id: counter, title: first.key, details: [.init("spec", BSONFormat.scalarShell(first.value))]))
                }
            }
        }
        return roots
    }

    private static func firstStage(_ explain: BSONDocument) -> BSONDocument? {
        guard case .array(let stages)? = explain["stages"], case .document(let first)? = stages.first else { return nil }
        return first["$cursor"]?.documentValue
    }

    private static func node(_ stage: BSONDocument, counter: inout Int) -> QueryPlanNode {
        counter += 1
        let id = counter
        var details: [QueryPlanNode.Detail] = []
        var children: [QueryPlanNode] = []
        for element in stage.elements {
            switch element.key {
            case "stage": continue
            case "inputStage":
                if let inner = element.value.documentValue { children.append(node(inner, counter: &counter)) }
            case "inputStages":
                for case .document(let inner) in element.value.arrayValue ?? [] { children.append(node(inner, counter: &counter)) }
            default:
                details.append(.init(element.key, BSONFormat.display(element.value)))
            }
        }
        return QueryPlanNode(id: id, title: stage["stage"]?.stringValue ?? "STAGE", details: details, children: children)
    }
}
