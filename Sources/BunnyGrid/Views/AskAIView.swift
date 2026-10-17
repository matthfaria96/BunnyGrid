import AppKit
import BunnyGridCore
import SwiftUI

/// One Ask AI request from the query editor (a built-in action, a custom action or Fix with AI).
@MainActor
@Observable
final class AskAIRun: Identifiable {
    let id = UUID()
    let title: String
    let format: AIResponseFormat
    /// The SQL the answer is compared against for Show Diff.
    let originalSQL: String
    /// What the user asked, for "Continue in New Chat".
    let question: String
    let prompt: String
    /// The saved/custom action behind this run (nil for the built-in actions), for Back and Save AI Action.
    var customAction: AIAction?
    var builtin: AIBuiltinAction?
    /// What was attached ("All Text", "Server Version"…), shown as chips over the answer.
    var attached: [String] = []
    let assistantConfig: AIAssistantConfig
    var provider: AIProvider { assistantConfig.provider }
    private(set) var model: String?
    private(set) var text = ""
    private(set) var note: String?
    private(set) var error: String?
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var assistant: AssistantModel?

    init(title: String, format: AIResponseFormat, originalSQL: String, question: String, prompt: String, assistant: AssistantModel) {
        self.title = title
        self.format = format
        self.originalSQL = originalSQL
        self.question = question
        self.prompt = prompt
        // AskAI checks there is an active assistant with a key before creating a run.
        self.assistantConfig = assistant.active ?? AIAssistantConfig(provider: .claude)
        self.assistant = assistant
    }

    /// The SQL of a code answer (also while it streams in).
    var code: String { AIPrompts.extractCode(from: text) }

    func start() {
        guard let assistant else { return }
        task?.cancel()
        text = ""
        note = nil
        error = nil
        isRunning = true
        let stream = assistant.stream(assistantConfig, messages: [.object(["role": .string("user"), "content": .string(prompt)])])
        let provider = provider
        task = Task {
            defer { isRunning = false }
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let piece): text += piece
                    case .fallback(let from, let to): note = "\(from) declined this request; \(to) answered instead."
                    case .finished(let turn):
                        model = turn.model
                        if turn.wasRefused { note = "\(provider.displayName) declined to answer this request." }
                        if turn.stopReason == "max_tokens" { note = "The answer was cut off at the output limit (Max Tokens in Settings)." }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

/// Starts Ask AI runs for a query tab and checks that the active platform has a key.
@MainActor
enum AskAI {
    static func run(_ action: AIBuiltinAction, on query: QueryTabModel, app: AppModel,
                    targetEngine: String = "", targetVersion: String = "") {
        guard ensureKey(app) else { return }
        Task {
            var context = await AIContextBuilder.requestContext(for: query, includeSchema: true)
            var original = context.targetSQL
            if action == .fixError || action == .explainError, let failed = query.failedStatement {
                context.selectedText = failed
                original = failed
            }
            let prompt = AIPrompts.builtin(action, context: context, targetEngine: targetEngine, targetVersion: targetVersion,
                                           errorMessage: query.failureMessage ?? "")
            var title = action.title
            if action == .convert { title = "Convert SQL to \([targetEngine, targetVersion].filter { !$0.isEmpty }.joined(separator: " "))" }
            let question = action == .explainError ? "Explain this error: \(query.failureMessage ?? "")" : "\(title):\n\(original)"
            let run = AskAIRun(title: title, format: action.format, originalSQL: original, question: question, prompt: withLanguage(prompt), assistant: app.assistant)
            run.builtin = action
            run.attached = ["Selected Text", "Server Version", "Current Schema"]
            present(run, on: query)
        }
    }

    static func run(_ action: AIAction, on query: QueryTabModel, app: AppModel) {
        guard ensureKey(app) else { return }
        Task {
            let context = await AIContextBuilder.requestContext(for: query, includeSchema: action.context.contains(.currentSchema))
            let original = action.context.contains(.selectedText) && query.hasSelection ? query.selectedText : query.text
            let run = AskAIRun(title: action.title, format: action.format, originalSQL: original, question: action.prompt,
                               prompt: withLanguage(AIPrompts.custom(action, context: context)), assistant: app.assistant)
            run.customAction = action
            run.attached = [(AIContextOptions.selectedText, "Selected Text"), (.allText, "All Text"), (.currentSchema, "Current Schema"), (.serverVersion, "Server Version")]
                .filter { action.context.contains($0.0) }.map(\.1)
            present(run, on: query)
        }
    }

    /// Options › AI › Ask AI › Language: answers in that language unless it is Auto.
    static func withLanguage(_ prompt: String) -> String {
        let language = AppOptions.shared.values.askAILanguage
        return language == "Auto" ? prompt : prompt + "\n\nWrite all explanations and SQL comments in \(language)."
    }

    private static func present(_ run: AskAIRun, on query: QueryTabModel) {
        query.showingAskAICustom = false
        query.aiRun = run
        run.start()
    }

    private static func ensureKey(_ app: AppModel) -> Bool {
        guard app.assistant.unavailableReason == nil else {
            app.showingAccountMenu = true
            return false
        }
        return true
    }
}

/// The editor toolbar's Ask AI button: click to ask, the arrow for Navicat's menu
/// (Ask AI, Change AI Assistant, Explain / Beautify / Optimize / Convert, pinned actions).
struct AskAIButton: View {
    @Environment(AppModel.self) private var app
    @Bindable var query: QueryTabModel
    @State private var showingConvert = false

    var body: some View {
        Menu {
            Button("Ask AI") { query.showingAskAICustom = true }
            Menu("Change AI Assistant (\(app.assistant.active?.name ?? "None"))") {
                ForEach(app.assistant.assistants) { assistant in
                    Button {
                        app.assistant.activate(assistant.id)
                    } label: {
                        if app.assistant.active?.id == assistant.id { Label(assistant.name, systemImage: "checkmark") } else { Text(assistant.name) }
                    }
                }
            }
            Divider()
            ForEach([AIBuiltinAction.explain, .beautify, .optimize]) { action in
                Button(action.title) { AskAI.run(action, on: query, app: app) }
            }
            Button("Convert SQL to Another Database Type") { showingConvert = true }
            if !app.assistant.pinnedActions.isEmpty {
                Divider()
                ForEach(app.assistant.pinnedActions) { action in
                    Button(action.title) { AskAI.run(action, on: query, app: app) }
                }
            }
        } label: {
            if let icon = IconLibrary.image(app.assistant.provider.iconName, size: 15) {
                Image(nsImage: icon)
            } else {
                Image(systemName: "sparkles")
            }
        } primaryAction: {
            query.showingAskAICustom = true
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(query.isBlank)
        .help("Ask AI")
        .accessibilityIdentifier("query.askAI")
        .sheet(isPresented: $showingConvert) {
            ConvertSQLSheet(query: query)
        }
    }
}

/// The Ask AI card floating over the query tab: compose a question, then review the answer.
struct AskAIOverlay: View {
    @Bindable var query: QueryTabModel

    var body: some View {
        ZStack {
            if let run = query.aiRun {
                Color.black.opacity(0.18).ignoresSafeArea().onTapGesture {}
                AskAIResultCard(run: run, query: query)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            } else if query.showingAskAICustom {
                Color.black.opacity(0.18).ignoresSafeArea().onTapGesture {}
                AskAIComposeCard(query: query)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: query.aiRun?.id)
        .animation(.easeOut(duration: 0.18), value: query.showingAskAICustom)
    }
}

/// The card's frame: rounded, bordered, with a shadow, like Navicat's floating Ask AI panel.
private struct AskAICard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(minWidth: 560, idealWidth: 720, maxWidth: 760, minHeight: 300, idealHeight: 340, maxHeight: 520)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .padding(30)
    }
}

/// "Ask AI:" — the question, AI Response (Code / Natural Language), what to attach, saved actions and Ask AI.
private struct AskAIComposeCard: View {
    @Environment(AppModel.self) private var app
    @Bindable var query: QueryTabModel
    @AppStorage("askAIDraftFormat") private var formatRaw = AIResponseFormat.code.rawValue
    @AppStorage("askAIDraftContext") private var contextRaw = AIContextOptions([.allText, .serverVersion]).rawValue
    @State private var prompt = ""
    @State private var showingSaved = false
    @State private var editingID: UUID?

    private var format: AIResponseFormat { AIResponseFormat(rawValue: formatRaw) ?? .code }
    private var context: AIContextOptions { AIContextOptions(rawValue: contextRaw) }
    private var action: AIAction {
        AIAction(id: editingID ?? UUID(), prompt: prompt, format: format, context: context,
                 isPinned: app.assistant.actions.first { $0.id == editingID }?.isPinned ?? false)
    }

    var body: some View {
        AskAICard {
            HStack(spacing: 14) {
                if showingSaved {
                    savedList.frame(width: 200)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Ask AI:").font(.system(size: 13, weight: .medium))
                        Spacer()
                        AssistantMenu()
                    }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $prompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                        if prompt.isEmpty {
                            Text("You can ask AI a question...")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    HStack(spacing: 8) {
                        Text("AI Response:").font(.system(size: 12.5))
                        Picker("", selection: $formatRaw) {
                            ForEach(AIResponseFormat.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                            .help("Code returns only SQL you can apply to the editor; Natural Language returns an explanation.")
                    }
                    Text("You will attach:").font(.system(size: 12.5))
                    HStack(spacing: 8) {
                        pill("Selected Text", .selectedText).disabled(!query.hasSelection)
                        pill("All Text", .allText)
                        pill("Current Schema", .currentSchema)
                        pill("Server Version", .serverVersion)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        Button { showingSaved.toggle() } label: { Image(systemName: "sidebar.left") }
                            .help(showingSaved ? "Hide Saved AI Actions" : "Show Saved AI Actions")
                        Menu("Save AI Action") {
                            Button("Save AI Action") { editingID = app.assistant.saveAction(action).id }
                            Button("Save and Pin to Menu") {
                                var pinned = action
                                pinned.isPinned = true
                                editingID = app.assistant.saveAction(pinned).id
                            }
                        }
                        .fixedSize()
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button("Close") { query.showingAskAICustom = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Ask AI") { AskAI.run(action, on: query, app: app) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            if let last = query.lastCustomAction {
                prompt = last.prompt
                formatRaw = last.format.rawValue
                contextRaw = last.context.rawValue
                editingID = app.assistant.actions.contains { $0.id == last.id } ? last.id : nil
            }
        }
    }

    /// Navicat's attach toggles: outlined pills, filled blue when on.
    private func pill(_ title: String, _ option: AIContextOptions) -> some View {
        let on = context.contains(option)
        return Button {
            var value = context
            if on { value.remove(option) } else { value.insert(option) }
            contextRaw = value.rawValue
        } label: {
            Text(title)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.28) : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved AI Actions").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            if app.assistant.actions.isEmpty {
                Text("Save a question to reuse it. Pinned actions appear in the Ask AI menu.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(app.assistant.actions) { saved in
                        HStack(spacing: 6) {
                            Image(systemName: saved.format == .code ? "chevron.left.forwardslash.chevron.right" : "text.bubble")
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            Text(saved.title).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 0)
                            Button { app.assistant.togglePin(saved.id) } label: {
                                Image(systemName: saved.isPinned ? "pin.fill" : "pin").font(.system(size: 10))
                                    .foregroundStyle(saved.isPinned ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(saved.isPinned ? "Unpin from Menu" : "Pin to Menu")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(editingID == saved.id ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingID = saved.id
                            prompt = saved.prompt
                            formatRaw = saved.format.rawValue
                            contextRaw = saved.context.rawValue
                        }
                        .contextMenu {
                            Button(saved.isPinned ? "Unpin from Menu" : "Pin to Menu") { app.assistant.togglePin(saved.id) }
                            Button("Delete", role: .destructive) { app.assistant.deleteAction(saved.id) }
                        }
                    }
                }
            }
        }
    }
}

/// Assistant name and model with a menu to switch, at the card's top right.
private struct AssistantMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ForEach(app.assistant.assistants) { assistant in
                Button("\(assistant.name) (\(app.assistant.modelName(for: assistant)))") { app.assistant.activate(assistant.id) }
            }
        } label: {
            HStack(spacing: 5) {
                AppIcon(name: app.assistant.provider.iconName, size: 14)
                Text(app.assistant.active?.name ?? "").fontWeight(.semibold)
                Text("(\(app.assistant.activeModelName))").foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The answer: for code, Perform Action and Original / AI Suggested Text side by side; for prose, the explanation.
struct AskAIResultCard: View {
    @Environment(AppModel.self) private var app
    let run: AskAIRun
    let query: QueryTabModel
    @State private var mode: EditorInsertMode = .append
    @AppStorage("askAISideBySide") private var sideBySide = true

    private var modes: [EditorInsertMode] {
        var list: [EditorInsertMode] = [.append, .replaceAll]
        if query.hasSelection { list.insert(.replaceSelection, at: 0) }
        if run.customAction != nil { list.append(.atCursor) }
        return list
    }

    private var actionLabel: String {
        switch mode {
        case .append: "Append"
        case .replaceAll, .replaceSelection: "Replace"
        case .atCursor: "Insert"
        }
    }

    var body: some View {
        AskAICard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.customAction != nil ? "New AI Action" : run.title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        AppIcon(name: run.provider.iconName, size: 14)
                        Text(run.assistantConfig.name).fontWeight(.semibold)
                        Text("(\(run.model ?? app.assistant.modelName(for: run.assistantConfig)))").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12.5))
                }
                if run.customAction != nil {
                    HStack(spacing: 8) {
                        Text(run.question).font(.system(size: 12.5)).lineLimit(2)
                        ForEach(run.attached, id: \.self) { chip in
                            Text(chip).font(.system(size: 12))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.25)))
                        }
                    }
                }
                Divider()
                if run.format == .code {
                    HStack(spacing: 8) {
                        Text("Perform Action:").font(.system(size: 12.5))
                        Picker("", selection: $mode) {
                            ForEach(modes) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        if run.isRunning { ProgressView().controlSize(.small) }
                    }
                    codeComparison
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if run.text.isEmpty && run.isRunning {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(run.assistantConfig.name) is working on it…").foregroundStyle(.secondary) }
                            }
                            MarkdownView(text: run.text)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
                }
                if let note = run.note { Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange) }
                if let error = run.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
                footer
            }
        }
        .onAppear { mode = defaultMode }
        .onChange(of: query.hasSelection) { _, _ in if !modes.contains(mode) { mode = defaultMode } }
    }

    /// Built-in actions replace what they worked on (the selection, else everything); custom actions append.
    private var defaultMode: EditorInsertMode {
        guard run.builtin != nil else { return .append }
        return query.hasSelection ? .replaceSelection : .replaceAll
    }

    private var codeComparison: some View {
        let lines = LineDiff.diff(old: run.originalSQL, new: run.code)
        let left = lines.filter { $0.kind != .added }
        let right = lines.filter { $0.kind != .removed }
        return HStack(spacing: 10) {
            if sideBySide {
                CodeColumn(title: "Original Text:", titleColor: .primary, lines: left, highlight: .removed)
            }
            CodeColumn(title: "AI Suggested Text:", titleColor: .green, lines: sideBySide ? right : lines, highlight: .added)
        }
        .frame(minHeight: 130)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if run.format == .code {
                Button { sideBySide.toggle() } label: { Image(systemName: sideBySide ? "rectangle.split.2x1" : "rectangle") }
                    .help(sideBySide ? "Show only the AI Suggested Text" : "Show Original and AI Suggested Text")
            }
            if let action = run.customAction {
                Menu("Save AI Action") {
                    Button("Save AI Action") { query.lastCustomAction = app.assistant.saveAction(action) }
                    Button("Save and Pin to Menu") {
                        var pinned = action
                        pinned.isPinned = true
                        query.lastCustomAction = app.assistant.saveAction(pinned)
                    }
                }
                .fixedSize()
            }
            Spacer()
            if run.format == .naturalLanguage {
                Button {
                    app.assistant.continueInNewChat(question: run.question, apiPrompt: run.prompt, answer: run.text, provider: run.provider,
                                                    assistantName: run.assistantConfig.name, model: run.model)
                    close()
                } label: { Label("Continue in New Chat", systemImage: "bubble.left.and.bubble.right") }
                .disabled(run.isRunning || run.text.isEmpty)
            }
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            if let action = run.customAction {
                Button("Back") {
                    query.lastCustomAction = action
                    run.stop()
                    query.aiRun = nil
                    query.showingAskAICustom = true
                }
            }
            if run.format == .code {
                Button(actionLabel) {
                    query.insert(run.code, mode: mode)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(run.isRunning || run.code.isEmpty || !query.canInsert(mode))
            }
        }
    }

    private func close() {
        run.stop()
        query.aiRun = nil
    }
}

/// One side of the comparison: line numbers and code, changed lines tinted.
private struct CodeColumn: View {
    let title: String
    let titleColor: Color
    let lines: [LineDiff.Line]
    let highlight: LineDiff.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(titleColor)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 0) {
                            Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing).padding(.trailing, 8)
                            Text(SQLSyntax.highlight(line.text.isEmpty ? " " : line.text))
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(line.kind == highlight ? (highlight == .added ? Color.green : Color.red).opacity(0.18) : Color.clear)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Convert SQL to Another Database Type": target engine and version.
struct ConvertSQLSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let query: QueryTabModel
    @AppStorage("askAIConvertTarget") private var target = "MySQL"
    @State private var version = ""

    static let targets = ["MySQL", "PostgreSQL", "MariaDB", "SQLite", "SQL Server", "Oracle", "Snowflake", "ClickHouse", "IBM Db2", "Redshift"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert SQL to Another Database Type").font(.headline)
            Form {
                LabeledContent("From", value: query.context.map { "\($0.kind.displayName) \($0.session?.serverVersion ?? "")" } ?? "SQL")
                Picker("To", selection: $target) {
                    ForEach(Self.targets, id: \.self) { Text($0).tag($0) }
                }
                TextField("Version", text: $version, prompt: Text("Optional, e.g. 8.4"))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Convert") {
                    let target = target, version = version
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        AskAI.run(.convert, on: query, app: app, targetEngine: target, targetVersion: version)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
