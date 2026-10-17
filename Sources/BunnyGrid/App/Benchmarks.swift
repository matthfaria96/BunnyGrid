#if DEBUG || BUNNYGRID_BENCH
import AppKit
import BunnyGridCore
import QuartzCore

/// Watches the main run loop: how long each busy stretch (wake → sleep) takes, and lets the
/// benchmarks wait for the next moment the main thread goes idle (everything laid out and committed).
@MainActor
final class RunLoopMonitor {
    static let shared = RunLoopMonitor()

    private var busySince: UInt64 = 0
    private var observers: [CFRunLoopObserver] = []
    private var idleWaiters: [CheckedContinuation<UInt64, Never>] = []
    /// Busy stretches (milliseconds) recorded while `isRecording`.
    private(set) var stretches: [Double] = []
    var isRecording = false {
        didSet { if isRecording { stretches = [] } }
    }

    func install() {
        guard observers.isEmpty else { return }
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { RunLoopMonitor.shared.busySince = PerfTrace.now() }
        }
        // Last observer before sleeping: after Core Animation's commit, so drawing is included.
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { RunLoopMonitor.shared.willSleep() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        busySince = PerfTrace.now()
    }

    private func willSleep() {
        let now = PerfTrace.now()
        if isRecording, busySince > 0 { stretches.append(Double(now &- busySince) / 1_000_000) }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume(returning: now) }
    }

    /// The time at which the main thread next goes to sleep.
    func nextIdle() async -> UInt64 {
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Waits until the main thread has been idle twice in a row with a pause between, i.e. settled.
    func settle(pause: Duration = .milliseconds(30)) async -> UInt64 {
        _ = await nextIdle()
        try? await Task.sleep(for: pause)
        return await nextIdle()
    }
}

/// `--bench SCENARIO`: scripted actions that time what the user feels, written to `BUNNYGRID_PERF_LOG`
/// (and stderr), then quit. Scenarios: launch, connect, expand, objects, open-table, scroll, resize,
/// tabs, typing, autocomplete, query100k, er. Datasets: a SQLite file with a 1M-row, 20-column `events`
/// table (open-table, scroll, resize, typing, query100k), one with 2,000 tables (expand, objects, tabs),
/// one with 200 related tables (er); `--bench-script FILE` is the 20,000-line script for the editor.
/// Built into release with `swift build -c release -Xswiftc -DBUNNYGRID_BENCH`.
@MainActor
enum Benchmarks {
    static var scenario: String? {
        CommandLine.arguments.firstIndex(of: "--bench").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }

    static func argument(_ flag: String) -> String? {
        CommandLine.arguments.firstIndex(of: flag).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }

    weak static var app: AppModel?

    /// Wall-clock seconds since the process started (kinfo_proc).
    static var secondsSinceProcessStart: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    static func report(_ name: String, _ ms: Double, _ detail: String = "") {
        PerfTrace.record(name, milliseconds: ms, detail: detail)
        FileHandle.standardError.write(Data("[bench] \(name) \(String(format: "%.2f", ms)) ms \(detail)\n".utf8))
    }

    /// Mean / p95 / max of busy stretches and how many missed a 60 Hz or 120 Hz frame.
    static func reportStretches(_ name: String, _ values: [Double], frames: Int? = nil) {
        guard !values.isEmpty else { return report(name, 0, "no samples"); }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let over8 = values.filter { $0 > 8.33 }.count
        let over16 = values.filter { $0 > 16.7 }.count
        let over50 = values.filter { $0 > 50 }.count
        var detail = String(format: "n=%d mean=%.2f p95=%.2f max=%.2f >8.3ms=%d >16.7ms=%d >50ms=%d", values.count, mean, p95, sorted.last!, over8, over16, over50)
        if let frames { detail += " frames=\(frames)" }
        report(name, p95, detail)
    }

    static func start() {
        guard let scenario else { return }
        RunLoopMonitor.shared.install()
        Task {
            // First frame: the window is on screen and the main thread went idle once.
            while !NSApp.windows.contains(where: { $0.isVisible && $0.contentView != nil }) {
                _ = await RunLoopMonitor.shared.nextIdle()
            }
            _ = await RunLoopMonitor.shared.nextIdle()
            report("launch.firstFrame", secondsSinceProcessStart * 1_000)
            _ = await RunLoopMonitor.shared.settle(pause: .milliseconds(200))
            report("launch.settled", secondsSinceProcessStart * 1_000)
            await run(scenario)
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    static func waitFor(_ timeout: Duration = .seconds(120), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    static func openContext() async -> DatabaseContext? {
        guard let app else { return nil }
        await waitFor { app.sessions.values.first?.context("main")?.isOpen == true }
        return app.sessions.values.first?.context("main")
    }

    static func views<T: NSView>(_ type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        for window in NSApp.windows where window.isVisible { if let content = window.contentView { walk(content) } }
        return found
    }

    /// Times `action` until the main thread is idle again.
    static func timeToIdle(_ name: String, detail: String = "", _ action: () -> Void) async -> Double {
        _ = await RunLoopMonitor.shared.settle()
        let start = PerfTrace.now()
        action()
        let end = await RunLoopMonitor.shared.nextIdle()
        let ms = Double(end &- start) / 1_000_000
        report(name, ms, detail)
        return ms
    }

    /// Calls `step` on every display frame for `duration`, recording the main thread's busy stretches
    /// and the frame-to-frame intervals (a hitch is an interval well over the display's period).
    static func driveFrames(_ name: String, duration: Duration, step: @escaping (Int) -> Void) async {
        guard let window = NSApp.windows.first(where: \.isVisible), let view = window.contentView else { return }
        let driver = FrameDriver(step: step)
        RunLoopMonitor.shared.isRecording = true
        let link = view.displayLink(target: driver, selector: #selector(FrameDriver.tick(_:)))
        link.add(to: .main, forMode: .common)
        var timer: Timer?
        try? await Task.sleep(for: .milliseconds(150))
        if driver.frames == 0 {
            // No display link callbacks (window not on an active display): fall back to a 120 Hz timer.
            link.invalidate()
            let fallback = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { driver.timerTick() } }
            RunLoop.main.add(fallback, forMode: .common)
            timer = fallback
        }
        try? await Task.sleep(for: duration)
        link.invalidate()
        timer?.invalidate()
        RunLoopMonitor.shared.isRecording = false
        reportStretches("\(name).mainBusy", RunLoopMonitor.shared.stretches, frames: driver.frames)
        let period = driver.period > 0 ? driver.period * 1_000 : 16.67
        let intervals = driver.intervals
        let hitches = intervals.filter { $0 > period * 1.5 }
        let hitchTime = hitches.reduce(0) { $0 + ($1 - period) }
        let total = intervals.reduce(0, +)
        report("\(name).hitchRatio", total > 0 ? hitchTime / (total / 1_000) : 0,
               String(format: "ms-per-s; period=%.2fms frames=%d hitches=%d worst=%.1fms", period, intervals.count, hitches.count, intervals.max() ?? 0))
    }

    @MainActor final class FrameDriver: NSObject {
        let step: (Int) -> Void
        var frames = 0
        var last: CFTimeInterval = 0
        var period: CFTimeInterval = 0
        var intervals: [Double] = []

        init(step: @escaping (Int) -> Void) { self.step = step }

        @objc func tick(_ link: CADisplayLink) {
            if last > 0 { intervals.append((link.timestamp - last) * 1_000) }
            last = link.timestamp
            period = link.targetTimestamp - link.timestamp
            step(frames)
            frames += 1
        }

        func timerTick() {
            let now = CACurrentMediaTime()
            if last > 0 { intervals.append((now - last) * 1_000) }
            last = now
            period = 1.0 / 120
            step(frames)
            frames += 1
        }
    }

    /// Sends a key press through the window, as typing does.
    static func type(_ characters: String, in window: NSWindow) {
        for character in characters {
            let string = String(character)
            let keyCode: UInt16 = character == "\n" ? 36 : 0
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: character == "\n" ? "\r" : string,
                                                charactersIgnoringModifiers: character == "\n" ? "\r" : string, isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                }
            }
        }
    }

    // MARK: - Scenarios

    static func run(_ scenario: String) async {
        guard let app else { return }
        switch scenario {
        case "launch":
            break

        case "connect":
            // The connection was opened from the command line; Session/DatabaseContext log their own timings.
            let start = PerfTrace.now()
            _ = await openContext()
            report("connect.untilOpen", PerfTrace.milliseconds(since: start), "after first frame")

        case "expand":
            guard let context = await openContext(), let id = context.session?.id else { return }
            app.expanded.insert(.database(id, "main"))
            let node = NavNode.category(id, "main", nil, .tables)
            _ = await timeToIdle("navigator.expand", detail: "\(context.objects(in: nil)?.count ?? 0) tables") { app.setExpanded(node, true) }
            if CommandLine.arguments.contains("--bench-hot"), let objects = context.objects(in: nil) {
                for index in 0..<300 {
                    app.navSelection = .object(id, "main", objects[index % 20])
                    _ = await RunLoopMonitor.shared.nextIdle()
                }
            }
            if let object = context.objects(in: nil)?[10] {
                _ = await timeToIdle("navigator.selectRow") { app.navSelection = .object(id, "main", object) }
            }
            _ = await timeToIdle("navigator.unrelatedChange") { app.listedItemCount += 1 }
            var filter = ""
            var samples: [Double] = []
            for character in "table_19" {
                filter.append(character)
                let value = filter
                samples.append(await timeToIdle("navigator.filterKeystroke", detail: value) { app.navigatorFilter = value })
            }
            reportStretches("navigator.filter", samples)
            app.navigatorFilter = ""
            _ = await timeToIdle("navigator.collapse") { app.setExpanded(node, false) }

        case "objects":
            guard let context = await openContext(), let id = context.session?.id else { return }
            app.expanded.insert(.database(id, "main"))
            _ = await timeToIdle("objects.show", detail: "\(context.objects(in: nil)?.count ?? 0) tables") {
                app.select(.category(id, "main", nil, .tables))
            }
            try? await Task.sleep(for: .milliseconds(500))
            _ = await RunLoopMonitor.shared.settle()
            // Typing in the Objects search field (the right-hand "Search" field).
            let fields = views(NSTextField.self).filter { $0.placeholderString == "Search" }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            if let field = fields.last, let window = field.window {
                window.makeFirstResponder(field)
                var samples: [Double] = []
                for character in "table_19" {
                    samples.append(await timeToIdle("objects.searchKeystroke", detail: String(character)) { type(String(character), in: window) })
                }
                reportStretches("objects.search", samples)
            }

        case "open-table", "scroll", "resize":
            guard let context = await openContext(), let object = context.objects(in: nil)?.first(where: { $0.name == (argument("--bench-table") ?? "events") }) else { return }
            let start = PerfTrace.now()
            app.openTable(object, in: context)
            guard let tab = app.selectedTableTab else { return }
            await waitFor { tab.page != nil && !tab.isLoading }
            let loaded = PerfTrace.milliseconds(since: start)
            let end = await RunLoopMonitor.shared.nextIdle()
            report("table.open", Double(end &- start) / 1_000_000, String(format: "page loaded at %.1f ms, %d rows", loaded, tab.page?.rows.count ?? 0))
            try? await Task.sleep(for: .milliseconds(300))
            guard let grid = views(GridTableView.self).last, let scroll = grid.enclosingScrollView else { return }
            if scenario == "scroll" { await scrollGrid(grid, scroll: scroll, name: "grid") }
            if scenario == "resize" { await resizeColumns(grid) }

        case "tabs":
            guard let context = await openContext(), let objects = context.objects(in: nil) else { return }
            for object in objects.prefix(4) {
                app.openTable(object, in: context)
                if let tab = app.selectedTableTab { await waitFor { tab.page != nil } }
            }
            let script = (try? String(contentsOfFile: argument("--bench-script") ?? "", encoding: .utf8)) ?? ""
            app.openQuery(text: script, in: context)
            app.openQuery(text: "SELECT * FROM \(objects[0].name);", in: context)
            _ = await RunLoopMonitor.shared.settle(pause: .milliseconds(500))
            let ids = app.tabs.map(\.id) + [nil]
            var samples: [Double] = []
            if CommandLine.arguments.contains("--bench-hot") {
                for index in 0..<200 {
                    app.selectedTabID = ids[index % ids.count]
                    _ = await RunLoopMonitor.shared.nextIdle()
                }
            }
            for round in 0..<3 {
                for id in ids {
                    samples.append(await timeToIdle("tabs.switch", detail: "round \(round)") { app.selectedTabID = id })
                }
            }
            reportStretches("tabs.switchAll", samples)

        case "typing", "autocomplete":
            guard let context = await openContext() else { return }
            let script = (try? String(contentsOfFile: argument("--bench-script") ?? "", encoding: .utf8)) ?? "SELECT 1;"
            let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
            let openStart = PerfTrace.now()
            _ = await timeToIdle("editor.open", detail: "\(lines) lines") { app.openQuery(text: script, in: context) }
            if let editor = views(SQLTextView.self).last {
                await waitFor { editor.colouredUpTo >= (editor.string as NSString).length || editor.colouredUpTo == 0 }
                report("editor.colouredAll", PerfTrace.milliseconds(since: openStart), "chunked colouring finished")
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard let editor = views(SQLTextView.self).last, let window = editor.window else { return }
            window.makeFirstResponder(editor)
            // Cursor at the middle line.
            let string = editor.string as NSString
            var location = 0
            for _ in 0..<(lines / 2) { location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0))) }
            editor.setSelectedRange(NSRange(location: location, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            _ = await RunLoopMonitor.shared.settle(pause: .milliseconds(300))
            if CommandLine.arguments.contains("--bench-hot") {
                // Back-to-back keystrokes for a profiler to sample.
                for index in 0..<400 {
                    type(index % 2 == 1 ? "\n" : "x", in: window)
                    _ = await RunLoopMonitor.shared.nextIdle()
                }
            }
            if scenario == "typing" {
                var samples: [Double] = []
                for character in "select name, email from events where id = 42 and status = 'paid';\n" {
                    samples.append(await timeToIdle("editor.keystroke") { type(String(character), in: window) })
                }
                reportStretches("editor.typing", samples)
                // Opening a block comment recolours everything after it, then closing it again.
                _ = await timeToIdle("editor.openBlockComment") { type("/*", in: window) }
                _ = await timeToIdle("editor.closeBlockComment") { type("*/", in: window) }
                // Scrolling the editor (line numbers, lazy layout).
                if let scroll = editor.enclosingScrollView {
                    let height = editor.bounds.height
                    await driveFrames("editor.scroll", duration: .seconds(2)) { frame in
                        let y = CGFloat(frame * 240).truncatingRemainder(dividingBy: max(height - scroll.contentSize.height, 1))
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
            } else {
                type("\nselect * from events e where e", in: window)
                _ = await RunLoopMonitor.shared.settle()
                var samples: [Double] = []
                for _ in 0..<5 {
                    // "." opens the completion popup, which runs its own event loop until dismissed: a common-mode
                    // timer notes when the popup window is on screen, then queues an Escape to close it.
                    let start = PerfTrace.now()
                    var shown: Double?
                    let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                    let watcher = Timer(timeInterval: 0.001, repeats: true) { timer in
                        nonisolated(unsafe) let timer = timer
                        MainActor.assumeIsolated {
                            guard NSApp.windows.contains(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) }) else {
                                if PerfTrace.milliseconds(since: start) > 3_000 { timer.invalidate() }
                                return
                            }
                            shown = PerfTrace.milliseconds(since: start)
                            timer.invalidate()
                            if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                                NSApp.postEvent(escape, atStart: false)
                            }
                        }
                    }
                    RunLoop.main.add(watcher, forMode: .common)
                    type(".", in: window)
                    watcher.invalidate()
                    if let shown { samples.append(shown); report("editor.completionPopup", shown) }
                    editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    _ = await RunLoopMonitor.shared.settle(pause: .milliseconds(150))
                }
                reportStretches("editor.completion", samples)
            }

        case "query100k":
            guard let context = await openContext() else { return }
            let rows = Int(argument("--bench-rows") ?? "") ?? 100_000
            app.openQuery(text: "SELECT * FROM events LIMIT \(rows)", in: context)
            guard let tab = app.selectedQueryTab else { return }
            _ = await RunLoopMonitor.shared.settle(pause: .milliseconds(300))
            var start = PerfTrace.now()
            tab.run()
            await waitFor { !tab.isRunning && (tab.selectedResult != nil || tab.error != nil) }
            var end = await RunLoopMonitor.shared.nextIdle()
            report("query.firstPage", Double(end &- start) / 1_000_000, "\(tab.selectedResult?.rows.count ?? 0) rows \(tab.error ?? "") text=\(tab.text.count)")
            guard let first = tab.selectedResult else { return }
            start = PerfTrace.now()
            tab.fetchAll(first)
            await waitFor { !tab.isRunning && tab.selectedResult?.id != first.id }
            let fetched = PerfTrace.milliseconds(since: start)
            end = await RunLoopMonitor.shared.nextIdle()
            report("query.fetchAll", Double(end &- start) / 1_000_000,
                   String(format: "%d rows, data at %.1f ms, driver %.1f ms", tab.selectedResult?.rows.count ?? 0, fetched, tab.selectedResult?.duration.milliseconds ?? 0))
            try? await Task.sleep(for: .milliseconds(300))
            if let grid = views(GridTableView.self).last, let scroll = grid.enclosingScrollView {
                await scrollGrid(grid, scroll: scroll, name: "resultGrid")
            }

        case "er":
            guard let context = await openContext() else { return }
            let start = PerfTrace.now()
            app.openModel(in: context, schema: nil)
            guard case .model(let model) = app.selectedTab else { return }
            await waitFor { model.model != nil && !model.isLoading }
            let loaded = PerfTrace.milliseconds(since: start)
            let end = await RunLoopMonitor.shared.nextIdle()
            report("er.open", Double(end &- start) / 1_000_000, String(format: "%d tables, model read at %.1f ms", model.model?.tables.count ?? 0, loaded))
            _ = await timeToIdle("er.select") { model.selection = model.model?.tables[100].name }
            _ = await timeToIdle("er.zoom") { model.setZoom(0.5) }
            if let table = model.model?.tables[50].name, let origin = model.positions[table] {
                await driveFrames("er.drag", duration: .seconds(1)) { frame in
                    model.move(table, to: CGPoint(x: origin.x + CGFloat(frame * 3), y: origin.y + CGFloat(frame * 2)))
                }
            }

        default:
            report("unknown-scenario", 0, scenario)
        }
    }

    static func scrollGrid(_ grid: NSTableView, scroll: NSScrollView, name: String) async {
        let maxY = max(grid.bounds.height - scroll.contentSize.height, 1)
        // A fast fling: 180 pt per frame down the whole page and back.
        await driveFrames("\(name).scrollVertical", duration: .seconds(3)) { frame in
            var y = CGFloat(frame * 180).truncatingRemainder(dividingBy: maxY * 2)
            if y > maxY { y = maxY * 2 - y }
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y - (grid.headerView?.frame.height ?? 0)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let maxX = max(grid.bounds.width - scroll.contentSize.width, 1)
        await driveFrames("\(name).scrollHorizontal", duration: .seconds(2)) { frame in
            var x = CGFloat(frame * 60).truncatingRemainder(dividingBy: maxX * 2)
            if x > maxX { x = maxX * 2 - x }
            scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    static func resizeColumns(_ grid: NSTableView) async {
        guard grid.tableColumns.count > 3 else { return }
        let column = grid.tableColumns[2]
        let base = column.width
        await driveFrames("grid.resizeColumn", duration: .seconds(2)) { frame in
            column.width = base + CGFloat((frame % 60) * 4)
        }
    }
}
#endif
