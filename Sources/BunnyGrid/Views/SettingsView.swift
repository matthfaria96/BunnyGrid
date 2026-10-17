import AppKit
import BunnyGridCore
import SwiftUI

/// The Options window, laid out like Navicat's: a toolbar of panes, right-aligned labels,
/// Restore Defaults per pane and Cancel / OK. Changes are drafted and applied on OK.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage("appearance") private var savedAppearance = AppearancePreference.system.rawValue
    @State private var draft = AppOptions.shared.values
    @State private var appearance = AppearancePreference.system.rawValue
    @State private var ai = AIDraft()

    var body: some View {
        TabView(selection: $tab) {
            pane("general") { GeneralPane(draft: $draft, appearance: $appearance) }
                .tabItem { Label("General", systemImage: "gearshape") }
            pane("tabs") { TabsPane(draft: $draft) }
                .tabItem { Label("Tabs", systemImage: "rectangle.on.rectangle") }
            pane("completion") { CodeCompletionPane(draft: $draft) }
                .tabItem { Label("Code Completion", systemImage: "text.badge.plus") }
            pane("editor") { EditorPane(draft: $draft) }
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
            pane("records") { RecordsPane(draft: $draft) }
                .tabItem { Label("Records", systemImage: "tablecells") }
            pane("recovery") { AutoRecoveryPane(draft: $draft) }
                .tabItem { Label("Auto Recovery", systemImage: "clock.arrow.circlepath") }
            pane("ai") { AIPane(draft: $draft, ai: $ai) }
                .tabItem { Label("AI", systemImage: "sparkles") }
            pane("advanced") { AdvancedPane(draft: $draft) }
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 760)
        .onAppear(perform: reload)
    }

    /// One pane: its content, then Restore Defaults, then the window's Cancel / OK.
    private func pane<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 40)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                if id != "ai" {
                    Button("Restore Defaults") { restoreDefaults(id) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 66)
                Button("OK") { apply(); close() }
                    .keyboardShortcut(.defaultAction)
                    .frame(minWidth: 66)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.03))
        }
        .tag(id)
    }

    private func reload() {
        draft = AppOptions.shared.values
        appearance = savedAppearance
        ai = AIDraft(model: app.assistant)
    }

    private func restoreDefaults(_ id: String) {
        let defaults = OptionsValues()
        switch id {
        case "general":
            draft.showObjectsUnderSchema = defaults.showObjectsUnderSchema
            draft.objectListFont = nil
            draft.useSafeConfirmDialog = defaults.useSafeConfirmDialog
            draft.askToSaveNewQueries = defaults.askToSaveNewQueries
            appearance = AppearancePreference.system.rawValue
        case "tabs":
            draft.startupTabs = defaults.startupTabs
            draft.openTabsIn = defaults.openTabsIn
            draft.allowMultipleForms = defaults.allowMultipleForms
            draft.alwaysShowTabBar = defaults.alwaysShowTabBar
        case "completion":
            draft.useCodeCompletion = defaults.useCodeCompletion
            draft.autoSelectFirstSuggestion = defaults.autoSelectFirstSuggestion
            draft.autoUpdateCompletionInfo = defaults.autoUpdateCompletionInfo
            draft.includeSystemObjectsInCompletion = defaults.includeSystemObjectsInCompletion
        case "editor":
            draft.disableHighlightAboveMB = defaults.disableHighlightAboveMB
            draft.showLineNumbers = defaults.showLineNumbers
            draft.useBraceHighlighting = defaults.useBraceHighlighting
            draft.useSyntaxHighlighting = defaults.useSyntaxHighlighting
            draft.insertSpacesForTab = defaults.insertSpacesForTab
            draft.tabWidth = defaults.tabWidth
            draft.wordWrap = defaults.wordWrap
            draft.editorFont = nil
            draft.syntaxColors = SyntaxColors()
        case "records":
            draft.limitRecords = defaults.limitRecords
            draft.recordsPerPage = defaults.recordsPerPage
            draft.autoBeginTransaction = defaults.autoBeginTransaction
            draft.gridFont = nil
            draft.rowShading = defaults.rowShading
            draft.profilingColors = defaults.profilingColors
        case "recovery":
            draft.autosaveQueries = defaults.autosaveQueries
        case "advanced":
            draft.diagnosticLogging = defaults.diagnosticLogging
        default:
            break
        }
    }

    private func apply() {
        AppOptions.shared.save(draft)
        savedAppearance = appearance
        ai.commit(to: app.assistant)
    }

    /// Closes the Settings window itself: closing "the key window" closed the main window instead when Settings
    /// was not key (OK / Cancel pressed while the app was in the background, or with another window key).
    private func close() {
        let settings = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
        (settings ?? NSApp.keyWindow)?.close()
    }
}

// MARK: - Layout helpers

/// Navicat's option rows: a right-aligned label column and the controls beside it.
private struct OptionRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 190
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.isEmpty ? "" : label + ":")
                .frame(width: labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 9) { content() }
            Spacer(minLength: 0)
        }
    }
}

/// A titled section separator ("AI Assistant ────────").
private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }
}

/// "Font: [name size …] ☑ Use default font" in a rounded group, as Navicat draws it.
private struct FontGroup: View {
    let title: String
    @Binding var font: FontSpec?
    let fallback: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Font:")
                    // The display name ("System Font Regular"), not the private PostScript name (".AppleSystemUIFont").
                    Text(font?.label ?? "\(fallback.displayName ?? fallback.fontName) \(String(format: "%.1f", fallback.pointSize))")
                        .font(.system(size: 12, design: font == nil ? .default : .monospaced))
                        .foregroundStyle(font == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    Button("…") { FontPicker.shared.pick(initial: font?.nsFont ?? fallback) { font = FontSpec(name: $0.fontName, size: Double($0.pointSize)) } }
                        .disabled(font == nil)
                }
                Toggle("Use default font", isOn: Binding(get: { font == nil }, set: { useDefault in
                    font = useDefault ? nil : FontSpec(name: fallback.fontName, size: Double(fallback.pointSize))
                }))
                .padding(.leading, 48)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        .frame(maxWidth: 420)
    }
}

/// Opens the system font panel and reports the chosen font.
@MainActor
final class FontPicker: NSObject {
    static let shared = FontPicker()
    private var onPick: ((NSFont) -> Void)?
    private var current = NSFont.systemFont(ofSize: 12)

    func pick(initial: NSFont, onPick: @escaping (NSFont) -> Void) {
        self.onPick = onPick
        current = initial
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(initial, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        current = sender.convert(current)
        onPick?(current)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Binding var draft: OptionsValues
    @Binding var appearance: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "Appearance") {
                Picker("", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0 == .system ? "System Default" : $0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            OptionRow(label: "Main Window") {
                Toggle("Show objects under schema in navigation pane", isOn: $draft.showObjectsUnderSchema)
                FontGroup(title: "Object List Font", font: $draft.objectListFont, fallback: .systemFont(ofSize: 12))
            }
            OptionRow(label: "Confirm Dialog") {
                Toggle("Use safe confirm dialog", isOn: $draft.useSafeConfirmDialog)
                    .help("Deleting objects asks you to type the object's name to confirm.")
                Toggle("Ask to save new queries/profiles before closing", isOn: $draft.askToSaveNewQueries)
            }
        }
    }
}

private struct TabsPane: View {
    @Binding var draft: OptionsValues

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "On Startup") {
                Picker("", selection: $draft.startupTabs) {
                    Text("Open Objects tab only").tag(OptionsValues.StartupTabs.objectsOnly)
                    Text("Continue where you left off").tag(OptionsValues.StartupTabs.continueWhereLeft)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            OptionRow(label: "Open Tabs") {
                Text("Open new tab in").foregroundStyle(.secondary)
                Picker("", selection: $draft.openTabsIn) {
                    Text("Main window").tag(OptionsValues.OpenTabsIn.mainWindow)
                    Text("New window").tag(OptionsValues.OpenTabsIn.newWindow)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Toggle("Allow opening multiple forms for same object", isOn: $draft.allowMultipleForms)
            }
            OptionRow(label: "Tab Bar Style") {
                Toggle("Always show the tab bar", isOn: $draft.alwaysShowTabBar)
            }
        }
    }
}

private struct CodeCompletionPane: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: OptionsValues
    @State private var cleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "Code Completion") {
                HStack(spacing: 10) {
                    Toggle("Use code completion", isOn: $draft.useCodeCompletion)
                    Button(cleared ? "Cleared" : "Clear Code Completion Info") {
                        for session in app.sessions.values { for context in session.contexts.values { context.clearCompletionInfo() } }
                        cleared = true
                    }
                    .help("Forget the cached columns of every open database; they load again as you type")
                }
                Group {
                    Toggle("Auto update code completion info", isOn: $draft.autoUpdateCompletionInfo)
                    Toggle("Include system objects when updating code completion info", isOn: $draft.includeSystemObjectsInCompletion)
                    Toggle("Auto select first suggestion", isOn: $draft.autoSelectFirstSuggestion)
                }
                .padding(.leading, 18)
                .disabled(!draft.useCodeCompletion)
            }
        }
    }
}

private struct EditorPane: View {
    @Binding var draft: OptionsValues

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Disable syntax highlight and code completion if SQL larger than:")
                TextField("", value: $draft.disableHighlightAboveMB, format: .number)
                    .frame(width: 80)
                Text("MB")
            }
            OptionRow(label: "Show", labelWidth: 200) {
                Toggle("Show line number", isOn: $draft.showLineNumbers)
                Toggle("Use brace highlighting", isOn: $draft.useBraceHighlighting)
                Toggle("Use syntax highlighting", isOn: $draft.useSyntaxHighlighting)
            }
            OptionRow(label: "Text Layout", labelWidth: 200) {
                Toggle("Insert spaces when pressing Tab", isOn: $draft.insertSpacesForTab)
                HStack {
                    Text("Tab Width:")
                    TextField("", value: $draft.tabWidth, format: .number).frame(width: 90)
                }
                .padding(.leading, 18)
                Toggle("Use word wrap", isOn: $draft.wordWrap)
            }
            OptionRow(label: "Font and Colors", labelWidth: 200) {
                FontGroup(title: "Editor Font", font: $draft.editorFont, fallback: SQLHighlighter.defaultFont)
                SyntaxColorGroup(colors: $draft.syntaxColors)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                EditorPreview(options: draft)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }
}

/// Common · Keyword · Comment · String · Number · Background swatches.
private struct SyntaxColorGroup: View {
    @Binding var colors: SyntaxColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Syntax Colors").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                swatch("Common", \.common, .labelColor)
                swatch("Keyword", \.keyword, .navicatKeyword)
                swatch("Comment", \.comment, .secondaryLabelColor)
                swatch("String", \.string, .navicatString)
                swatch("Number", \.number, .systemBlue)
                swatch("Background", \.background, .textBackgroundColor)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    private func swatch(_ title: String, _ key: WritableKeyPath<SyntaxColors, String?>, _ fallback: NSColor) -> some View {
        VStack(spacing: 4) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: colors[keyPath: key]) ?? fallback) },
                set: { colors[keyPath: key] = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            Text(title).font(.system(size: 11))
        }
    }
}

/// The highlighted sample under Font and Colors, drawn with the drafted settings.
private struct EditorPreview: NSViewRepresentable {
    let options: OptionsValues

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.string = "/* SQL Editor Preview */\nSELECT `bunnygrid` FROM `db_admin_tool`\nWHERE\n  number = 1 AND\n  `desc` = 'Welcome to BunnyGrid, a native database client for your Mac';"
            text.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        SQLHighlighter.highlight(text, options: options)
    }
}

private struct RecordsPane: View {
    @Binding var draft: OptionsValues

    private func colorSwatch(_ title: String, _ key: WritableKeyPath<ProfilingColors, String>) -> some View {
        VStack(spacing: 4) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: draft.profilingColors[keyPath: key]) ?? .systemTeal) },
                set: { draft.profilingColors[keyPath: key] = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            Text(title).font(.system(size: 11))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "Records") {
                HStack {
                    Toggle("Limit records", isOn: $draft.limitRecords)
                    TextField("", value: $draft.recordsPerPage, format: .number)
                        .frame(width: 90)
                        .disabled(!draft.limitRecords)
                    Text("records per page")
                }
                Toggle("Auto begin transaction", isOn: $draft.autoBeginTransaction)
                    .help("Editing a row starts a transaction; changes stay pending until you commit.")
            }
            OptionRow(label: "Grid") {
                FontGroup(title: "Grid Font", font: $draft.gridFont, fallback: .systemFont(ofSize: 12))
                HStack {
                    Text("Row Shading:")
                    Picker("", selection: $draft.rowShading) {
                        ForEach(OptionsValues.RowShading.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            OptionRow(label: "Data Profiling") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Data Profiling Colors").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        colorSwatch("Bar", \.bar)
                        colorSwatch("Spotlight", \.spotlight)
                        colorSwatch("Not Null / Valid", \.valid)
                    }
                    .padding(10)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }
}

private struct AutoRecoveryPane: View {
    @Binding var draft: OptionsValues

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "Autosave Modified Queries", labelWidth: 230) {
                Picker("", selection: $draft.autosaveQueries) {
                    ForEach(OptionsValues.Autosave.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                Text("Unsaved query tabs are restored after a crash or forced quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AdvancedPane: View {
    @Binding var draft: OptionsValues
    @State private var results: [String: Bool?] = [:]
    @State private var testing = false

    private let targets: [(String, String)] = [
        ("Google", "https://www.google.com"),
        ("Anthropic API", "https://api.anthropic.com"),
        ("OpenAI API", "https://api.openai.com"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionRow(label: "Logs Location") {
                HStack(spacing: 4) {
                    Text(AppModel.dataDirectory.appending(path: "Logs").path)
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .frame(width: 300, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    Button("…") {
                        let url = AppModel.dataDirectory.appending(path: "Logs")
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .help("Show in Finder")
                }
                Toggle("Enable diagnostic logging", isOn: $draft.diagnosticLogging)
            }
            SectionHeader(title: "Connectivity")
            Text("This option only applies to BunnyGrid's AI assistants (Claude and ChatGPT).")
                .font(.system(size: 12))
            OptionRow(label: "Connectivity Diagnosis") {
                Button(testing ? "Testing…" : "Test Connectivity") { test() }
                    .disabled(testing)
                    .frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(targets, id: \.0) { name, _ in
                        HStack(spacing: 6) {
                            switch results[name] ?? nil {
                            case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            case .none: Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                            }
                            Text(name)
                        }
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    private func test() {
        testing = true
        results = [:]
        Task {
            for (name, address) in targets {
                // A typed address that isn't a URL (spaces, a bare scheme) is just unreachable, not a crash.
                guard let url = URL(string: address), url.host != nil else { results[name] = false; continue }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 8
                let reachable = (try? await URLSession.shared.data(for: request)).map { _, response in
                    (response as? HTTPURLResponse) != nil
                } ?? false
                results[name] = reachable
            }
            testing = false
        }
    }
}

// MARK: - AI pane

/// The AI pane's staged state: assistants, pending keys and the UI switches.
struct AIDraft {
    var showAIFeatures = true
    var enabled = true
    var assistants: [AIAssistantConfig] = []
    var keys: [UUID: String] = [:]
    var removed: Set<UUID> = []
    var enterSends = true
    var compareEnabled = true

    init() {}

    @MainActor
    init(model: AssistantModel) {
        showAIFeatures = UserDefaults.standard.object(forKey: "showAIFeatures") as? Bool ?? true
        enabled = model.aiEnabled
        assistants = model.assistants
        keys = Dictionary(uniqueKeysWithValues: model.assistants.map { ($0.id, model.storedAPIKey(for: $0)) })
        enterSends = model.enterSends
        compareEnabled = model.compareEnabled
    }

    @MainActor
    func commit(to model: AssistantModel) {
        UserDefaults.standard.set(showAIFeatures, forKey: "showAIFeatures")
        model.aiEnabled = enabled
        model.enterSends = enterSends
        model.compareEnabled = compareEnabled
        for id in removed { model.removeAssistant(id) }
        for assistant in assistants {
            if model.assistants.contains(where: { $0.id == assistant.id }) {
                model.updateAssistant(assistant)
            } else {
                model.assistants.append(assistant)
            }
            let key = keys[assistant.id] ?? ""
            if key != model.storedAPIKey(for: assistant) { model.setAPIKey(key, for: assistant) }
        }
        model.assistants = assistants
        if model.active == nil, let first = assistants.first { model.activate(first.id) }
    }
}

private struct AIPane: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: OptionsValues
    @Binding var ai: AIDraft
    @State private var selection: UUID?

    static let languages = ["Auto", "English", "Português", "Español", "Français", "Deutsch", "Italiano", "中文", "日本語", "한국어"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show AI features", isOn: $ai.showAIFeatures)
            Toggle("Enable AI Assistant", isOn: $ai.enabled)
            SectionHeader(title: "AI Assistant")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    List(selection: $selection) {
                        ForEach(ai.assistants) { assistant in
                            HStack(spacing: 7) {
                                AppIcon(name: assistant.provider.iconName, size: 18)
                                Text(assistant.name).lineLimit(1)
                            }
                            .tag(assistant.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(width: 200, height: 330)
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(AIProvider.allCases) { provider in
                                Button(provider.menuTitle) { add(provider) }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add an assistant")
                        Button {
                            remove()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.plain)
                        .disabled(selection == nil)
                        .help("Remove the selected assistant")
                    }
                    .padding(.leading, 6)
                    .foregroundStyle(.secondary)
                }
                .disabled(!ai.enabled)

                Group {
                    if let index = ai.assistants.firstIndex(where: { $0.id == selection }) {
                        AssistantForm(assistant: $ai.assistants[index], key: Binding(
                            get: { ai.keys[ai.assistants[index].id] ?? "" },
                            set: { ai.keys[ai.assistants[index].id] = $0 }
                        ))
                    } else {
                        Text("Click left side \"+\" button to add an assistant.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 350, alignment: .top)
                .disabled(!ai.enabled)
            }
            SectionHeader(title: "AI Assistant UI")
            OptionRow(label: "Action for Enter Key", labelWidth: 300) {
                Picker("", selection: $ai.enterSends) {
                    Text("Send Message").tag(true)
                    Text("New Line").tag(false)
                }
                .labelsHidden()
                .frame(width: 150)
                Toggle("Enable compare with other assistants", isOn: $ai.compareEnabled)
            }
            .disabled(!ai.enabled)
            SectionHeader(title: "Ask AI")
            OptionRow(label: "Language", labelWidth: 300) {
                Picker("", selection: $draft.askAILanguage) {
                    ForEach(Self.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
        .onAppear { selection = selection ?? app.assistant.active?.id ?? ai.assistants.first?.id }
        .overlay(alignment: .bottom) { AITestBannerView().offset(y: 34) }
    }

    private func add(_ provider: AIProvider) {
        let taken = Set(ai.assistants.map(\.name))
        var name = provider.displayName
        var number = 2
        while taken.contains(name) { name = "\(provider.displayName) \(number)"; number += 1 }
        let assistant = AIAssistantConfig(name: name, provider: provider)
        ai.assistants.append(assistant)
        selection = assistant.id
    }

    private func remove() {
        guard let id = selection else { return }
        ai.assistants.removeAll { $0.id == id }
        ai.keys[id] = nil
        ai.removed.insert(id)
        selection = ai.assistants.first?.id
    }
}

/// One assistant's fields: name, provider, API host, key, model, Max Tokens, Effort and Instruction.
private struct AssistantForm: View {
    @Environment(AppModel.self) private var app
    @Binding var assistant: AIAssistantConfig
    @Binding var key: String
    @State private var testing = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 9) {
            row("AI Assistant Name") { TextField("", text: $assistant.name) }
            row("AI Provider") {
                HStack(spacing: 6) {
                    AppIcon(name: assistant.provider.iconName, size: 16)
                    Text(assistant.provider.menuTitle)
                }
            }
            row("API Host") { TextField("", text: $assistant.apiHost, prompt: Text(assistant.provider.defaultHost)) }
            row("API Endpoint") {
                Text(assistant.baseURL.appending(path: assistant.provider == .claude ? "v1/messages" : "v1/responses").absoluteString)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            row("API Key") {
                VStack(alignment: .leading, spacing: 3) {
                    SecureField("", text: $key, prompt: Text(assistant.provider.keyPlaceholder))
                    Link("Get an \(assistant.provider.company) API key", destination: assistant.provider.keysURL).font(.system(size: 11))
                }
            }
            row("Model") {
                HStack(spacing: 4) {
                    TextField("", text: $assistant.model, prompt: Text(assistant.provider.defaultModel))
                    Menu {
                        ForEach(app.assistant.models(for: assistant.provider)) { option in
                            Button(option.name) { assistant.model = option.id }
                        }
                    } label: {
                        Text("…")
                    }
                    .fixedSize()
                    .help("Choose a chat model")
                }
            }
            row("Max Tokens") {
                TextField("", value: $assistant.maxTokens, format: .number, prompt: Text(assistant.provider == .claude ? "64000" : "Model limit"))
                    .frame(width: 120)
            }
            row("Effort") {
                Picker("", selection: $assistant.effort) {
                    ForEach(AIEffort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                // As a tooltip: a caption row here pushed the form past the list and over "AI Assistant UI".
                .help("Effort replaces Temperature: current Claude and GPT models no longer take a sampling temperature.")
            }
            row("Instructions") {
                TextEditor(text: $assistant.instruction)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true
                    let config = assistant, typed = key
                    Task {
                        let result = await app.assistant.test(config, key: typed)
                        testing = false
                        switch result {
                        case .success: AITestBanner.shared.show(nil)
                        case .failure(let error): AITestBanner.shared.show(error.localizedDescription)
                        }
                    }
                }
                .disabled(testing)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label + ":").gridColumnAlignment(.trailing)
            content()
        }
    }
}

/// The green "Connection Successful" (or red error) strip Navicat shows after Test Connection.
@MainActor
@Observable
final class AITestBanner {
    static let shared = AITestBanner()
    /// nil while hidden; "" for success, otherwise the error.
    private(set) var message: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ error: String?) {
        message = error ?? ""
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(error == nil ? 4 : 8))
            if !Task.isCancelled { message = nil }
        }
    }

    func hide() { message = nil }
}

private struct AITestBannerView: View {
    private var banner = AITestBanner.shared

    var body: some View {
        if let message = banner.message {
            let success = message.isEmpty
            HStack(spacing: 8) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Text(success ? "Connection Successful" : message).lineLimit(2)
                Spacer()
                Button { banner.hide() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(success ? Color.green : Color.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((success ? Color.green : Color.red).opacity(0.18))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
