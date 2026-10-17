import Foundation

/// Keeps a data file that could not be read: it is moved aside (next to it, with a timestamp) before the app
/// starts from an empty list, so the next save can't overwrite the user's connections, queries or history.
public enum StoreQuarantine {
    /// Loads with `load`; on failure moves `fileURL` aside and returns the empty list plus a message for the user.
    public static func load<Element>(_ fileURL: URL, now: Date = Date(),
                                     _ load: () throws -> [Element]) -> (elements: [Element], problem: String?) {
        do {
            return (try load(), nil)
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], nil) }
            let moved = quarantine(fileURL, now: now)
            let name = fileURL.lastPathComponent
            let message = moved.map { "\(name) could not be read (\(error.localizedDescription)). It was kept as \($0.lastPathComponent)." }
                ?? "\(name) could not be read (\(error.localizedDescription))."
            return ([], message)
        }
    }

    /// Moves the file to `name.unreadable-<yyyyMMdd-HHmmss>.ext`; nil when it can't be moved.
    @discardableResult
    public static func quarantine(_ fileURL: URL, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        var target = fileURL.deletingLastPathComponent()
            .appending(path: "\(base).unreadable-\(formatter.string(from: now))\(ext.isEmpty ? "" : "." + ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            suffix += 1
            target = fileURL.deletingLastPathComponent()
                .appending(path: "\(base).unreadable-\(formatter.string(from: now))-\(suffix)\(ext.isEmpty ? "" : "." + ext)")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            return target
        } catch {
            return nil
        }
    }
}
