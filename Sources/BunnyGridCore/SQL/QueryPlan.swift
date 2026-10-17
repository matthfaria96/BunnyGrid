import Foundation

/// One step of a query plan (a scan, a join, a sort…), with its children.
public struct QueryPlanNode: Identifiable, Sendable, Equatable {
    public struct Detail: Sendable, Equatable {
        public let key: String
        public let value: String

        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    public let id: Int
    public var title: String
    public var details: [Detail]
    public var children: [QueryPlanNode]

    public init(id: Int, title: String, details: [Detail] = [], children: [QueryPlanNode] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.children = children
    }

    /// The node and its descendants depth-first, with their depth (0 for `self`), for an always-expanded tree.
    public func flattened(depth: Int = 0) -> [(depth: Int, node: QueryPlanNode)] {
        [(depth, self)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

/// Turns the result of `SQLDialect.explain` into a tree: SQLite's EXPLAIN QUERY PLAN rows,
/// PostgreSQL's `EXPLAIN (FORMAT JSON)` and MySQL/MariaDB's `EXPLAIN FORMAT=JSON` documents.
public enum QueryPlan {
    /// The plan's root nodes, or nil when `result` isn't a plan in a shape this knows.
    public static func parse(_ result: QueryResult, kind: DatabaseKind) -> [QueryPlanNode]? {
        switch kind {
        case .sqlite:
            let names = result.columns.map { $0.lowercased() }
            guard names.count == 4, names[0] == "id", names[1] == "parent", names[3] == "detail" else { return nil }
            return sqlite(result.rows)
        case .postgresql, .mysql, .mariadb:
            guard result.columns.count == 1, result.rows.count == 1, let cell = result.rows.first?.first, !cell.isNull else { return nil }
            return kind == .postgresql ? postgresJSON(cell.displayString) : mysqlJSON(cell.displayString)
        case .sqlserver:
            guard result.columns.count == 1, let cell = result.rows.first?.first, !cell.isNull else { return nil }
            return sqlServerXML(cell.displayString)
        case .redis: return nil
        case .mongodb:
            guard result.columns == ["explain"], let text = result.rows.first?.first?.displayString,
                  let document = try? MongoShellParser.parseDocument(text) else { return nil }
            return MongoExplain.plan(document)
        }
    }

    // MARK: - SQL Server

    /// SET SHOWPLAN_XML documents: each `StmtSimple` becomes a root, its nested `RelOp`s the tree.
    public static func sqlServerXML(_ text: String) -> [QueryPlanNode]? {
        // Several documents (one per statement) are wrapped so they parse as one.
        let wrapped = "<Plans>" + text.replacingOccurrences(of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression) + "</Plans>"
        let delegate = ShowplanParser()
        let parser = XMLParser(data: Data(wrapped.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.roots.isEmpty ? nil : delegate.roots
    }

    private final class ShowplanParser: NSObject, XMLParserDelegate {
        var roots: [QueryPlanNode] = []
        /// Open statements and operators, innermost last.
        private var stack: [QueryPlanNode] = []
        private var counter = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "StmtSimple", "StmtCond", "StmtCursor":
                counter += 1
                var details: [QueryPlanNode.Detail] = []
                if let cost = attributes["StatementSubTreeCost"] { details.append(.init("cost", cost)) }
                if let rows = attributes["StatementEstRows"] { details.append(.init("rows", rows)) }
                if let level = attributes["StatementOptmLevel"] { details.append(.init("optimization", level)) }
                let statement = (attributes["StatementText"] ?? "Statement").trimmingCharacters(in: .whitespacesAndNewlines)
                stack.append(QueryPlanNode(id: counter, title: statement.count > 120 ? String(statement.prefix(120)) + "…" : statement, details: details))
            case "RelOp":
                counter += 1
                let physical = attributes["PhysicalOp"] ?? "Operator"
                let logical = attributes["LogicalOp"] ?? physical
                var details: [QueryPlanNode.Detail] = []
                if let cost = attributes["EstimatedTotalSubtreeCost"] { details.append(.init("cost", cost)) }
                if let rows = attributes["EstimateRows"] { details.append(.init("rows", rows)) }
                if let io = attributes["EstimateIO"] { details.append(.init("io", io)) }
                if let cpu = attributes["EstimateCPU"] { details.append(.init("cpu", cpu)) }
                if let width = attributes["AvgRowSize"] { details.append(.init("width", width)) }
                if let parallel = attributes["Parallel"], parallel == "1" || parallel == "true" { details.append(.init("parallel", "true")) }
                stack.append(QueryPlanNode(id: counter, title: logical == physical ? physical : "\(physical) (\(logical))", details: details))
            case "Object":
                // The table or index the innermost operator reads (only the first one names it).
                guard var node = stack.last, !node.title.contains(" on ") else { return }
                if let table = attributes["Table"] {
                    let schema = attributes["Schema"].map { $0 + "." } ?? ""
                    node.title += " on \(schema)\(table)"
                    if let alias = attributes["Alias"] { node.title += " \(alias)" }
                    if let index = attributes["Index"] { node.title += " using \(index)" }
                    stack[stack.count - 1] = node
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard ["StmtSimple", "StmtCond", "StmtCursor", "RelOp"].contains(name), let node = stack.popLast() else { return }
            if stack.isEmpty { roots.append(node) } else { stack[stack.count - 1].children.append(node) }
        }
    }

    /// EXPLAIN QUERY PLAN rows: `id, parent, notused, detail`, where `parent` is another row's id (0 at the top).
    public static func sqlite(_ rows: [[CellValue]]) -> [QueryPlanNode] {
        struct Row { let id: Int; let parent: Int; let detail: String }
        let parsed: [Row] = rows.compactMap { row in
            guard row.count >= 4, let id = Int(row[0].displayString), let parent = Int(row[1].displayString) else { return nil }
            return Row(id: id, parent: parent, detail: row[3].displayString)
        }
        let ids = Set(parsed.map(\.id))
        func children(of parent: Int) -> [QueryPlanNode] {
            parsed.filter { $0.parent == parent && $0.id != parent }.map { row in
                QueryPlanNode(id: row.id, title: row.detail, children: children(of: row.id))
            }
        }
        // Rows whose parent is missing are roots too.
        let roots = parsed.filter { $0.parent == 0 || !ids.contains($0.parent) }
        return roots.map { QueryPlanNode(id: $0.id, title: $0.detail, children: children(of: $0.id)) }
    }

    // MARK: - PostgreSQL

    /// `[{"Plan": {"Node Type": …, "Plans": [...]}, …}]`.
    public static func postgresJSON(_ text: String) -> [QueryPlanNode]? {
        guard let json = decode(text) else { return nil }
        let documents: [JSONValue] = if case .array(let items) = json { items } else { [json] }
        var counter = 0
        let nodes = documents.compactMap { document -> QueryPlanNode? in
            guard case .object(let object) = document, case .object(let plan)? = object["Plan"] else { return nil }
            var root = postgresNode(plan, counter: &counter)
            // Totals printed beside the plan (EXPLAIN ANALYZE, SETTINGS…) go on the root.
            for key in object.keys.sorted() where key != "Plan" {
                if let value = scalarText(object[key]!) { root.details.append(.init(key, value)) }
            }
            return root
        }
        return nodes.isEmpty ? nil : nodes
    }

    private static let postgresTitleKeys: Set<String> = [
        "Node Type", "Relation Name", "Alias", "Schema", "Index Name", "Startup Cost", "Total Cost", "Plan Rows", "Plan Width",
        "Plans", "Parallel Aware", "Async Capable", "Join Type", "Strategy", "Partial Mode", "CTE Name", "Function Name",
    ]

    private static func postgresNode(_ plan: [String: JSONValue], counter: inout Int) -> QueryPlanNode {
        counter += 1
        let id = counter
        var title = plan["Node Type"].flatMap(scalarText) ?? "Plan"
        if let join = plan["Join Type"].flatMap(scalarText), join != "Inner" { title += " (\(join))" }
        if let strategy = plan["Strategy"].flatMap(scalarText), strategy != "Plain" { title = "\(strategy) \(title)" }
        if let relation = plan["Relation Name"].flatMap(scalarText) {
            let schema = plan["Schema"].flatMap(scalarText).map { "\($0)." } ?? ""
            title += " on \(schema)\(relation)"
            if let alias = plan["Alias"].flatMap(scalarText), alias != relation { title += " \(alias)" }
        } else if let cte = plan["CTE Name"].flatMap(scalarText) {
            title += " on \(cte)"
        } else if let function = plan["Function Name"].flatMap(scalarText) {
            title += " on \(function)"
        }
        if let index = plan["Index Name"].flatMap(scalarText) { title += " using \(index)" }

        var details: [QueryPlanNode.Detail] = []
        if let startup = plan["Startup Cost"].flatMap(number), let total = plan["Total Cost"].flatMap(number) {
            details.append(.init("cost", String(format: "%.2f..%.2f", startup, total)))
        }
        if let rows = plan["Plan Rows"].flatMap(scalarText) { details.append(.init("rows", rows)) }
        if let width = plan["Plan Width"].flatMap(scalarText) { details.append(.init("width", width)) }
        for key in plan.keys.sorted() where !postgresTitleKeys.contains(key) {
            if let value = scalarText(plan[key]!) { details.append(.init(key, value)) }
        }
        var children: [QueryPlanNode] = []
        if case .array(let subplans)? = plan["Plans"] {
            for case .object(let subplan) in subplans { children.append(postgresNode(subplan, counter: &counter)) }
        }
        return QueryPlanNode(id: id, title: title, details: details, children: children)
    }

    // MARK: - MySQL / MariaDB

    /// `{"query_block": {"select_id": 1, "table": {...}, "nested_loop": [{"table": {...}}, …]}}`.
    /// Objects become nodes; their scalar fields (and flat objects such as `cost_info`) become details.
    public static func mysqlJSON(_ text: String) -> [QueryPlanNode]? {
        guard case .object(let root)? = decode(text) else { return nil }
        var counter = 0
        let nodes = mysqlChildren(of: root, counter: &counter)
        return nodes.isEmpty ? nil : nodes
    }

    private static func mysqlNode(key: String, _ object: [String: JSONValue], counter: inout Int) -> QueryPlanNode {
        counter += 1
        let id = counter
        var title: String
        var details: [QueryPlanNode.Detail] = []
        if let table = object["table_name"].flatMap(scalarText) {
            let access = object["access_type"].flatMap(scalarText) ?? ""
            title = "\(accessLabel(access)) on \(table)"
            if let key = object["key"].flatMap(scalarText) { title += " using \(key)" }
        } else {
            title = key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            if let select = object["select_id"].flatMap(scalarText) { title += " #\(select)" }
        }
        var children: [QueryPlanNode] = []
        for name in object.keys.sorted() {
            let value = object[name]!
            if let text = scalarText(value) {
                if name != "table_name" && name != "select_id" { details.append(.init(name, text)) }
                continue
            }
            switch value {
            case .object(let inner) where inner.values.allSatisfy({ scalarText($0) != nil }):
                // cost_info and similar: flat groups of numbers.
                for innerKey in inner.keys.sorted() { details.append(.init(innerKey, scalarText(inner[innerKey]!)!)) }
            case .object(let inner):
                children.append(mysqlNode(key: name, inner, counter: &counter))
            case .array(let items):
                for item in items {
                    guard case .object(let element) = item else { continue }
                    // `nested_loop: [{"table": {...}}]` names the element by its only key.
                    if element.count == 1, let (innerKey, innerValue) = element.first, case .object(let inner) = innerValue {
                        children.append(mysqlNode(key: innerKey, inner, counter: &counter))
                    } else {
                        children.append(mysqlNode(key: name, element, counter: &counter))
                    }
                }
            default:
                break
            }
        }
        return QueryPlanNode(id: id, title: title, details: details, children: children)
    }

    private static func mysqlChildren(of object: [String: JSONValue], counter: inout Int) -> [QueryPlanNode] {
        object.keys.sorted().compactMap { key in
            guard case .object(let inner)? = object[key] else { return nil }
            return mysqlNode(key: key, inner, counter: &counter)
        }
    }

    /// MySQL's access types in the words of a visual explain.
    private static func accessLabel(_ access: String) -> String {
        switch access.uppercased() {
        case "ALL": "Full Table Scan"
        case "INDEX": "Full Index Scan"
        case "RANGE": "Index Range Scan"
        case "REF", "REF_OR_NULL": "Non-Unique Key Lookup"
        case "EQ_REF": "Unique Key Lookup"
        case "CONST", "SYSTEM": "Single Row"
        case "FULLTEXT": "Fulltext Index Search"
        case "INDEX_MERGE": "Index Merge"
        case "": "Table"
        default: access
        }
    }

    // MARK: - JSON

    private static func decode(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }

    /// Scalars (and arrays of scalars, joined) as text; nil for objects and arrays of objects.
    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%.2f", d)
        case .string(let s): return s
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                if case .object = item { return nil }
                if case .array = item { return nil }
                return scalarText(item)
            }
            return parts.count == items.count ? parts.joined(separator: ", ") : nil
        case .object: return nil
        }
    }
}
