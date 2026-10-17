#if DEBUG
import AppKit
import BunnyGridCore
import SwiftUI

/// `--ui-script FILE [--ui-results FILE] [--ui-shots DIR]`: runs a scripted interaction scenario inside the app.
///
/// Every event is synthesized with `NSEvent` and queued with `NSApp.postEvent` for one of the app's own windows,
/// so tracking loops (drags, menus, sliders) see them as if the mouse moved — but the real pointer never moves and
/// nothing reaches other apps. Targets are found through the in-process accessibility tree (SwiftUI
/// `.accessibilityIdentifier`, labels, roles) or by AppKit view class plus a named anchor (`UIHarnessAnchors`).
/// System drag and drop (`.draggable` / `.onDrag`) is delivered straight to the destination view's
/// `NSDraggingDestination` methods with an in-memory pasteboard. Results go to a JSON file; screenshots are the
/// app's own window (`CGWindowListCreateImage` of its window id, falling back to `cacheDisplay`).
///
/// A scenario is `{"name", "args": [launch flags, read by scripts/ui-test.sh], "steps": [...]}`. Step ops:
/// wait, waitFor, assert, click, doubleClick, rightClick, hover, drag, dragDrop, key, type, scroll, magnify, menu
/// (choose in the open menu), menuBar, screenshot, action (model-level setup), log. See scripts/ui-scenarios/README.md.
@MainActor
final class UIHarness {
    static let shared = UIHarness()
    weak var app: AppModel?

    static var scriptPath: String? { argument("--ui-script") }

    static func argument(_ flag: String) -> String? {
        CommandLine.arguments.firstIndex(of: flag).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }

    struct StepResult: Encodable {
        var index: Int
        var op: String
        var note: String?
        var ok: Bool
        var ms: Double
        var error: String?
        var screenshot: String?
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private var results: [StepResult] = []
    private var variables: [String: String] = [:]
    private var logs: [String] = []
    private var eventNumber = 0
    private var trackedMenus: [NSMenu] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var shotsDir: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var scenarioName = "scenario"
    /// The last pointer position, per window, so drags continue from where they were.
    private var pointer: NSPoint = .zero

    /// Models owned by views (`@State`) that probes read: `UIHarness.register("qb", model)` → `{"probe": "qb.query.joins.count"}`.
    private var objects: [String: () -> AnyObject?] = [:]

    static func register(_ name: String, _ object: AnyObject) {
        shared.objects[name] = { [weak object] in object }
    }

    func registered(_ name: String) -> AnyObject? { objects[name]?() }

    static func start(app: AppModel) {
        guard let path = scriptPath else { return }
        shared.app = app
        Task { await shared.run(path: path) }
    }

    // MARK: - Running

    private func run(path: String) async {
        let resultsURL = URL(fileURLWithPath: Self.argument("--ui-results") ?? (path + ".results.json"))
        shotsDir = URL(fileURLWithPath: Self.argument("--ui-shots") ?? resultsURL.deletingLastPathComponent().path)
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        installMenuTracking()
        Self.acceptFirstMouseEverywhere()
        logs.append("app active at start: \(NSApp.isActive)")
        if ProcessInfo.processInfo.environment["BUNNYGRID_UI_TRACE"] != nil {
            // Every event the app dispatches, with the view under it: why a synthesized event went nowhere.
            _ = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
                MainActor.assumeIsolated {
                    if event.type != .appKitDefined, event.type != .systemDefined, event.type != .periodic {
                        let hit = event.window.flatMap { $0.contentView?.superview?.hitTest(event.locationInWindow) }
                        FileHandle.standardError.write(Data("[ui-trace] \(event.type.rawValue) win=\(event.windowNumber) at=\(event.locationInWindow) hit=\(hit.map { String(describing: type(of: $0)).prefix(50) } ?? "-")\n".utf8))
                    }
                }
                return event
            }
        }
        var passed = true
        var fatal: String?
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let steps = root["steps"] as? [[String: Any]] else { throw Failure("scenario must be an object with \"steps\"") }
            scenarioName = (root["name"] as? String) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            // The first window on screen and the launch flags' work (connect, open tab) settled.
            try await waitUntil(timeout: 20) { NSApp.windows.contains { $0.isVisible && $0.contentView != nil } }
            try await Task.sleep(for: .milliseconds(Int(root["settleMs"] as? Double ?? 800)))
            for (index, step) in steps.enumerated() {
                let op = step["op"] as? String ?? "?"
                let started = ContinuousClock.now
                var result = StepResult(index: index, op: op, note: step["note"] as? String, ok: true, ms: 0)
                do {
                    result.screenshot = try await perform(op, step)
                } catch {
                    result.ok = false
                    result.error = "\(error)"
                    result.screenshot = screenshot(named: String(format: "fail-%02d", index))
                }
                let elapsed = ContinuousClock.now - started
                result.ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                results.append(result)
                FileHandle.standardError.write(Data("[ui] \(result.ok ? "ok  " : "FAIL") #\(index) \(op) \(result.note ?? "") \(result.error ?? "")\n".utf8))
                if !result.ok, step["optional"] as? Bool != true {
                    passed = false
                    break
                }
                // Let SwiftUI commit the step's changes before the next one looks at the screen.
                try? await Task.sleep(for: .milliseconds(Int(step["after"] as? Double ?? 120)))
            }
        } catch {
            passed = false
            fatal = "\(error)"
        }
        if let alert = app?.alertMessage { logs.append("alert on screen: \(alert)") }
        let report: [String: Any] = [
            "scenario": scenarioName,
            "passed": passed,
            "fatal": fatal as Any,
            "steps": results.map { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) ?? [:] },
            "logs": logs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: resultsURL)
        }
        if CommandLine.arguments.contains("--ui-keep-open") { return }
        try? await Task.sleep(for: .milliseconds(200))
        exit(passed ? 0 : 1)
    }

    private func perform(_ op: String, _ step: [String: Any]) async throws -> String? {
        switch op {
        case "wait":
            try await Task.sleep(for: .milliseconds(Int(step["ms"] as? Double ?? 300)))
        case "log":
            logs.append("\(step["text"] ?? "") \(try evaluate(step))")
        case "waitFor":
            let timeout = step["timeout"] as? Double ?? 10
            var lastError = ""
            try await waitUntil(timeout: timeout, describe: { lastError }) { [self] in
                do { try check(step); return true } catch { lastError = "\(error)"; return false }
            }
        case "assert":
            try check(step)
        case "remember":
            // {"op": "remember", "as": "before", "probe": ...}; later checks compare with "$before".
            variables[step["as"] as? String ?? "value"] = try evaluate(step)
        case "click", "doubleClick", "rightClick", "hover":
            let (window, point) = try locate(step)
            if op == "hover" {
                post(.mouseMoved, window, point)
                break
            }
            let count = op == "doubleClick" ? 2 : Int(step["count"] as? Double ?? 1)
            let flags = modifiers(step["modifiers"])
            if op == "rightClick" || step["button"] as? String == "right" {
                trackedMenus = []
                post(.rightMouseDown, window, point, flags: flags)
                post(.rightMouseUp, window, point, flags: flags)
            } else {
                for click in 1...count {
                    post(.leftMouseDown, window, point, flags: flags, clicks: click)
                    post(.leftMouseUp, window, point, flags: flags, clicks: click)
                }
            }
            try await drain()
            if let path = step["menu"] as? [String] { try await choose(path) }
        case "drag":
            let (window, from) = try locate(step["from"] as? [String: Any] ?? [:])
            let to: NSPoint
            if let delta = step["by"] as? [Double], delta.count == 2 {
                to = NSPoint(x: from.x + delta[0], y: from.y - delta[1])
            } else {
                let (other, point) = try locate(step["to"] as? [String: Any] ?? [:])
                guard other == window else { throw Failure("drag must stay in one window") }
                to = point
            }
            let flags = modifiers(step["modifiers"])
            let steps = max(2, Int(step["steps"] as? Double ?? 12))
            post(.leftMouseDown, window, from, flags: flags)
            try await drain()
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                post(.leftMouseDragged, window, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), flags: flags)
                try await drain(ms: 8)
            }
            post(.leftMouseUp, window, to, flags: flags)
            try await drain()
        case "dragDrop":
            guard let payload = step["payload"] as? String else { throw Failure("dragDrop needs a payload string") }
            let (window, point) = try locate(step["to"] as? [String: Any] ?? [:])
            try await deliverDrop(payload, in: window, at: point)
        case "key":
            let window = try targetWindow(step)
            guard let key = step["key"] as? String else { throw Failure("key needs \"key\"") }
            postKey(key, flags: modifiers(step["modifiers"]), window: window)
            try await drain()
        case "type":
            let window = try targetWindow(step)
            if let target = step["target"] as? [String: Any] {
                let (_, point) = try locate(target)
                post(.leftMouseDown, window, point)
                post(.leftMouseUp, window, point)
                try await drain()
            }
            if step["replace"] as? Bool == true {
                postKey("a", flags: .command, window: window)
                try await drain()
            }
            for character in (step["text"] as? String ?? "") {
                postKey(String(character), flags: [], window: window)
                try await drain(ms: 4)
            }
            try await drain()
        case "scroll":
            let (window, point) = try locate(step)
            try scroll(window, point, dx: step["dx"] as? Double ?? 0, dy: step["dy"] as? Double ?? 0, ticks: Int(step["ticks"] as? Double ?? 6))
            try await drain()
        case "magnify":
            let (window, point) = try locate(step)
            magnify(window, point, amount: step["amount"] as? Double ?? 0.25)
            try await drain()
        case "menu":
            try await choose(step["path"] as? [String] ?? [])
        case "menuBar":
            try menuBar(step["path"] as? [String] ?? [])
            try await drain()
        case "screenshot":
            return screenshot(named: step["name"] as? String ?? "shot-\(results.count)")
        case "action":
            guard let app else { throw Failure("no app") }
            try await UIHarnessActions.perform(step, app: app)
        case "dump":
            // The accessibility tree (role, id, label, value, frame) of every window, for writing scenarios.
            var lines: [String] = []
            for window in windows {
                lines.append("== window \"\(window.title)\" \(type(of: window)) id=\(window.identifier?.rawValue ?? "")")
                walkTree(AXNode(window), depth: 0, into: &lines)
            }
            let url = shotsDir.appendingPathComponent("\(scenarioName)-\(step["name"] as? String ?? "tree").txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        case "closeSheet":
            for window in NSApp.windows where window.isSheet { window.sheetParent?.endSheet(window) }
        default:
            throw Failure("unknown op \(op)")
        }
        return nil
    }

    /// While the app is in the background (the person keeps working in another app during a run), a click on a
    /// window that is not key only activates it unless the view accepts the first mouse. Scenarios must not depend
    /// on being frontmost, so every view takes the first click, as if the window were already key.
    private static func acceptFirstMouseEverywhere() {
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        let block: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: - Waiting and checks

    private func waitUntil(timeout: Double, describe: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure("timed out after \(timeout)s \(describe())") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Lets queued events dispatch (and any tracking loop they start consume them).
    private func drain(ms: Int = 60) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    /// The step's subject as a string: a probe path, an element's accessibility value / label, or a window title.
    private func evaluate(_ step: [String: Any]) throws -> String {
        if let path = step["probe"] as? String {
            guard let app else { throw Failure("no app") }
            return UIHarnessProbe.evaluate(path, app: app) ?? "nil"
        }
        if step["id"] != nil || step["label"] != nil || step["view"] != nil {
            if step["exists"] != nil { return (try? element(step)) == nil ? "false" : "true" }
            let found = try element(step)
            switch step["attribute"] as? String ?? "value" {
            case "label": return found.label
            case "enabled": return found.enabled ? "true" : "false"
            case "frame": return NSStringFromRect(found.frame)
            default: return found.value ?? found.label
            }
        }
        if step["windows"] != nil {
            return NSApp.windows.filter(\.isVisible).map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title }.joined(separator: "|")
        }
        if step["sheet"] != nil { return NSApp.windows.contains { $0.isVisible && $0.isSheet } ? "true" : "false" }
        throw Failure("nothing to check (probe/id/label/view/windows/sheet)")
    }

    private func check(_ step: [String: Any]) throws {
        if let exists = step["exists"] as? Bool {
            let found = (try? element(step)) != nil
            guard found == exists else { throw Failure("expected \(describe(step)) \(exists ? "to exist" : "to be gone")") }
            return
        }
        let value = try evaluate(step)
        var step = step
        for key in ["equals", "notEquals", "contains", "notContains"] {
            if let text = step[key] as? String, text.hasPrefix("$"), let stored = variables[String(text.dropFirst())] { step[key] = stored }
        }
        if let expected = step["equals"] { guard value == "\(expected)" else { throw Failure("\(describe(step)) = \"\(value)\", expected \"\(expected)\"") } }
        if let expected = step["notEquals"] { guard value != "\(expected)" else { throw Failure("\(describe(step)) is \"\(value)\"") } }
        if let expected = step["contains"] as? String { guard value.contains(expected) else { throw Failure("\(describe(step)) = \"\(value.prefix(300))\", missing \"\(expected)\"") } }
        if let expected = step["notContains"] as? String { guard !value.contains(expected) else { throw Failure("\(describe(step)) contains \"\(expected)\"") } }
        if let minimum = step["atLeast"] as? Double {
            guard let number = Double(value), number >= minimum else { throw Failure("\(describe(step)) = \(value), expected ≥ \(minimum)") }
        }
        if let maximum = step["atMost"] as? Double {
            guard let number = Double(value), number <= maximum else { throw Failure("\(describe(step)) = \(value), expected ≤ \(maximum)") }
        }
    }

    private func describe(_ step: [String: Any]) -> String {
        for key in ["probe", "id", "label", "view"] { if let value = step[key] { return "\(key) \(value)" } }
        return "value"
    }

    // MARK: - Finding elements

    struct Element {
        var window: NSWindow
        var frame: NSRect   // window coordinates (bottom-left origin)
        var label: String
        var value: String?
        var enabled: Bool
        var view: NSView?
    }

    /// Visible windows front to back (sheets and menus' owners first).
    private var windows: [NSWindow] {
        NSApp.orderedWindows.filter {
            $0.isVisible && $0.contentView != nil && !($0 is NSPanel && $0.title.isEmpty && $0.contentView?.subviews.isEmpty == true)
                && String(describing: type(of: $0)) != "SPRoundedWindow"   // text-field autocomplete popup
        }
    }

    private func targetWindow(_ step: [String: Any]) throws -> NSWindow {
        if let target = step["target"] as? [String: Any] { return try element(target).window }
        if let key = NSApp.keyWindow, key.isVisible { return key }
        guard let first = windows.first else { throw Failure("no window") }
        return first
    }

    /// Finds the step's element: `id` (accessibility identifier), `label` (+ optional `role`), or `view` (class name)
    /// with optional `anchor`; `index` picks among matches; `window` ("sheet", "main", "settings" or a title) narrows.
    private func element(_ spec: [String: Any]) throws -> Element {
        var candidates = windows
        if let which = spec["window"] as? String {
            candidates = candidates.filter { window in
                switch which {
                case "sheet": window.isSheet
                case "main": window.identifier?.rawValue.hasPrefix("main") == true
                case "settings": window.identifier?.rawValue.contains("Settings") == true || window.title.contains("Settings") || window.title.contains("Options")
                default: window.title == which
                }
            }
        }
        let index = Int(spec["index"] as? Double ?? 0)
        if let className = spec["view"] as? String {
            var matches: [(NSWindow, NSView)] = []
            for window in candidates {
                guard let root = window.contentView?.superview ?? window.contentView else { continue }
                walkViews(root) { view in
                    if String(describing: type(of: view)) == className, !view.isHiddenOrHasHiddenAncestor { matches.append((window, view)) }
                }
            }
            guard matches.indices.contains(index) else { throw Failure("no view \(className) #\(index) (found \(matches.count))") }
            let (window, view) = matches[index]
            var frame = view.convert(view.bounds, to: nil)
            if let anchor = spec["anchor"] as? String {
                guard let provider = view as? UIHarnessAnchors else { throw Failure("\(className) has no anchors") }
                guard let rect = provider.harnessAnchor(anchor) else { throw Failure("\(className) has no anchor \(anchor)") }
                frame = view.convert(rect, to: nil)
            }
            return Element(window: window, frame: frame, label: className, value: (view as? UIHarnessAnchors)?.harnessValue, enabled: true, view: view)
        }
        let identifier = spec["id"] as? String
        let label = spec["label"] as? String
        let role = spec["role"] as? String
        guard identifier != nil || label != nil else { throw Failure("target needs id, label or view") }
        var matches: [Element] = []
        for window in candidates {
            walkAccessibility(AXNode(window), depth: 0) { node in
                if let identifier, node.identifier != identifier { return }
                let title = node.label
                let valueString = node.value
                if let label, title != label, valueString != label, node.placeholder != label { return }
                if let role, node.role != role, node.role != "AX" + role.prefix(1).uppercased() + role.dropFirst() { return }
                let screen = node.frame
                guard screen.width > 0 || screen.height > 0 else { return }
                matches.append(Element(window: window, frame: window.convertFromScreen(screen), label: title, value: valueString,
                                       enabled: node.enabled, view: node.object as? NSView))
            }
        }
        guard matches.indices.contains(index) else {
            throw Failure("no element \(identifier.map { "id=\($0)" } ?? "") \(label.map { "label=\($0)" } ?? "") (found \(matches.count))")
        }
        return matches[index]
    }

    private func walkTree(_ node: AXNode, depth: Int, into lines: inout [String]) {
        guard depth < 80 else { return }
        var line = String(repeating: "  ", count: depth) + node.role
        if let id = node.identifier, !id.isEmpty { line += " #\(id)" }
        if !node.label.isEmpty { line += " \"\(node.label)\"" }
        if let value = node.value { line += " =\(value.prefix(60))" }
        if node.object is NSView { line += " <\(String(describing: type(of: node.object)).prefix(60))>" }
        let frame = node.frame
        line += " [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
        if !node.enabled { line += " disabled" }
        lines.append(line)
        for child in node.children { walkTree(child, depth: depth + 1, into: &lines) }
    }

    private func walkViews(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for subview in view.subviews { walkViews(subview, visit) }
    }

    private func walkAccessibility(_ node: AXNode, depth: Int, _ visit: (AXNode) -> Void) {
        guard depth < 80 else { return }
        visit(node)
        for child in node.children { walkAccessibility(child, depth: depth + 1, visit) }
    }

    /// The point to act on: the element's centre, or `at` ([fx, fy] fractions from its top-left), plus `offset` [dx, dy]
    /// (points, y down).
    private func locate(_ spec: [String: Any]) throws -> (NSWindow, NSPoint) {
        var found = try element(spec)
        // Scrolled out of its scroll view: bring it into view first, as a person would.
        if spec["view"] == nil, reveal(found.frame, in: found.window) { found = try element(spec) }
        var fx = 0.5, fy = 0.5
        if let at = spec["at"] as? [Double], at.count == 2 { fx = at[0]; fy = at[1] }
        var point = NSPoint(x: found.frame.minX + found.frame.width * fx, y: found.frame.maxY - found.frame.height * fy)
        if let offset = spec["offset"] as? [Double], offset.count == 2 { point.x += offset[0]; point.y -= offset[1] }
        if found.window.isKeyWindow == false, !found.window.isSheet { found.window.makeKeyAndOrderFront(nil) }
        return (found.window, point)
    }

    /// Scrolls the innermost scroll view whose document holds `frame` (window coordinates) so its centre is visible.
    private func reveal(_ frame: NSRect, in window: NSWindow) -> Bool {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        var scrollViews: [NSScrollView] = []
        if let root = window.contentView?.superview ?? window.contentView {
            walkViews(root) { view in
                if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor, let document = scroll.documentView,
                   document.convert(document.bounds, to: nil).contains(center) { scrollViews.append(scroll) }
            }
        }
        guard let scroll = scrollViews.last, let document = scroll.documentView else { return false }
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        guard !visible.insetBy(dx: 2, dy: 2).contains(center) else { return false }
        document.scrollToVisible(document.convert(frame, from: nil).insetBy(dx: -8, dy: -8))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
        return true
    }

    // MARK: - Events

    private func modifiers(_ value: Any?) -> NSEvent.ModifierFlags {
        let names = (value as? [String]) ?? ((value as? String).map { [$0] } ?? [])
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    private func post(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        eventNumber += 1
        pointer = point
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                             clickCount: type == .mouseMoved ? 0 : clicks, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static let keyCodes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "enter": (76, "\u{3}"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7F}"),
        "escape": (53, "\u{1B}"), "forwarddelete": (117, "\u{F728}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
        "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"), "f2": (120, "\u{F705}"),
    ]
    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    private func postKey(_ key: String, flags: NSEvent.ModifierFlags, window: NSWindow) {
        let code: UInt16
        var characters: String
        if let special = Self.keyCodes[key.lowercased()] {
            (code, characters) = special
        } else {
            characters = key
            code = key.count == 1 ? (Self.letterCodes[Character(key.lowercased())] ?? 0) : 0
        }
        var flags = flags
        if characters.count == 1, let scalar = characters.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) { flags.insert(.shift) }
        let ignoring = flags.contains(.shift) ? characters : characters.lowercased()
        if flags.contains(.option), key.count == 1 { characters = key }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            eventNumber += 1
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Scroll-wheel events are built from a CGEvent (never posted to the system) addressed at the window.
    private func scroll(_ window: NSWindow, _ point: NSPoint, dx: Double, dy: Double, ticks: Int) throws {
        let screenPoint = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        for _ in 0..<max(1, ticks) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(dy / Double(max(1, ticks))), wheel2: Int32(dx / Double(max(1, ticks))), wheel3: 0) else { throw Failure("scroll event") }
            cg.location = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            guard let event = NSEvent(cgEvent: cg) else { throw Failure("scroll event") }
            // Through the window, as AppKit delivers the wheel: it routes to the view under the point.
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Pinch: a magnify gesture event when one can be built, otherwise the enclosing scroll view's magnification
    /// (what NSScrollView does with the gesture).
    private func magnify(_ window: NSWindow, _ point: NSPoint, amount: Double) {
        let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        if let cg = CGEvent(source: nil) {
            cg.type = CGEventType(rawValue: 29)!   // kCGSEventGesture
            cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // kIOHIDEventTypeZoom
            cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
            let screenPoint = window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
            if let event = NSEvent(cgEvent: cg), event.type == .magnify, let hit {
                hit.magnify(with: event)
                return
            }
        }
        var view = hit
        while let current = view, !(current is NSScrollView) { view = current.superview }
        if let scrollView = view as? NSScrollView, scrollView.allowsMagnification {
            scrollView.setMagnification(scrollView.magnification * (1 + amount), centeredAt: scrollView.contentView.convert(point, from: nil))
        } else {
            logs.append("magnify: no magnifiable view at \(point)")
        }
    }

    // MARK: - Menus

    private func installMenuTracking() {
        guard menuObservers.isEmpty else { return }
        let watcher = MenuWatcher()
        NotificationCenter.default.addObserver(watcher, selector: #selector(MenuWatcher.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(watcher, selector: #selector(MenuWatcher.ended(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        menuObservers.append(watcher)
    }

    private final class MenuWatcher: NSObject {
        @MainActor @objc func began(_ note: Notification) {
            guard let menu = note.object as? NSMenu, !UIHarness.shared.trackedMenus.contains(menu) else { return }
            UIHarness.shared.trackedMenus.append(menu)
        }

        @MainActor @objc func ended(_ note: Notification) {
            guard let menu = note.object as? NSMenu else { return }
            UIHarness.shared.trackedMenus.removeAll { $0 === menu }
        }
    }

    /// Picks `path` in the menu that is open (context menu, pop-up button, join menu): finds the item, closes the menu
    /// and then performs the item, as a click on it would.
    private func choose(_ path: [String]) async throws {
        guard !path.isEmpty else { return }
        try await waitUntil(timeout: 3, describe: { "no menu opened" }) { trackedMenus.contains { $0.supermenu == nil } }
        guard let root = trackedMenus.last(where: { $0.supermenu == nil }) else { throw Failure("no open menu") }
        var menu = root
        var item: NSMenuItem?
        for (depth, title) in path.enumerated() {
            menu.update()
            guard let found = menu.items.first(where: { matches($0, title) }) else {
                let titles = menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")
                root.cancelTrackingWithoutAnimation()
                throw Failure("menu has no \"\(title)\" (items: \(titles))")
            }
            item = found
            if depth < path.count - 1 {
                guard let submenu = found.submenu else { throw Failure("\"\(title)\" has no submenu") }
                menu = submenu
            }
        }
        guard let item, let owner = item.menu, let index = Optional(owner.index(of: item)), index >= 0 else { return }
        guard item.isEnabled else {
            root.cancelTrackingWithoutAnimation()
            throw Failure("menu item \"\(item.title)\" is disabled")
        }
        root.cancelTrackingWithoutAnimation()
        try await drain(ms: 30)
        await onRunLoop { owner.performActionForItem(at: index) }
        try await drain()
    }

    private func matches(_ item: NSMenuItem, _ title: String) -> Bool {
        let plain = item.title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        let wanted = title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        return plain == wanted || item.attributedTitle?.string == title
            || (item.view as? UIHarnessMenuItemView)?.harnessTitle == title || item.accessibilityLabel() == title
    }

    private func menuBar(_ path: [String]) throws {
        guard var menu = NSApp.mainMenu else { throw Failure("no main menu") }
        for (depth, title) in path.enumerated() {
            menu.update()
            guard let item = menu.items.first(where: { matches($0, title) }) else {
                throw Failure("menu bar has no \"\(title)\" (items: \(menu.items.map(\.title).joined(separator: ", ")))")
            }
            if depth == path.count - 1 {
                guard item.isEnabled else { throw Failure("\"\(title)\" is disabled") }
                let box = UncheckedBox((menu, menu.index(of: item)))
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated { box.value.0.performActionForItem(at: box.value.1) } }; CFRunLoopWakeUp(CFRunLoopGetMain())
            } else {
                guard let submenu = item.submenu else { throw Failure("\"\(title)\" has no submenu") }
                menu = submenu
            }
        }
    }

    // MARK: - Drag and drop

    /// Delivers a system drag (as `.draggable` / `.onDrag` would start) to the view under `point`: entered, updated
    /// and perform, with the payload on a private pasteboard.
    private func deliverDrop(_ payload: String, in window: NSWindow, at point: NSPoint) async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.bunnygrid.uiharness.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("public.utf8-plain-text")], owner: nil)
        pasteboard.setString(payload, forType: .string)
        let info = HarnessDraggingInfo(window: window, location: point, pasteboard: pasteboard)
        let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        var view = hit
        let types = Set(pasteboard.types ?? [.string])
        // The innermost view that registered for a type on the pasteboard.
        var chain: [String] = []
        while let current = view, !current.registeredDraggedTypes.contains(where: types.contains) {
            chain.append(String(describing: type(of: current)).prefix(40) + "")
            view = current.superview
        }
        guard let destination = view else { throw Failure("no drop destination at \(point) (hit: \(chain.joined(separator: " < ")))") }
        let entered = await onRunLoop { destination.draggingEntered(info) }
        try await drain(ms: 30)
        var updated: NSDragOperation = []
        for offset in [1.0, 0.0] {
            info.location = NSPoint(x: point.x + offset, y: point.y)
            updated = await onRunLoop { destination.responds(to: #selector(NSView.draggingUpdated(_:))) ? destination.draggingUpdated(info) : entered }
            try await drain(ms: 30)
        }
        guard entered != [] || updated != [] else {
            await onRunLoop { if destination.responds(to: #selector(NSView.draggingExited(_:))) { destination.draggingExited(info) } }
            throw Failure("\(type(of: destination)) refused the drop of \(payload)")
        }
        let accepted = await onRunLoop {
            // The optional NSDraggingDestination methods are only sent when implemented, as AppKit does.
            if destination.responds(to: #selector(NSView.prepareForDragOperation(_:))) {
                guard destination.prepareForDragOperation(info) else { return false }
            }
            let accepted = destination.performDragOperation(info)
            if destination.responds(to: #selector(NSView.concludeDragOperation(_:))) { destination.concludeDragOperation(info) }
            if destination.responds(to: #selector(NSView.draggingEnded(_:))) { destination.draggingEnded(info) }
            return accepted
        }
        guard accepted else { throw Failure("\(type(of: destination)) did not accept \(payload)") }
        try await drain()
    }

    /// Runs `body` from the run loop, outside any Swift task, as AppKit delivers real events. SwiftUI updates that
    /// run synchronously inside a task's context crashed in executor checks (`swift_task_isCurrentExecutor`).
    private func onRunLoop<T>(_ body: @escaping @MainActor () -> T) async -> T {
        let box = UncheckedBox(body)
        let result = ResultBox<T>()
        let resultBox = UncheckedBox(result)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { resultBox.value.value = box.value() }
        }
        while result.value == nil { try? await Task.sleep(for: .milliseconds(5)) }
        return result.value!
    }

    // MARK: - Screenshots

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The main window; a sheet on it is saved alongside as NAME-sheet.png. Returns the main capture's path.
    func screenshot(named name: String) -> String? {
        let main = NSApp.orderedWindows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.keyWindow ?? windows.first
        guard let main else { return nil }
        let path = capture(main, as: name)
        if let sheet = main.attachedSheet { _ = capture(sheet, as: name + "-sheet") }
        for other in windows where other !== main && !other.isSheet && other.level == .normal {
            _ = capture(other, as: name + "-" + (other.title.isEmpty ? "window" : other.title.lowercased().replacingOccurrences(of: " ", with: "-")))
        }
        return path
    }

    private func capture(_ window: NSWindow, as name: String) -> String? {
        var image: CGImage?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // .optionIncludingWindow; .boundsIgnoreFraming | .bestResolution: only this window, never what is behind it.
            image = function(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
        }
        if (image?.width ?? 0) < 4, let view = window.contentView?.superview ?? window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        guard let image else { logs.append("screenshot \(name) failed"); return nil }
        let url = shotsDir.appendingPathComponent("\(scenarioName)-\(name).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url.path
    }
}

/// An accessibility element, whether it adopts NSAccessibilityProtocol or only the informal attribute API
/// (SwiftUI's elements).
@MainActor
struct AXNode {
    let object: NSObject

    init(_ object: NSObject) { self.object = object }

    /// Reads an NSAccessibility getter by name: formal adopters and SwiftUI's elements (which implement the
    /// methods without declaring the protocol) both answer through KVC.
    private func read(_ key: String) -> Any? {
        if object.responds(to: Selector(key)) { return object.value(forKey: key) }
        // Older elements only answer the attribute API.
        let attribute: NSAccessibility.Attribute? = switch key {
        case "accessibilityRole": .role
        case "accessibilityIdentifier": .identifier
        case "accessibilityLabel": .description
        case "accessibilityTitle": .title
        case "accessibilityValue": .value
        case "isAccessibilityEnabled": .enabled
        case "accessibilityChildren": .children
        default: nil
        }
        if let attribute, object.responds(to: #selector(NSObject.accessibilityAttributeValue(_:))) {
            return object.accessibilityAttributeValue(attribute)
        }
        if key == "accessibilityFrame", object.responds(to: #selector(NSObject.accessibilityAttributeValue(_:))),
           let origin = (object.accessibilityAttributeValue(.position) as? NSValue)?.pointValue,
           let size = (object.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue {
            let height = NSScreen.screens.first?.frame.height ?? 0
            return NSValue(rect: NSRect(x: origin.x, y: height - origin.y - size.height, width: size.width, height: size.height))
        }
        return nil
    }

    var role: String { (read("accessibilityRole") as? String) ?? "?" }
    var identifier: String? { read("accessibilityIdentifier") as? String }
    var label: String {
        if let label = read("accessibilityLabel") as? String, !label.isEmpty { return label }
        return (read("accessibilityTitle") as? String) ?? ""
    }
    var value: String? { read("accessibilityValue").map { "\($0)" } }
    var enabled: Bool { (read("isAccessibilityEnabled") as? Bool) ?? true }
    var placeholder: String? { read("accessibilityPlaceholderValue") as? String }
    var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    var children: [AXNode] {
        ((read("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) }
    }
}

/// Views drawn in AppKit (canvases) name points of interest so scenarios can address them.
@MainActor
protocol UIHarnessAnchors: AnyObject {
    /// A rect in the view's coordinates for `name` (e.g. "table:customers", "column:customers.id").
    func harnessAnchor(_ name: String) -> NSRect?
    /// A summary for `assert` on `{view: ...}`.
    var harnessValue: String? { get }
}

extension UIHarnessAnchors {
    var harnessValue: String? { nil }
}

/// Menu items drawn by a custom view name themselves for `menu` steps.
@MainActor
protocol UIHarnessMenuItemView: AnyObject {
    var harnessTitle: String { get }
}

final class ResultBox<T> {
    var value: T?
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The NSDraggingInfo a real drag session would hand the destination.
@MainActor
final class HarnessDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let window: NSWindow
    var location: NSPoint
    let pasteboard: NSPasteboard

    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        self.window = window
        self.location = location
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic, .link] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let string = pasteboard.string(forType: .string) else { return }
        let item = NSDraggingItem(pasteboardWriter: string as NSString)
        var stop: ObjCBool = false
        block(item, 0, &stop)
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
