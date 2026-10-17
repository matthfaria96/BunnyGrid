import AppKit
import BunnyGridCore
import SwiftUI

/// The right pane's AI tab: chat with Claude or ChatGPT about the current database.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var app

    private var assistant: AssistantModel { app.assistant }

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeader()
            Divider()
            messages
            Composer()
                .padding(8)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !assistant.hasAPIKey {
                        APIKeyBanner()
                    }
                    if let chat = assistant.currentChat {
                        ForEach(chat.messages) { message in
                            MessageView(message: message, isLast: message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                    } else if !assistant.isStreaming {
                        EmptyChat()
                    }
                    if assistant.isStreaming {
                        StreamingReply(provider: assistant.provider, text: assistant.streamingText)
                    }
                    if let error = assistant.error {
                        ErrorNote(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: assistant.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.currentChat?.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: assistant.currentChatID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

// MARK: - Header

private struct AssistantHeader: View {
    @Environment(AppModel.self) private var app
    @State private var showingHistory = false

    var body: some View {
        let assistant = app.assistant
        HStack(spacing: 6) {
            Button { showingHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chat History")
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                ChatHistoryPopover { showingHistory = false }
            }

            HStack(spacing: 5) {
                AppIcon(name: assistant.provider.iconName, size: 15)
                Text(assistant.currentChat?.title ?? "New Chat")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            IconButton(systemImage: "square.and.pencil", help: "New Chat", tint: .accentColor) { assistant.newChat() }
            Menu {
                Button("New Chat") { assistant.newChat() }
                Button("Delete This Chat", role: .destructive) { assistant.deleteCurrentChat() }
                    .disabled(assistant.currentChat == nil)
                Button("Clear All Chats", role: .destructive) { assistant.clearAllChats() }
                    .disabled(assistant.chats.isEmpty)
                Divider()
                Button("AI Platform…") { app.showingAccountMenu = true }
                SettingsLink { Text("Options…") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(Color.accentColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Options")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

/// Past chats, newest first, with search, rename and delete.
private struct ChatHistoryPopover: View {
    @Environment(AppModel.self) private var app
    let dismiss: () -> Void
    @State private var search = ""
    @State private var renaming: UUID?
    @State private var newTitle = ""

    private var chats: [AIChat] {
        let all = app.assistant.chats.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        guard !search.isEmpty else { return all }
        return all.filter { chat in
            chat.title.localizedCaseInsensitiveContains(search) || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground(in: Capsule())
            .padding(10)
            Divider()
            if chats.isEmpty {
                Text(search.isEmpty ? "No chats yet" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chats) { chat in row(chat) }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 320, height: 380)
    }

    @ViewBuilder
    private func row(_ chat: AIChat) -> some View {
        let isCurrent = chat.id == app.assistant.currentChatID
        HStack(spacing: 8) {
            AppIcon(name: (chat.messages.last { $0.role == .assistant }?.provider ?? .claude).iconName, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                if renaming == chat.id {
                    TextField("Title", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            app.assistant.renameChat(chat.id, to: newTitle)
                            renaming = nil
                        }
                } else {
                    Text(chat.title).font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                }
                Text("\(chat.messages.count) messages · \((chat.updatedAt ?? chat.createdAt).formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard renaming == nil else { return }
            app.assistant.open(chat)
            dismiss()
        }
        .contextMenu {
            Button("Rename") {
                newTitle = chat.title
                renaming = chat.id
            }
            Button("Delete", role: .destructive) { app.assistant.deleteChat(chat.id) }
        }
    }
}

// MARK: - Messages

private struct APIKeyBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let provider = app.assistant.provider
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(name: provider.iconName, size: 22)
                Text("Connect \(provider.displayName)").font(.system(size: 13, weight: .semibold))
            }
            Text("Paste your \(provider.company) API key to chat with \(provider.displayName) about your data. Switch platforms from your profile picture in the toolbar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            APIKeyEditor(provider: provider, compact: true)
        }
        .padding(12)
        .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EmptyChat: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppIcon(name: app.assistant.provider.iconName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask \(app.assistant.provider.displayName)").font(.system(size: 15, weight: .semibold))
                    Text(app.assistant.modelName(for: app.assistant.provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text("Write, explain, optimize and fix SQL. Attach schemas or open tabs as context with the buttons below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { suggestion in
                SuggestionButton(text: suggestion) { app.assistant.draft = suggestion }
            }
        }
    }

    private var suggestions: [String] {
        if let table = app.selectedTableTab?.object.name {
            return ["Explain what the \(table) table stores", "Write a query to find duplicate rows in \(table)", "Suggest indexes for \(table)"]
        }
        return ["Write a query that joins two tables", "Can you explain the difference between an inner join and a left join?", "How do I find the slowest queries?"]
    }
}

private struct SuggestionButton: View {
    let text: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                Text(text).font(.system(size: 12)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct MessageView: View {
    @Environment(AppModel.self) private var app
    let message: AIMessage
    let isLast: Bool
    @State private var isHovering = false
    /// Which answer is shown when the message has alternates (nil: the original).
    @State private var shownAlternate: AIProvider?

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantReply
        }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Spacer(minLength: 24)
            HStack(spacing: 0) {
                IconButton(systemImage: "doc.on.doc", help: "Copy", tint: .secondary) { copy(message.typedText ?? message.text) }
                if isLastQuestion {
                    IconButton(systemImage: "pencil", help: "Edit Question", tint: .secondary) { app.assistant.editLastQuestion() }
                }
            }
            .opacity(isHovering ? 1 : 0)
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.16)))
        }
        .onHover { isHovering = $0 }
    }

    private var isLastQuestion: Bool {
        guard let messages = app.assistant.currentChat?.messages else { return false }
        return messages.last(where: { $0.role == .user })?.id == message.id && !app.assistant.isStreaming
    }

    private var answers: [(provider: AIProvider, model: String?, text: String, note: String?)] {
        [(message.provider ?? .claude, message.model, message.text, message.note)]
            + (message.alternates ?? []).map { ($0.provider, $0.model, $0.text, $0.note) }
    }

    private var assistantReply: some View {
        let assistant = app.assistant
        let comparing = assistant.comparingMessageID == message.id
        let current = answers.first { $0.provider == shownAlternate } ?? answers[0]
        return VStack(alignment: .leading, spacing: 8) {
            if answers.count > 1 || comparing {
                AnswerTabs(answers: answers.map(\.provider), comparing: comparing ? otherProvider : nil, selection: Binding(
                    get: { shownAlternate ?? answers[0].provider },
                    set: { shownAlternate = $0 }
                ))
            }
            if comparing && shownAlternate == otherProvider {
                StreamingReply(provider: otherProvider ?? .chatGPT, text: assistant.compareText, showsAvatar: false)
            } else {
                MarkdownView(text: current.text)
                if let note = current.note {
                    Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 2) {
                IconButton(systemImage: "doc.on.doc", help: "Copy Answer", tint: .accentColor) { copy(current.text) }
                IconButton(systemImage: "plus.rectangle.on.rectangle", help: "Copy SQL to New Query", tint: .accentColor,
                           isEnabled: !MarkdownParser.sqlBlocks(in: current.text).isEmpty) {
                    app.openQuery(text: MarkdownParser.sqlBlocks(in: current.text).joined(separator: "\n\n"))
                }
                if isLast && assistant.canRegenerate {
                    IconButton(systemImage: "arrow.clockwise", help: "Regenerate with \(assistant.provider.displayName)", tint: .accentColor) {
                        assistant.regenerate()
                    }
                }
                if assistant.compareEnabled, let other = otherProvider, !answers.contains(where: { $0.provider == other }), !comparing {
                    Button {
                        shownAlternate = other
                        assistant.compare(message.id, with: other)
                    } label: {
                        HStack(spacing: 3) {
                            AppIcon(name: other.iconName, size: 12)
                            Text("Compare with \(other.displayName)")
                        }
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("See how \(other.displayName) answers the same question")
                }
                Spacer()
                if let model = current.model {
                    HStack(spacing: 3) {
                        AppIcon(name: current.provider.iconName, size: 10)
                        Text(model)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }
            .opacity(isHovering || isLast ? 1 : 0.35)
        }
        .onHover { isHovering = $0 }
    }

    /// The platform Compare would ask (the first other one with a key).
    private var otherProvider: AIProvider? {
        let mine = message.provider ?? .claude
        return AIProvider.allCases.first { $0 != mine && app.assistant.hasAPIKey(for: $0) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "Claude | ChatGPT" switch above an answer that has been compared.
private struct AnswerTabs: View {
    let answers: [AIProvider]
    let comparing: AIProvider?
    @Binding var selection: AIProvider

    var body: some View {
        HStack(spacing: 4) {
            ForEach(answers + (comparing.map { answers.contains($0) ? [] : [$0] } ?? []), id: \.self) { provider in
                Button { selection = provider } label: {
                    HStack(spacing: 4) {
                        AppIcon(name: provider.iconName, size: 13)
                        Text(provider.displayName)
                        if provider == comparing { ProgressView().controlSize(.mini) }
                    }
                    .font(.system(size: 11, weight: selection == provider ? .semibold : .regular))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        if selection == provider {
                            Color.clear.glassBackground(in: Capsule(), interactive: true)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

/// The answer as it streams in, or an animated "Thinking…" before the first words.
private struct StreamingReply: View {
    let provider: AIProvider
    let text: String
    var showsAvatar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                HStack(spacing: 7) {
                    if showsAvatar { AppIcon(name: provider.iconName, size: 16) }
                    Text("\(provider.displayName) is thinking").font(.system(size: 12)).foregroundStyle(.secondary)
                    ThinkingDots()
                }
            } else {
                MarkdownView(text: text, codeActions: false)
            }
        }
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 4) % 4
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle().frame(width: 4, height: 4).opacity(index < step ? 0.8 : 0.2)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct ErrorNote: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
            HStack {
                if app.assistant.canRegenerate {
                    Button("Try Again") { app.assistant.regenerate() }
                }
                Button("Dismiss") { app.assistant.error = nil }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }
}

// MARK: - Composer

/// Input box with attachments, context chips, the assistant/model switch and send.
private struct Composer: View {
    @Environment(AppModel.self) private var app
    @State private var showingSchemas = false
    @State private var showingTabs = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var assistant = app.assistant
        VStack(alignment: .leading, spacing: 7) {
            if !assistant.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(assistant.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                assistant.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                // Sizes the editor to its content, up to ~7 lines.
                Text(assistant.draft.isEmpty ? " " : assistant.draft + " ")
                    .font(.system(size: 12.5))
                    .lineLimit(1...7)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .opacity(0)
                    .accessibilityHidden(true)
                TextEditor(text: $assistant.draft)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .disabled(assistant.isStreaming)
                    .onKeyPress(.return, phases: .down) { press in
                        let command = press.modifiers.contains(.command)
                        let newline = press.modifiers.contains(.shift) || press.modifiers.contains(.option)
                        if assistant.enterSends ? !newline : command {
                            assistant.send()
                            return .handled
                        }
                        return .ignored
                    }
                if assistant.draft.isEmpty {
                    Text("Ask \(assistant.provider.displayName)…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let table = assistant.contextTable {
                        ContextChip(title: table.object.name, systemImage: "tablecells", isOn: assistant.includeTable) {
                            assistant.includeTable.toggle()
                        }
                    }
                    if let schema = assistant.contextSchemaName {
                        ContextChip(title: schema, systemImage: "square.stack.3d.up", isOn: assistant.includeSchema) {
                            assistant.toggleSchemaContext()
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                AssistantPicker()
                Spacer()
                Menu {
                    Button("Attach Schemas…") { showingSchemas = true }
                        .disabled(app.currentContext == nil)
                    Button("Attach Tabs…") { showingTabs = true }
                        .disabled(app.tabs.isEmpty)
                    Divider()
                    Button("Attach File…") { assistant.attachFile() }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach Schema, Tabs or a File")
                if assistant.isStreaming {
                    IconButton(systemImage: "stop.circle.fill", help: "Stop", tint: .red) { assistant.cancel() }
                } else {
                    IconButton(systemImage: "arrow.up.circle.fill", help: assistant.enterSends ? "Send (↩)" : "Send (⌘↩)", tint: .accentColor,
                               isEnabled: !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        assistant.send()
                    }
                }
            }
        }
        .padding(10)
        .glassBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $showingSchemas) { AttachSchemasSheet() }
        .sheet(isPresented: $showingTabs) { AttachTabsSheet() }
    }
}

/// The down arrow next to the assistant: switch platform and model in one menu.
private struct AssistantPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let assistant = app.assistant
        Menu {
            ForEach(AIProvider.allCases) { provider in
                Section(provider.displayName + (assistant.hasAPIKey(for: provider) ? "" : " — no API key")) {
                    ForEach(assistant.models(for: provider)) { model in
                        Button {
                            assistant.select(provider, model: model.id)
                        } label: {
                            if assistant.provider == provider && assistant.selectedModel(for: provider) == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("AI Platform…") { app.showingAccountMenu = true }
        } label: {
            HStack(spacing: 4) {
                AppIcon(name: assistant.provider.iconName, size: 14)
                Text(assistant.provider.displayName).foregroundStyle(.primary)
                Text(assistant.modelName(for: assistant.provider)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct AttachmentChip: View {
    let attachment: AIAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.kind.systemImage).foregroundStyle(Color.accentColor)
            Text(attachment.name).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .help(String(attachment.content.prefix(400)))
    }
}

/// "payment +" chip that adds a table or schema as context for the next message.
private struct ContextChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).foregroundStyle(isOn ? .white : Color.accentColor)
                Text(title).lineLimit(1)
                Image(systemName: isOn ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11))
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn ? Color.accentColor : .clear))
            .overlay(Capsule().strokeBorder(isOn ? .clear : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Included as context — click to remove" : "Add as context")
    }
}

// MARK: - Attach sheets

/// Navicat's "Attach Schemas": pick schemas (or databases) whose structure goes with the next message.
private struct AttachSchemasSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    private var context: DatabaseContext? { app.currentContext }

    /// Schemas on PostgreSQL; the database itself elsewhere ("" stands for no schema).
    private var options: [String] {
        guard let context else { return [] }
        return context.usesSchemas ? context.schemas : [""]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Schemas").font(.headline)
            Text("The assistant gets each schema's tables and columns, which helps it write queries that fit your database.")
                .font(.callout).foregroundStyle(.secondary)
            List(options, id: \.self) { option in
                Toggle(isOn: Binding(get: { chosen.contains(option) }, set: { on in
                    if on { chosen.insert(option) } else { chosen.remove(option) }
                })) {
                    Label(option.isEmpty ? (context?.name ?? "") : option, systemImage: "square.stack.3d.up")
                }
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") {
                    if let context {
                        app.assistant.attachSchemas(chosen.sorted().map { $0.isEmpty ? nil : $0 }, in: context)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
        .onAppear {
            if let schema = app.currentSchema, options.contains(schema) { chosen = [schema] } else if options == [""] { chosen = [""] }
        }
    }
}

/// Navicat's "Attach Tabs": pick open tabs whose content goes with the next message.
private struct AttachTabsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Tabs").font(.headline)
            Text("Queries are attached as SQL; tables and designs as their columns.")
                .font(.callout).foregroundStyle(.secondary)
            List(app.tabs) { tab in
                Toggle(isOn: Binding(get: { chosen.contains(tab.id) }, set: { on in
                    if on { chosen.insert(tab.id) } else { chosen.remove(tab.id) }
                })) {
                    HStack(spacing: 6) {
                        AppIcon(name: tab.systemImage, size: 15)
                        Text(tab.title)
                    }
                }
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") {
                    app.assistant.attachTabs(Array(chosen))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
        .onAppear { if let id = app.selectedTabID { chosen = [id] } }
    }
}
