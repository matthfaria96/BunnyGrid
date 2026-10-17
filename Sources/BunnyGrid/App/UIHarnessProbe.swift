#if DEBUG
import AppKit
import BunnyGridCore
import SQLite3

/// Reads model state for `assert` / `waitFor` steps: `{"probe": "tab.builder.joins.count"}`.
///
/// Roots: `app` (AppModel), `tab` (the selected tab's model), `session`, `context`, `assistant`, `automation`, or a
/// named computed probe below. Each further segment reads a stored property by reflection (`_name` of @Observable
/// classes included), an enum case's payload by case name, or one of `count`, `first`, `last`, `isEmpty`, `case`,
/// `keys`, an index (`0`) or a dictionary key.
@MainActor
enum UIHarnessProbe {
    static func evaluate(_ path: String, app: AppModel) -> String? {
        // "sql:FILE|STATEMENT": the first column of the first row, read straight from a SQLite file.
        if path.hasPrefix("sql:"), let bar = path.firstIndex(of: "|") {
            return sqliteValue(file: String(path[path.index(path.startIndex, offsetBy: 4)..<bar]), sql: String(path[path.index(after: bar)...]))
        }
        // "file:PATH": the file's text (first 4 KB), or "missing".
        if path.hasPrefix("file:") {
            guard let data = FileManager.default.contents(atPath: String(path.dropFirst(5))) else { return "missing" }
            return String(decoding: data.prefix(4096), as: UTF8.self)
        }
        var segments = path.split(separator: ".").map(String.init)
        guard let head = segments.first else { return nil }
        segments.removeFirst()
        var value: Any?
        if let named = named(head, app: app) {
            value = named
        } else if let object = UIHarness.shared.registered(head) {
            value = object
        } else {
            switch head {
            case "app": value = app
            case "tab": value = app.selectedTab.map(payload)
            case "session": value = app.currentSession
            case "context": value = app.currentContext
            case "assistant": value = app.assistant
            case "automation": value = app.automation
            default: return nil
            }
        }
        for segment in segments {
            guard let current = value.flatMap(unwrap) else { return segment == "isNil" ? "true" : nil }
            value = step(current, segment)
        }
        guard let value = value.flatMap(unwrap) else { return "nil" }
        return describe(value)
    }

    private static func sqliteValue(file: String, sql: String) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return "error: cannot open \(file)" }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return "error: \(String(cString: sqlite3_errmsg(db)))" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return "no rows" }
        guard let text = sqlite3_column_text(statement, 0) else { return "NULL" }
        return String(cString: text)
    }

    /// Computed state that reflection cannot see.
    private static func named(_ name: String, app: AppModel) -> Any? {
        switch name {
        case "alert": return app.alertMessage ?? "nil"
        case "tabCount": return app.tabs.count
        case "tabTitle": return app.selectedTab?.title ?? "nil"
        case "tabKind": return app.selectedTab.map { "\(Mirror(reflecting: $0).children.first?.label ?? "?")" } ?? "nil"
        case "tabTitles": return app.tabs.map(\.title).joined(separator: "|")
        case "connections": return app.connections.map(\.name).joined(separator: "|")
        case "connectionCount": return app.connections.count
        case "navSelection": return app.navSelection.map { "\($0)" } ?? "nil"
        case "expandedCount": return app.expanded.count
        case "sheet": return NSApp.windows.contains { $0.isVisible && $0.isSheet }
        case "opened": return UIHarness.opened.joined(separator: "|")
        case "options": return AppOptions.shared.values
        case "appearance": return NSApp.appearance?.name.rawValue ?? "system"
        case "popover": return NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        case "windowCount": return NSApp.windows.filter { $0.isVisible && $0.level == .normal }.count
        case "keyWindow": return NSApp.keyWindow?.title ?? "nil"
        case "pasteboard": return NSPasteboard.general.string(forType: .string) ?? "nil"
        case "firstResponder": return (NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible })?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        case "openSessions": return app.sessions.values.filter { $0.contexts.values.contains(where: \.isOpen) }.count
        default:
            // "menu:File>Save" → whether that menu bar item is enabled right now (without updating the menu first).
            if name.hasPrefix("menu:") {
                var menu = NSApp.mainMenu
                var item: NSMenuItem?
                for title in name.dropFirst(5).split(separator: ">").map(String.init) {
                    item = menu?.items.first { $0.title == title }
                    menu = item?.submenu
                }
                return item.map { $0.isEnabled } ?? "missing"
            }
            return nil
        }
    }

    private static func payload(_ tab: WorkspaceTab) -> Any {
        Mirror(reflecting: tab).children.first?.value ?? tab
    }

    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.map { unwrap($0.value) } ?? nil
    }

    private static func step(_ value: Any, _ segment: String) -> Any? {
        if let probing = value as? UIHarnessProbing, let computed = probing.harnessProbe(segment) { return computed }
        let mirror = Mirror(reflecting: value)
        switch segment {
        case "isNil": return false
        case "case":
            if mirror.displayStyle == .enum { return mirror.children.first?.label ?? "\(value)" }
            return "\(value)"
        case "count":
            if let string = value as? String { return string.count }
            if let collection = value as? any Collection { return collection.count }
            return mirror.children.count
        case "isEmpty":
            if let collection = value as? any Collection { return collection.isEmpty }
            return mirror.children.isEmpty
        case "first": return mirror.children.first?.value
        case "last": return mirror.children.reversed().first?.value
        case "keys":
            guard mirror.displayStyle == .dictionary else { return nil }
            return mirror.children.compactMap { Mirror(reflecting: $0.value).children.first.map { "\($0.value)" } }.sorted().joined(separator: "|")
        default: break
        }
        if let index = Int(segment), mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .tuple {
            let children = Array(mirror.children)
            return children.indices.contains(index) ? children[index].value : nil
        }
        if mirror.displayStyle == .dictionary {
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                if pair.count == 2, "\(pair[0].value)" == segment { return pair[1].value }
            }
            return nil
        }
        if mirror.displayStyle == .enum {
            guard let child = mirror.children.first, child.label == segment else { return nil }
            return child.value
        }
        var current: Mirror? = mirror
        while let level = current {
            for child in level.children where child.label == segment || child.label == "_" + segment || child.label == "$__lazy_storage_$_" + segment {
                return child.value
            }
            current = level.superclassMirror
        }
        // Collections of models: map the segment over the elements ("tables.name" → "a|b").
        if mirror.displayStyle == .collection {
            return mirror.children.compactMap { step($0.value, segment).flatMap(unwrap).map(describe) }.joined(separator: "|")
        }
        return nil
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? any BinaryInteger { return "\(number)" }
        if let number = value as? Double { return number == number.rounded() ? String(Int(number)) : String(format: "%.3f", number) }
        if let number = value as? CGFloat { return String(format: "%.1f", Double(number)) }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .enum, mirror.children.isEmpty { return "\(value)" }
        if mirror.displayStyle == .enum { return String(describing: value) }
        return "\(value)"
    }
}

/// Computed state a model exposes to probes (reflection only sees stored properties).
@MainActor
protocol UIHarnessProbing {
    func harnessProbe(_ key: String) -> Any?
}

extension QueryBuilderModel: UIHarnessProbing {
    func harnessProbe(_ key: String) -> Any? {
        switch key {
        case "sql": sql
        case "objects": filteredObjects.map(\.name)
        default: nil
        }
    }
}

extension QueryTabModel: UIHarnessProbing {
    func harnessProbe(_ key: String) -> Any? {
        switch key {
        case "text": text
        case "resultCount": results.count
        default: nil
        }
    }
}

/// `{"op": "action", "name": ...}`: model-level shortcuts for setup that is not itself under test.
@MainActor
enum UIHarnessActions {
    static func perform(_ step: [String: Any], app: AppModel) async throws {
        let name = step["name"] as? String ?? ""
        func context() async throws -> DatabaseContext {
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if let context = app.currentContext, context.isOpen { return context }
                if let context = app.sessions.values.lazy.compactMap({ $0.contexts.values.first(where: \.isOpen) }).first { return context }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw UIHarness.Failure("no open database")
        }
        func object(_ name: String?, in context: DatabaseContext) throws -> DatabaseObject {
            guard let name, let found = context.objects(in: context.defaultSchema)?.first(where: { $0.name == name }) else {
                throw UIHarness.Failure("no table \(name ?? "?")")
            }
            return found
        }
        switch name {
        case "openTable":
            let context = try await context()
            app.openTable(try object(step["table"] as? String, in: context), in: context)
        case "openQuery":
            app.openQuery(text: step["text"] as? String ?? "", in: try await context())
        case "openDesign":
            let context = try await context()
            app.openDesign(table: try? object(step["table"] as? String, in: context), in: context)
        case "openModel":
            let context = try await context()
            app.openModel(in: context, schema: context.defaultSchema)
        case "newBI":
            let context = try await context()
            app.newBIWorkspace(in: context, table: try? object(step["table"] as? String, in: context))
        case "openAutomation":
            app.openAutomation()
        case "connectFirst":
            guard let first = app.connections.first else { throw UIHarness.Failure("no saved connection") }
            app.connect(first.id)
            app.navSelection = .connection(first.id)
        case "closeAllTabs":
            for tab in app.tabs { app.closeTab(tab.id) }
        case "defaults":
            // {"name": "defaults", "key": "...", "value": ...}
            if let key = step["key"] as? String { UserDefaults.standard.set(step["value"], forKey: key) }
        case "showPane":
            app.showAssistant = true
            if let pane = (step["pane"] as? String).flatMap(AppModel.RightPane.init(rawValue:)) { app.rightPane = pane }
        case "settings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            throw UIHarness.Failure("unknown action \(name)")
        }
    }
}
#endif
