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
    let provider: AIProvider
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
        self.provider = assistant.provider
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
        let stream = assistant.stream(provider, messages: [.object(["role": .string("user"), "content": .string(prompt)])])
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
            present(AskAIRun(title: title, format: action.format, originalSQL: original, question: question, prompt: prompt, assistant: app.assistant), on: query)
        }
    }

    static func run(_ action: AIAction, on query: QueryTabModel, app: AppModel) {
        guard ensureKey(app) else { return }
        Task {
            let context = await AIContextBuilder.requestContext(for: query, includeSchema: action.context.contains(.currentSchema))
            let original = action.context.contains(.selectedText) && query.hasSelection ? query.selectedText : query.text
            let run = AskAIRun(title: action.title, format: action.format, originalSQL: original, question: action.prompt,
                               prompt: AIPrompts.custom(action, context: context), assistant: app.assistant)
            present(run, on: query)
        }
    }

    private static func present(_ run: AskAIRun, on query: QueryTabModel) {
        query.aiRun = run
        run.start()
    }

    private static func ensureKey(_ app: AppModel) -> Bool {
        guard app.assistant.hasAPIKey else {
            app.showingAccountMenu = true
            return false
        }
        return true
    }
}

/// The editor toolbar's Ask AI button: click for custom actions, hold for the default and pinned ones.
struct AskAIButton: View {
    @Environment(AppModel.self) private var app
    @Bindable var query: QueryTabModel
    @State private var showingConvert = false

    var body: some View {
        Menu {
            Section("Ask \(app.assistant.provider.displayName)") {
                ForEach([AIBuiltinAction.explain, .optimize, .beautify]) { action in
                    Button(action.title) { AskAI.run(action, on: query, app: app) }
                }
                Button("Convert SQL to Another Database Type…") { showingConvert = true }
            }
            if !app.assistant.pinnedActions.isEmpty {
                Section("Pinned") {
                    ForEach(app.assistant.pinnedActions) { action in
                        Button(action.title) { AskAI.run(action, on: query, app: app) }
                    }
                }
            }
            Divider()
            Button("Custom Actions…") { query.showingAskAICustom = true }
        } label: {
            Label {
                Text("Ask AI")
            } icon: {
                if let icon = IconLibrary.image(app.assistant.provider.iconName, size: 14) { Image(nsImage: icon) }
            }
            .labelStyle(.titleAndIcon)
        } primaryAction: {
            query.showingAskAICustom = true
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Ask AI: click for custom actions, hold for Explain, Optimize, Beautify and Convert")
        .sheet(isPresented: $query.showingAskAICustom) {
            AskAICustomSheet(query: query)
        }
        .sheet(isPresented: $showingConvert) {
            ConvertSQLSheet(query: query)
        }
    }
}

/// The answer pane: diff-highlighted code with the editor insert options, or prose with Continue in New Chat.
struct AskAIResultView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let run: AskAIRun
    let query: QueryTabModel
    @AppStorage("askAIShowDiff") private var showDiff = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                    if let note = run.note {
                        Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if let error = run.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu {
                if run.format == .code { Toggle("Show Diff", isOn: $showDiff) }
                Button("Copy") { copy(run.format == .code ? run.code : run.text) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .onDisappear { run.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIcon(name: run.provider.iconName, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([run.provider.displayName, run.model ?? app.assistant.modelName(for: run.provider)].joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if run.format == .code {
                Toggle("Show Diff", isOn: $showDiff).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            }
            if run.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { run.stop() }
            } else {
                Button { run.start() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if run.text.isEmpty && run.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(run.provider.displayName) is working on it…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        } else if run.format == .code {
            let original = run.originalSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            if showDiff && !original.isEmpty && !run.code.isEmpty {
                DiffView(lines: LineDiff.diff(old: original, new: run.code))
            } else {
                Text(SQLSyntax.highlight(run.code))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MarkdownView(text: run.text)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if run.format == .code {
                ForEach(EditorInsertMode.allCases.reversed()) { mode in
                    Button(mode.shortTitle) {
                        query.insert(run.code, mode: mode)
                        dismiss()
                    }
                    .help(mode.title)
                    .disabled(run.isRunning || run.code.isEmpty || !query.canInsert(mode))
                }
                Spacer()
                Button("New Query") {
                    app.openQuery(text: run.code, in: query.context)
                    dismiss()
                }
                .disabled(run.isRunning || run.code.isEmpty)
            } else {
                Button {
                    app.assistant.continueInNewChat(question: run.question, apiPrompt: run.prompt, answer: run.text, provider: run.provider, model: run.model)
                    dismiss()
                } label: {
                    Label("Continue in New Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(run.isRunning || run.text.isEmpty)
                Spacer()
                Button("Copy") { copy(run.text) }.disabled(run.text.isEmpty)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Lines added by the AI in green, removed lines in red, like Navicat's highlighted differences.
struct DiffView: View {
    let lines: [LineDiff.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 0) {
                    Text(symbol(line.kind))
                        .foregroundStyle(color(line.kind))
                        .frame(width: 18, alignment: .center)
                    Text(line.kind == .removed ? AttributedString(line.text.isEmpty ? " " : line.text) : SQLSyntax.highlight(line.text.isEmpty ? " " : line.text))
                        .strikethrough(line.kind == .removed, color: .red.opacity(0.6))
                        .foregroundStyle(line.kind == .removed ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.vertical, 1)
                .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.13))
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func symbol(_ kind: LineDiff.Kind) -> String {
        switch kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private func color(_ kind: LineDiff.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .added: .green
        case .removed: .red
        }
    }
}

/// Custom Ask AI actions: saved actions on the left (pin them to the menu), the question and its context on the right.
struct AskAICustomSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let query: QueryTabModel
    @State private var editing = AIAction(prompt: "")
    @State private var hovered: UUID?

    var body: some View {
        HStack(spacing: 0) {
            savedList
                .frame(width: 230)
            Divider()
            editor
        }
        .frame(width: 760, height: 470)
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Actions").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton(systemImage: "plus", help: "New Action", tint: .accentColor) { editing = AIAction(prompt: "") }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            if app.assistant.actions.isEmpty {
                Text("Save a question to reuse it. Pinned actions appear in the Ask AI menu.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(app.assistant.actions) { action in actionRow(action) }
                    }
                    .padding(6)
                }
            }
        }
        .background(VisualEffectBackground(material: .sidebar, blending: .withinWindow))
    }

    private func actionRow(_ action: AIAction) -> some View {
        let selected = editing.id == action.id
        return HStack(spacing: 7) {
            Image(systemName: action.format == .code ? "chevron.left.forwardslash.chevron.right" : "text.bubble")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(action.title).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 0)
            if action.isPinned || hovered == action.id {
                Button { app.assistant.togglePin(action.id) } label: {
                    Image(systemName: action.isPinned ? "pin.fill" : "pin").font(.system(size: 11))
                        .foregroundStyle(action.isPinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(action.isPinned ? "Unpin from Menu" : "Pin to Menu")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { editing = action }
        .onHover { hovered = $0 ? action.id : (hovered == action.id ? nil : hovered) }
        .contextMenu {
            Button(action.isPinned ? "Unpin from Menu" : "Pin to Menu") { app.assistant.togglePin(action.id) }
            Button("Delete", role: .destructive) {
                app.assistant.deleteAction(action.id)
                if editing.id == action.id { editing = AIAction(prompt: "") }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppIcon(name: app.assistant.provider.iconName, size: 20)
                Text("Ask \(app.assistant.provider.displayName)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(app.assistant.modelName(for: app.assistant.provider)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $editing.prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if editing.prompt.isEmpty {
                    Text("Ask anything about this query, e.g. “Add pagination with LIMIT/OFFSET” or “Rewrite with a CTE”.")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Text("Response Format").font(.system(size: 12))
                Picker("", selection: $editing.format) {
                    ForEach(AIResponseFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Attach").font(.system(size: 12))
                HStack(spacing: 16) {
                    contextToggle("Selected Text", .selectedText).disabled(!query.hasSelection)
                    contextToggle("All Text", .allText)
                    contextToggle("Current Schema", .currentSchema)
                    contextToggle("Server Version", .serverVersion)
                }
                .font(.system(size: 12))
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Action") {
                    editing = app.assistant.saveAction(editing)
                }
                .disabled(isEmpty)
                Button("Ask AI") {
                    let action = editing
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        AskAI.run(action, on: query, app: app)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isEmpty)
            }
        }
        .padding(18)
    }

    private var isEmpty: Bool { editing.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func contextToggle(_ title: String, _ option: AIContextOptions) -> some View {
        Toggle(title, isOn: Binding(
            get: { editing.context.contains(option) },
            set: { on in if on { editing.context.insert(option) } else { editing.context.remove(option) } }
        ))
        .toggleStyle(.checkbox)
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
