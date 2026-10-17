#if DEBUG
import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

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
        var optional: Bool?
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private var results: [StepResult] = []
    /// Remembered values ("$name"); "$RUN" is the run's scratch directory (scripts/ui-test.sh sets BUNNYGRID_UI_RUN).
    private var variables: [String: String] = ["RUN": ProcessInfo.processInfo.environment["BUNNYGRID_UI_RUN"] ?? FileManager.default.currentDirectoryPath]
    /// How mouse events are made and delivered: "cg" (from a CGEvent, queued), "ns" (NSEvent.mouseEvent, queued),
    /// "send" (from a CGEvent, NSApp.sendEvent from the run loop). Scenarios may set it: {"op": "mode", "mode": ...}.
    private var postMode = "cg"
    private var held: (NSWindow, NSPoint, NSEvent.ModifierFlags)?
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
        logs.append("app active at start: \(NSApp.isActive)")
        if ProcessInfo.processInfo.environment["BUNNYGRID_UI_REAL_FOCUS"] == nil {
            Self.acceptFirstMouseEverywhere()
            Self.virtualizePointer()
            Self.virtualizeKeyWindow()
        }
        Self.privatePasteboard()
        Self.scriptPanels()
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
                var result = StepResult(index: index, op: op, note: step["note"] as? String, ok: true, ms: 0, optional: step["optional"] as? Bool)
                do {
                    result.screenshot = try await perform(op, step)
                } catch {
                    result.ok = false
                    result.error = "\(error)"
                    result.screenshot = screenshot(named: String(format: "fail-%02d", index))
                    _ = try? await perform("dump", ["name": String(format: "fail-%02d-tree", index)])
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
                try await drain()
                await hover(window, point)
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
            // "release": false keeps the button down (screenshot mid-drag); a later {"op": "release"} lets go.
            if step["release"] as? Bool == false {
                held = (window, to, flags)
            } else {
                post(.leftMouseUp, window, to, flags: flags)
            }
            try await drain()
        case "mode":
            postMode = step["mode"] as? String ?? "cg"
        case "keyEquivalentProbe":
            let window = try targetWindow(step)
            let key = step["key"] as? String ?? "s"
            for kind in ["ns", "cg"] {
                var event: NSEvent?
                if kind == "ns" {
                    event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                             keyCode: Self.letterCodes[Character(key)] ?? 0)
                } else if let cg = CGEvent(keyboardEventSource: nil, virtualKey: Self.letterCodes[Character(key)] ?? 0, keyDown: true) {
                    cg.flags = .maskCommand
                    event = NSEvent(cgEvent: cg)
                }
                guard let event else { continue }
                let box = UncheckedBox(event)
                let windowBox = UncheckedBox(window)
                let byWindow = await onRunLoop { windowBox.value.performKeyEquivalent(with: box.value) }
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
                let handled = byWindow ? false : await onRunLoop { NSApp.mainMenu?.performKeyEquivalent(with: box.value) ?? false }
                logs.append("keyEquivalent \(kind) ⌘\(key): window=\(byWindow) menu=\(handled) responder=\(responder) active=\(NSApp.isActive)")
                try await drain(ms: 300)
            }
        case "menuDump":
            // The menu bar: title, key equivalent, enabled.
            var lines: [String] = []
            func walk(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items where !item.isSeparatorItem {
                    lines.append(String(repeating: "  ", count: depth) + "\(item.title) [\(item.keyEquivalentModifierMask.rawValue >> 16)+\(item.keyEquivalent)] \(item.isEnabled ? "" : "disabled") \(item.action.map { NSStringFromSelector($0) } ?? "")")
                    if let submenu = item.submenu { walk(submenu, depth + 1) }
                }
            }
            if let menu = NSApp.mainMenu { walk(menu, 0) }
            let url = shotsDir.appendingPathComponent("\(scenarioName)-menus.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        case "panel":
            if step["cancel"] as? Bool == true {
                Self.panelCancels = true
            } else {
                let paths = (step["paths"] as? [String]) ?? [(step["path"] as? String) ?? ""]
                Self.panelURLs = paths.map { URL(fileURLWithPath: substitute($0)) }
            }
        case "release":
            guard let (window, point, flags) = held else { throw Failure("no drag is held") }
            held = nil
            post(.leftMouseUp, window, point, flags: flags)
            try await drain()
        case "dragDrop":
            guard let raw = step["payload"] as? String else { throw Failure("dragDrop needs a payload string") }
            let payload = variables.keys.sorted { $0.count > $1.count }.reduce(raw) { $0.replacingOccurrences(of: "$" + $1, with: variables[$1]!) }
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
                focusText(at: point, in: window)
            } else if !(window.firstResponder is NSText) {
                focusText(at: pointer, in: window)
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
        case "selfTest":
            // Checks which SwiftUI gestures synthesized events can drive, in a window of their own.
            let probe = HarnessGestureProbe()
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: HarnessGestureView(probe: probe))
            window.makeKeyAndOrderFront(nil)
            try await drain(ms: 400)
            logs.append("selfTest key=\(window.isKeyWindow) active=\(NSApp.isActive) mainKey=\(NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.isKeyWindow ?? false)")
            for mode in ["cg", "ns", "send"] {
                postMode = mode
                probe.changed = [:]; probe.ended = [:]; probe.taps = [:]
                for (name, y) in [("plain", 350.0), ("scroll", 150.0)] {
                    post(.leftMouseDown, window, NSPoint(x: 100, y: y))
                    post(.leftMouseUp, window, NSPoint(x: 100, y: y))
                    try await drain(ms: 300)
                    post(.leftMouseDown, window, NSPoint(x: 100, y: y))
                    try await drain(ms: 30)
                    for i in 1...10 { post(.leftMouseDragged, window, NSPoint(x: 100 + Double(i) * 10, y: y)); try await drain(ms: 16) }
                    post(.leftMouseUp, window, NSPoint(x: 200, y: y))
                    try await drain(ms: 200)
                    logs.append("selfTest \(mode) \(name): changed=\(probe.changed[name] ?? 0) ended=\(probe.ended[name] ?? 0) taps=\(probe.taps[name] ?? 0)")
                    if mode == "cg", probe.changed[name] == nil || probe.ended[name] != 1 || probe.taps[name] != 1 {
                        window.orderOut(nil)
                        postMode = "cg"
                        throw Failure("SwiftUI did not see the synthesized \(name) tap/drag (\(probe.taps[name] ?? 0) taps, \(probe.changed[name] ?? 0) changes)")
                    }
                }
            }
            postMode = "cg"
            window.orderOut(nil)
        case "dumpViews":
            // The AppKit view tree: class, frame in the window, registered drag types.
            var lines: [String] = []
            for window in windows {
                lines.append("== window \"\(window.title)\" \(type(of: window))")
                func walk(_ view: NSView, _ depth: Int) {
                    var types = view.registeredDraggedTypes.isEmpty ? "" : " drag=\(view.registeredDraggedTypes.map(\.rawValue))"
                    if !view.gestureRecognizers.isEmpty { types += " gestures=\(view.gestureRecognizers.map { String(describing: type(of: $0)) })" }
                    if !view.trackingAreas.isEmpty { types += " tracking=\(view.trackingAreas.count)" }
                    lines.append(String(repeating: "  ", count: depth) + "\(String(describing: type(of: view)).prefix(70)) \(NSStringFromRect(view.convert(view.bounds, to: nil)))\(types)\(view.isHidden ? " hidden" : "")")
                    for subview in view.subviews { walk(subview, depth + 1) }
                }
                if let root = window.contentView?.superview { walk(root, 0) }
            }
            let url = shotsDir.appendingPathComponent("\(scenarioName)-\(step["name"] as? String ?? "views").txt")
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

    /// The scripted pointer, as the app sees it: SwiftUI gestures and hover read `NSEvent.pressedMouseButtons` and
    /// `NSEvent.mouseLocation` (the real hardware state) besides the events, so while a scenario runs both report the
    /// synthesized events' state, updated as each one is dispatched. The real pointer is untouched.
    /// SwiftUI ignores gestures (DragGesture, hover) in windows that are not key, and a background app has no key
    /// window. A scenario must not activate the app (that would take the keyboard from the person's current app), so
    /// the app is told it is active and its frontmost window that can be key is key.
    private static func virtualizeKeyWindow() {
        let active: @convention(block) (NSApplication) -> Bool = { _ in true }
        if let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) {
            method_setImplementation(method, imp_implementationWithBlock(active))
        }
        let key: @convention(block) (NSWindow) -> Bool = { window in
            MainActor.assumeIsolated {
                let front = NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey && String(describing: type(of: $0)) != "SPRoundedWindow" }
                return front === window
            }
        }
        if let method = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow)) {
            method_setImplementation(method, imp_implementationWithBlock(key))
        }
    }

    /// Copy commands in a scenario must not overwrite the person's clipboard: `NSPasteboard.general` is a private
    /// pasteboard for the run (the `pasteboard` probe reads it).
    nonisolated(unsafe) static let scenarioPasteboard = NSPasteboard(name: NSPasteboard.Name("app.bunnygrid.uiharness.general.\(getpid())"))

    private static func privatePasteboard() {
        let general: @convention(block) (AnyObject) -> NSPasteboard = { _ in UIHarness.scenarioPasteboard }
        if let method = class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)) {
            method_setImplementation(method, imp_implementationWithBlock(general))
        }
    }

    /// Open and save panels answer from the scenario instead of showing: `{"op": "panel", "path": "$RUN/out.csv"}`
    /// makes the next panel return OK with that URL ("cancel": true returns Cancel). Revealing files in Finder and
    /// opening URLs in other apps are recorded and not done (`opened` probe).
    nonisolated(unsafe) static var panelURLs: [URL]?
    nonisolated(unsafe) static var panelCancels = false
    nonisolated(unsafe) static var opened: [String] = []

    private static func scriptPanels() {
        let run: @convention(block) (NSSavePanel) -> Int = { _ in
            if UIHarness.panelCancels { UIHarness.panelCancels = false; return NSApplication.ModalResponse.cancel.rawValue }
            return UIHarness.panelURLs == nil ? NSApplication.ModalResponse.cancel.rawValue : NSApplication.ModalResponse.OK.rawValue
        }
        if let method = class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.runModal)) {
            method_setImplementation(method, imp_implementationWithBlock(run))
        }
        let sheet: @convention(block) (NSSavePanel, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { _, _, handler in
            let ok = UIHarness.panelURLs != nil && !UIHarness.panelCancels
            UIHarness.panelCancels = false
            DispatchQueue.main.async { handler(ok ? .OK : .cancel) }
        }
        if let method = class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.beginSheetModal(for:completionHandler:))) {
            method_setImplementation(method, imp_implementationWithBlock(sheet))
        }
        if let method = class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.begin(completionHandler:))) {
            let begin: @convention(block) (NSSavePanel, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { _, handler in
                let ok = UIHarness.panelURLs != nil
                DispatchQueue.main.async { handler(ok ? .OK : .cancel) }
            }
            method_setImplementation(method, imp_implementationWithBlock(begin))
        }
        let url: @convention(block) (NSSavePanel) -> URL? = { _ in UIHarness.panelURLs?.first }
        if let method = class_getInstanceMethod(NSSavePanel.self, #selector(getter: NSSavePanel.url)) {
            method_setImplementation(method, imp_implementationWithBlock(url))
        }
        let urls: @convention(block) (NSOpenPanel) -> [URL] = { _ in UIHarness.panelURLs ?? [] }
        if let method = class_getInstanceMethod(NSOpenPanel.self, #selector(getter: NSOpenPanel.urls)) {
            method_setImplementation(method, imp_implementationWithBlock(urls))
        }
        let reveal: @convention(block) (NSWorkspace, [URL]) -> Void = { _, urls in UIHarness.opened += urls.map { "reveal " + $0.path } }
        if let method = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.activateFileViewerSelecting(_:))) {
            method_setImplementation(method, imp_implementationWithBlock(reveal))
        }
        let open: @convention(block) (NSWorkspace, URL) -> Bool = { _, url in UIHarness.opened.append("open " + url.absoluteString); return true }
        if let method = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool)) {
            method_setImplementation(method, imp_implementationWithBlock(open))
        }
    }

    nonisolated(unsafe) static var virtualButtons = 0
    nonisolated(unsafe) static var virtualLocation: NSPoint?

    private static func virtualizePointer() {
        let buttons: @convention(block) (AnyObject) -> Int = { _ in UIHarness.virtualButtons }
        if let method = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)) {
            method_setImplementation(method, imp_implementationWithBlock(buttons))
        }
        if let method = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.mouseLocation)) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSPoint
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let location: @convention(block) (AnyObject) -> NSPoint = { object in
                UIHarness.virtualLocation ?? original(object, #selector(getter: NSEvent.mouseLocation))
            }
            method_setImplementation(method, imp_implementationWithBlock(location))
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                        .leftMouseDragged, .mouseMoved, .otherMouseDown, .otherMouseUp]) { event in
            switch event.type {
            case .leftMouseDown: virtualButtons |= 1
            case .leftMouseUp: virtualButtons &= ~1
            case .rightMouseDown: virtualButtons |= 2
            case .rightMouseUp: virtualButtons &= ~2
            default: break
            }
            if let window = event.window { virtualLocation = window.convertPoint(toScreen: event.locationInWindow) }
            return event
        }
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
            return UIHarnessProbe.evaluate(substitute(path), app: app) ?? "nil"
        }
        if step["id"] != nil || step["label"] != nil || step["view"] != nil || step["role"] != nil || step["labelContains"] != nil {
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
        if let expected = step["startsWith"] as? String { guard value.hasPrefix(expected) else { throw Failure("\(describe(step)) = \"\(value.prefix(300))\", expected to start with \"\(expected)\"") } }
        if let minimum = step["atLeast"] as? Double {
            guard let number = Double(value), number >= minimum else { throw Failure("\(describe(step)) = \(value), expected ≥ \(minimum)") }
        }
        if let maximum = step["atMost"] as? Double {
            guard let number = Double(value), number <= maximum else { throw Failure("\(describe(step)) = \(value), expected ≤ \(maximum)") }
        }
    }

    private func describe(_ step: [String: Any]) -> String {
        for key in ["probe", "id", "label", "view", "role"] { if let value = step[key] { return "\(key) \(value)" } }
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
    private func substitute(_ text: String) -> String {
        variables.keys.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: "$" + $1, with: variables[$1]!) }
    }

    private func element(_ raw: [String: Any]) throws -> Element {
        // "$name" in a target's strings is a remembered value.
        var spec = raw
        for key in ["id", "label", "anchor"] { if let text = spec[key] as? String, text.contains("$") { spec[key] = substitute(text) } }
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
        guard identifier != nil || label != nil || role != nil || spec["labelContains"] != nil else { throw Failure("target needs id, label, role or view") }
        var matches: [Element] = []
        for window in candidates {
            walkAccessibility(AXNode(window), depth: 0) { node in
                if let identifier, node.identifier != identifier { return }
                let title = node.label
                let valueString = node.value
                if let label, title != label, valueString != label, node.placeholder != label { return }
                if let partial = spec["labelContains"] as? String, !title.contains(partial), !(valueString ?? "").contains(partial) { return }
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

    private var hovered: [(NSTrackingArea, NSWindow)] = []

    /// Tracking areas fire from the window server's idea of the pointer, which synthesized moves do not change:
    /// send mouseExited / mouseEntered to the owners of the areas the scripted pointer leaves and enters.
    private func hover(_ window: NSWindow, _ point: NSPoint) async {
        var inside: [NSTrackingArea] = []
        if let root = window.contentView?.superview {
            walkViews(root) { view in
                guard !view.isHiddenOrHasHiddenAncestor else { return }
                let local = view.convert(point, from: nil)
                for area in view.trackingAreas where area.options.contains(.mouseEnteredAndExited) {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    if rect.contains(local) { inside.append(area) }
                }
            }
        }
        func send(_ type: NSEvent.EventType, _ area: NSTrackingArea, _ window: NSWindow) {
            eventNumber += 1
            guard let owner = area.owner as? NSResponder,
                  let event = NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                                     trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)
            else { return }
            if type == .mouseEntered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        }
        let left = hovered.filter { old in !inside.contains { $0 === old.0 } }
        let entered = inside.filter { new in !hovered.contains { $0.0 === new } }
        let leftBox = UncheckedBox(left), enteredBox = UncheckedBox(entered), windowBox = UncheckedBox(window)
        await onRunLoop {
            for (area, window) in leftBox.value { send(.mouseExited, area, window) }
            for area in enteredBox.value { send(.mouseEntered, area, windowBox.value) }
        }
        hovered = inside.map { ($0, window) }
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
        let previous = pointer
        pointer = point
        // Built from a CGEvent (never posted to the system) so drags carry deltas, which SwiftUI's DragGesture reads;
        // addressed to the window and queued in this app only.
        let cgType: CGEventType? = switch type {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .leftMouseDragged: .leftMouseDragged
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .mouseMoved: .mouseMoved
        default: nil
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = window.convertPoint(toScreen: point)
        if postMode != "ns", let cgType, let cg = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y),
                                        mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left) {
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            cg.setIntegerValueField(.mouseEventClickState, value: Int64(type == .mouseMoved ? 0 : clicks))
            cg.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if type == .leftMouseDragged || type == .mouseMoved {
                cg.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
                cg.setIntegerValueField(.mouseEventDeltaY, value: Int64((previous.y - point.y).rounded()))
            }
            cg.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseUp || type == .rightMouseUp || type == .mouseMoved ? 0 : 1)
            if let event = NSEvent(cgEvent: cg), event.windowNumber == window.windowNumber {
                if postMode == "send" {
                    let box = UncheckedBox(event)
                    DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.sendEvent(box.value) } }
                } else {
                    NSApp.postEvent(event, atStart: false)
                }
                return
            }
        }
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
        "n": 45, "m": 46, ".": 47, "`": 50, "+": 24, "_": 27, "?": 44, ":": 41, "\"": 39, "!": 18, "@": 19, "(": 25, ")": 29, "*": 28,
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
        if characters.count == 1, let scalar = characters.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) || "+_?:\"!@()*".unicodeScalars.contains(scalar) { flags.insert(.shift) }
        let ignoring = flags.contains(.shift) ? characters : characters.lowercased()
        if flags.contains(.option), key.count == 1 { characters = key }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            eventNumber += 1
            // A CGEvent-backed key event (never posted to the system), like a real keystroke: SwiftUI's menu-bar
            // commands only matched those. Its text is set explicitly, so the keyboard layout does not matter.
            if code != 0 || characters == "a", let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown) {
                cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                let utf16 = Array(characters.utf16)
                cg.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                if let event = NSEvent(cgEvent: cg), event.characters == characters {
                    if !flags.intersection([.command, .control]).isEmpty {
                        // Shortcuts are dispatched the way NSApplication does for a keystroke from the window server:
                        // the key window's views, then the menu bar, then the window. (Queued events reached the
                        // window but never the menu bar's key equivalents.)
                        guard type == .keyDown else { continue }
                        // NSEvent-made: SwiftUI's menu items did not match the CGEvent-backed one.
                        let plain = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: event.timestamp,
                                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                                     charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) ?? event
                        let box = UncheckedBox((plain, window))
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                let (event, window) = box.value
                                // A background app's menu bar is not kept current by SwiftUI (it is not on screen):
                                // bring it up to date first, as it is for the active app a person types into.
                                for item in NSApp.mainMenu?.items ?? [] {
                                    guard let submenu = item.submenu else { continue }
                                    submenu.delegate?.menuNeedsUpdate?(submenu)
                                    submenu.update()
                                }
                                let byWindow = window.performKeyEquivalent(with: event)
                                let byMenu = byWindow ? false : NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                                if !byWindow && !byMenu { window.sendEvent(event) }
                                if ProcessInfo.processInfo.environment["BUNNYGRID_UI_TRACE"] != nil {
                                    FileHandle.standardError.write(Data("[ui-trace] shortcut \(event.charactersIgnoringModifiers ?? "") window=\(byWindow) menu=\(byMenu)\n".utf8))
                                }
                            }
                        }
                        continue
                    }
                    deliverKey(event, to: window)
                    continue
                }
            }
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) {
                deliverKey(event, to: window)
            }
        }
    }

    /// A click on a text view in a window that is not really key (the app is in the background) does not always make
    /// it first responder: do it, as the click would have.
    private func focusText(at point: NSPoint, in window: NSWindow) {
        guard !(window.firstResponder is NSText) else { return }
        let hit = window.contentView?.superview?.hitTest(point)
        var candidates: [NSView] = []
        if let clip = hit as? NSClipView, let document = clip.documentView { candidates.append(document) }
        if let scroll = hit as? NSScrollView, let document = scroll.documentView { candidates.append(document) }
        var view = hit
        while let current = view { candidates.append(current); view = current.superview }
        if let text = candidates.first(where: { $0 is NSTextView || $0 is NSTextField }) { window.makeFirstResponder(text) }
    }

    /// Keystrokes go straight to the window (its first responder), in order, from the run loop: NSApp sends queued
    /// key events to its key window, and a background app has none.
    private func deliverKey(_ event: NSEvent, to window: NSWindow) {
        let box = UncheckedBox((event, window))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let (event, window) = box.value
                window.sendEvent(event)
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

    /// Pinch. On a magnifying NSScrollView it does what a trackpad pinch does there: will-start notification,
    /// magnification changed in steps around the point, did-end notification (which views listen to, to keep
    /// their zoom). Elsewhere a magnify gesture event (built from a CGEvent, never posted) goes to the view.
    private func magnify(_ window: NSWindow, _ point: NSPoint, amount: Double) {
        let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        var view = hit
        while let current = view, !((current as? NSScrollView)?.allowsMagnification ?? false) { view = current.superview }
        if let scrollView = view as? NSScrollView {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
            let start = scrollView.magnification
            for step in 1...4 {
                let center = scrollView.contentView.convert(point, from: nil)
                scrollView.setMagnification(start * (1 + amount * Double(step) / 4), centeredAt: center)
            }
            NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
            return
        }
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
        logs.append("magnify: no magnifiable view at \(point)")
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
        // The action is sent while the menu is still up, then the menu closes: what the menu's owner set up for it
        // (NSTableView's clickedRow, for one) is still in place, as when a person picks the item.
        await onRunLoop {
            owner.performActionForItem(at: index)
            root.cancelTrackingWithoutAnimation()
        }
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
        // What `.draggable(String)` / NSString writers put on a drag pasteboard.
        let textTypes = [NSPasteboard.PasteboardType.string, .init("public.plain-text"), .init("public.text"), .init("public.utf16-plain-text")]
        pasteboard.declareTypes(textTypes, owner: nil)
        for type in textTypes { pasteboard.setString(payload, forType: type) }
        let info = HarnessDraggingInfo(window: window, location: point, pasteboard: pasteboard)
        let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        let types = Set(pasteboard.types ?? [.string])
        // The innermost AppKit view registered for a type on the pasteboard; otherwise the window, which routes the
        // drag to SwiftUI's drop destinations (they do not register types per view).
        var view = hit
        while let current = view, !current.registeredDraggedTypes.contains(where: types.contains) { view = current.superview }
        // SwiftUI's drop targets are `_PlatformDraggingDestinationView`s that hit testing skips and that register
        // parent types (public.data): like AppKit, take the frontmost view under the point whose registered types
        // the pasteboard's types conform to, before falling back to the hit-test chain.
        let pasteboardUTTypes = types.compactMap { UTType($0.rawValue) }
        var registered: NSView?
        if let root = window.contentView?.superview {
            walkViews(root) { candidate in
                guard !candidate.isHiddenOrHasHiddenAncestor, !candidate.registeredDraggedTypes.isEmpty,
                      candidate.convert(candidate.bounds, to: nil).contains(point),
                      candidate.registeredDraggedTypes.contains(where: { accepted in
                          types.contains(accepted) || UTType(accepted.rawValue).map { want in pasteboardUTTypes.contains { $0.conforms(to: want) } } == true
                      }) else { return }
                registered = candidate
            }
        }
        if let registered, view == nil || registered.isDescendant(of: view!) || !(view!.isDescendant(of: registered)) { view = registered }
        let destination: NSDraggingDestination = view.map { $0 as NSDraggingDestination } ?? (window as NSDraggingDestination)
        let name = String(describing: type(of: destination))
        let entered = await onRunLoop { destination.draggingEntered?(info) ?? [] }
        info.lastOperation = entered
        try await drain(ms: 30)
        var updated = entered
        for offset in [1.0, 0.0] {
            info.location = NSPoint(x: point.x + offset, y: point.y)
            updated = await onRunLoop { destination.draggingUpdated?(info) ?? entered }
            info.lastOperation = updated
            try await drain(ms: 30)
        }
        guard updated != [] else {
            await onRunLoop { destination.draggingExited?(info) }
            throw Failure("\(name) refused the drop of \(payload) at \(point) (over \(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
        }
        let accepted = await onRunLoop {
            if destination.prepareForDragOperation?(info) == false { return false }
            let accepted = destination.performDragOperation?(info) ?? false
            destination.concludeDragOperation?(info)
            destination.draggingEnded?(info)
            return accepted
        }
        guard accepted else { throw Failure("\(name) did not accept \(payload)") }
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
        logs.append("screenshot \(name): \(main.identifier?.rawValue ?? "?") \(Int(main.frame.width))x\(Int(main.frame.height)) of [\(NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? String(describing: type(of: $0))) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))]")
        let path = capture(main, as: name)
        if let sheet = main.attachedSheet { _ = capture(sheet, as: name + "-sheet") }
        for other in windows where other !== main && !other.isSheet && other.level == .normal {
            _ = capture(other, as: name + "-" + (other.title.isEmpty ? "window" : other.title.lowercased().replacingOccurrences(of: " ", with: "-")))
        }
        return path
    }

    /// Every sampled pixel the same colour.
    private static func isBlank(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard rep.pixelsWide > 8, rep.pixelsHigh > 8, let first = rep.colorAt(x: 4, y: 4) else { return true }
        for i in 1..<64 {
            let x = (i * 37) % rep.pixelsWide, y = (i * 53) % rep.pixelsHigh
            if let color = rep.colorAt(x: x, y: y), color != first { return false }
        }
        return true
    }

    private func capture(_ window: NSWindow, as name: String) -> String? {
        var image: CGImage?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // .optionIncludingWindow; .boundsIgnoreFraming | .bestResolution: only this window, never what is behind it.
            image = function(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
        }
        // A locked or sleeping screen gives a blank (uniform) capture: draw the window ourselves instead.
        if (image?.width ?? 0) < 4 || image.map(Self.isBlank) == true, let view = window.contentView?.superview ?? window.contentView,
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

@MainActor @Observable
final class HarnessGestureProbe {
    var changed: [String: Int] = [:]
    var ended: [String: Int] = [:]
    var taps: [String: Int] = [:]
}

private struct HarnessGestureView: View {
    let probe: HarnessGestureProbe

    var body: some View {
        VStack(spacing: 0) {
            target("plain").frame(height: 200)
            ScrollView { target("scroll").frame(height: 200) }.frame(height: 200)
        }
    }

    private func target(_ name: String) -> some View {
        Color.blue.opacity(0.3)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { _ in probe.changed[name, default: 0] += 1 }
                .onEnded { _ in probe.ended[name, default: 0] += 1 })
            .onTapGesture { probe.taps[name, default: 0] += 1 }
    }
}

/// NSWindow implements the dragging-destination methods (it routes a drag to the view under it, SwiftUI's drop
/// destinations included); the requirements are all optional, so they are sent only when implemented.
extension NSWindow: @retroactive NSDraggingDestination {}

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
        // Items read back from the pasteboard as the classes asked for (NSPasteboardItem, NSString, …).
        let objects = pasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            let item = NSDraggingItem(pasteboardWriter: writer)
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    /// The operation the destination last answered (AppKit's private bookkeeping, which SwiftUI reads).
    var lastOperation: NSDragOperation = []
    @objc func _lastDragDestinationOperation() -> UInt { lastOperation.rawValue }
    @objc func _setLastDragDestinationOperation(_ value: UInt) { lastOperation = NSDragOperation(rawValue: value) }
    func resetSpringLoading() {}
}
#endif
