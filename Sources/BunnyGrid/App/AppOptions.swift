import AppKit
import Observation
import SwiftUI

/// Everything in the Options window (Navicat's Settings), saved as one JSON value in UserDefaults.
/// The window edits a draft copy; OK saves it, Cancel drops it.
struct OptionsValues: Codable, Equatable {
    enum StartupTabs: String, Codable, CaseIterable { case objectsOnly, continueWhereLeft }
    enum OpenTabsIn: String, Codable, CaseIterable { case mainWindow, newWindow }
    enum RowShading: String, Codable, CaseIterable {
        case none, everyOtherRow, everyThirdRow

        var title: String {
            switch self {
            case .none: "None"
            case .everyOtherRow: "Every Other Row"
            case .everyThirdRow: "Every Third Row"
            }
        }
    }
    enum Autosave: Int, Codable, CaseIterable {
        case never = 0, seconds30 = 30, minute1 = 60, minutes3 = 180, minutes5 = 300

        var title: String {
            switch self {
            case .never: "Never"
            case .seconds30: "Every 30 seconds"
            case .minute1: "Every minute"
            case .minutes3: "Every 3 minutes"
            case .minutes5: "Every 5 minutes"
            }
        }
    }

    // General
    var showObjectsUnderSchema = true
    var objectListFont: FontSpec?
    var useSafeConfirmDialog = true
    var askToSaveNewQueries = true

    // Tabs
    var startupTabs: StartupTabs = .objectsOnly
    var openTabsIn: OpenTabsIn = .mainWindow
    var allowMultipleForms = false
    var alwaysShowTabBar = true

    // Code Completion
    var useCodeCompletion = true
    var autoSelectFirstSuggestion = false
    /// Load the columns of tables named in the editor in the background.
    var autoUpdateCompletionInfo = true
    /// Offer pg_catalog / information_schema / sqlite_* objects in completion.
    var includeSystemObjectsInCompletion = true

    // Editor
    var disableHighlightAboveMB = 10
    var showLineNumbers = true
    var useBraceHighlighting = true
    var useSyntaxHighlighting = true
    var insertSpacesForTab = false
    var tabWidth = 2
    var wordWrap = false
    var editorFont: FontSpec?
    var syntaxColors = SyntaxColors()

    // Records
    var limitRecords = true
    var recordsPerPage = 1_000
    var autoBeginTransaction = false
    var gridFont: FontSpec?
    var rowShading: RowShading = .everyThirdRow
    var profilingColors = ProfilingColors()

    // Auto Recovery
    var autosaveQueries: Autosave = .seconds30

    // AI (the assistants themselves live in AssistantModel)
    var askAILanguage = "Auto"

    // Advanced
    var diagnosticLogging = false
}

/// Records › Data Profiling Colors: frequency bars, the highlighted value, and the Not Null / valid meter.
struct ProfilingColors: Codable, Equatable {
    var bar = "#1FB5C9"
    var spotlight = "#E58FE3"
    var valid = "#5AC8FA"
}

/// A font chosen in Options; nil anywhere means "Use default font".
struct FontSpec: Codable, Equatable {
    var name: String
    var size: Double

    var nsFont: NSFont? { NSFont(name: name, size: size) }
    var label: String { "\(NSFont(name: name, size: CGFloat(size))?.displayName ?? name) \(String(format: "%.1f", size))" }
}

/// Editor colors as hex strings; nil uses the system color for the current appearance.
struct SyntaxColors: Codable, Equatable {
    var common: String?
    var keyword: String?
    var comment: String?
    var string: String?
    var number: String?
    var background: String?
}

@MainActor
@Observable
final class AppOptions {
    static let shared = AppOptions()

    private(set) var values: OptionsValues

    private init() {
        if let data = UserDefaults.standard.data(forKey: "appOptions"), let saved = Self.decode(data) {
            values = saved
        } else {
            values = OptionsValues()
        }
    }

    /// Saved options over the defaults, so options added in a later version don't reset the user's others.
    static func decode(_ data: Data) -> OptionsValues? {
        if let values = try? JSONDecoder().decode(OptionsValues.self, from: data) { return values }
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(OptionsValues())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new })
        else { return nil }
        return try? JSONDecoder().decode(OptionsValues.self, from: merged)
    }

    func save(_ newValues: OptionsValues) {
        guard newValues != values else { return }
        values = newValues
        UserDefaults.standard.set(try? JSONEncoder().encode(newValues), forKey: "appOptions")
        NotificationCenter.default.post(name: .optionsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let optionsDidChange = Notification.Name("BunnyGridOptionsDidChange")
}

extension NSColor {
    /// Default SQL keyword color, as in Navicat's editor: light blue in dark mode, blue in light mode.
    static let navicatKeyword = NSColor(name: "navicatKeyword") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.71, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.33, blue: 0.85, alpha: 1)
    }
    /// Default SQL string color: pink in dark mode, red in light mode.
    static let navicatString = NSColor(name: "navicatString") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.53, alpha: 1)
            : NSColor(srgbRed: 0.77, green: 0.10, blue: 0.16, alpha: 1)
    }

    convenience init?(hex: String?) {
        guard var hex, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}

/// Options › Advanced › "Enable diagnostic logging": appends to Logs/bunnygrid.log in the data folder.
@MainActor
enum DiagnosticLog {
    static var fileURL: URL { AppModel.dataDirectory.appending(path: "Logs/bunnygrid.log") }

    static func write(_ message: String) {
        guard AppOptions.shared.values.diagnosticLogging else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
