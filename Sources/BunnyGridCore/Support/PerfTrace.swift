import Foundation
import os

/// Timing instrumentation: os_signpost intervals (Instruments › Points of Interest) and, when
/// `BUNNYGRID_PERF_LOG` names a file, one line per measurement (`name<TAB>milliseconds<TAB>detail`).
/// Cheap when no one is recording: the signposter is disabled outside Instruments and the log is off.
public enum PerfTrace {
    public static let signposter = OSSignposter(subsystem: "app.bunnygrid.BunnyGrid", category: .pointsOfInterest)

    private static let logFile: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["BUNNYGRID_PERF_LOG"], !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static let lock = OSAllocatedUnfairLock()

    /// Whether `BUNNYGRID_PERF_LOG` is set, so callers can skip building details.
    public static var isLogging: Bool { logFile != nil }

    /// Monotonic time in nanoseconds.
    @inline(__always)
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Milliseconds since `start` (from `now()`).
    @inline(__always)
    public static func milliseconds(since start: UInt64) -> Double { Double(now() &- start) / 1_000_000 }

    /// Runs `body` inside a signpost interval and logs its duration.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = now()
        defer {
            signposter.endInterval(name, state)
            if isLogging { record("\(name)", milliseconds: milliseconds(since: start)) }
        }
        return try body()
    }

    /// Async variant of `measure`.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = now()
        defer {
            signposter.endInterval(name, state)
            if isLogging { record("\(name)", milliseconds: milliseconds(since: start)) }
        }
        return try await body()
    }

    /// Writes one measurement to the log file (no-op without `BUNNYGRID_PERF_LOG`).
    public static func record(_ name: String, milliseconds: Double, detail: String = "") {
        guard let logFile else { return }
        let line = "\(name)\t\(String(format: "%.3f", milliseconds))\t\(detail)\n"
        lock.withLock { logFile.write(Data(line.utf8)) }
    }

    /// A signpost event (a point in time) with a message.
    public static func event(_ name: StaticString, _ message: String = "") {
        signposter.emitEvent(name, "\(message)")
    }
}
