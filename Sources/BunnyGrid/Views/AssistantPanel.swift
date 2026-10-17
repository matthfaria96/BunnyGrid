import AppKit
import BunnyGridCore
import SwiftUI

/// The right pane's AI tab: chat with Claude or ChatGPT about the current database.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var app
    @State private var showingChatList = false

    private var assistant: AssistantModel { app.assistant }

    var body: some View {
        if assistant.active == nil {
            AIDisabledState()
        } else if showingChatList {
            ManageChatsView { showingChatList = false }
        } else {
            VStack(spacing: 0) {
                AssistantHeader { showingChatList = true }
                messages
                Composer()
                    .padding(8)
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !assistant.hasAPIKey {
                        APIKeyBanner()
                    }
                    if let chat = assistant.currentChat, !chat.messages.isEmpty {
                        ForEach(chat.messages) { message in
                            MessageView(message: message, isLast: message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                    } else if !assistant.isStreaming {
                        EmptyChat()
                    }
                    if assistant.isStreaming {
                        StreamingReply(provider: assistant.provider, name: assistant.active?.name, text: assistant.streamingText)
                    }
                    if let comparing = assistant.assistants.first(where: { $0.id == assistant.comparingAssistantID }) {
                        StreamingReply(provider: comparing.provider, name: comparing.name, text: assistant.compareText)
                    }
                    if !assistant.isStreaming, assistant.comparingAssistantID == nil, !assistant.compareCandidates.isEmpty {
                        CompareOffer(candidates: assistant.compareCandidates)
                    }
                    if let error = assistant.error {
                        ErrorNote(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .environment(\.aiZoom, assistant.chatZoom)
            }
            .onChange(of: assistant.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.compareText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.currentChat?.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: assistant.currentChatID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct AIZoomKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// More Chat Actions › Zoom.
    var aiZoom: Double {
        get { self[AIZoomKey.self] }
        set { self[AIZoomKey.self] = newValue }
    }
}

/// Navicat's AI pane before an assistant exists: the AI mark, a short explanation and Settings.
private struct AIDisabledState: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            AIMark()
            Text(app.assistant.aiEnabled
                 ? "AI Assistant helps you work more efficiently on SQL editing. To get started, add a Claude or ChatGPT assistant in Settings."
                 : "AI Assistant helps you work more efficiently on SQL editing. To get started, you will need to enable AI Assistant and add at least one Claude or ChatGPT assistant in Settings.")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Button("Settings") {
                UserDefaults.standard.set("ai", forKey: "settingsTab")
                openSettings()
            }
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "AI" over chat bubbles with a sparkle, in the assistant's teal.
struct AIMark: View {
    var body: some View {
        let teal = LinearGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.72), Color(red: 0.1, green: 0.65, blue: 0.62)], startPoint: .top, endPoint: .bottom)
        VStack(spacing: 2) {
            Text("AI")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(teal)
            HStack(alignment: .bottom, spacing: 2) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(teal)
                    .offset(y: -10)
            }
        }
        .accessibilityLabel("AI Assistant")
    }
}

// MARK: - Header

/// ≡ · assistant · chat title ⌄ · New Chat · More Chat Actions, as in Navicat's AI pane.
private struct AssistantHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    let showChatList: () -> Void
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var showingInstructions = false

    var body: some View {
        let assistant = app.assistant
        HStack(spacing: 8) {
            IconButton(systemImage: "line.3.horizontal", help: "Manage Chats", tint: .secondary, action: showChatList)
            Divider().frame(height: 16)
            Menu {
                if assistant.chats.isEmpty { Text("No chats yet") }
                ForEach(assistant.chats.prefix(20)) { chat in
                    Button(chat.title) { assistant.open(chat) }
                }
            } label: {
                HStack(spacing: 6) {
                    AppIcon(name: assistant.provider.iconName, size: 16)
                    Text(assistant.currentChat?.title ?? "New Chat")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Spacer(minLength: 4)
            IconButton(systemImage: "plus.bubble", help: "New Chat", tint: .green) { assistant.newChat() }
            Menu {
                Button("View Instructions") { showingInstructions = true }
                Button("Search") { showChatList() }
                Divider()
                Button("Rename Chat") {
                    newTitle = assistant.currentChat?.title ?? ""
                    renaming = true
                }
                .disabled(assistant.currentChat == nil)
                Button("Clear Chat") { if let id = assistant.currentChatID { assistant.clearChat(id) } }
                    .disabled(assistant.currentChat?.messages.isEmpty ?? true)
                Button("Delete Chat", role: .destructive) { assistant.deleteCurrentChat() }
                    .disabled(assistant.currentChat == nil)
                Divider()
                Menu("Zoom") {
                    Button("Zoom In") { assistant.chatZoom = min(assistant.chatZoom + 0.1, 1.6) }
                    Button("Zoom Out") { assistant.chatZoom = max(assistant.chatZoom - 0.1, 0.8) }
                    Button("Actual Size") { assistant.chatZoom = 1 }
                }
                Divider()
                Button("Settings") {
                    UserDefaults.standard.set("ai", forKey: "settingsTab")
                    openSettings()
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(Color.accentColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Chat Actions")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .alert("Rename Chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let id = assistant.currentChatID { assistant.renameChat(id, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .popover(isPresented: $showingInstructions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions · \(assistant.active?.name ?? "")").font(.headline)
                Text((assistant.active?.instruction).flatMap { $0.isEmpty ? nil : $0 } ?? "No instructions. Add them in Settings › AI.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(width: 300, alignment: .leading)
            }
            .padding(14)
        }
    }
}

/// Manage Chats: the chat list replaces the conversation, with search, New Chat and Edit (delete).
private struct ManageChatsView: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    @State private var search = ""
    @State private var editing = false
    @FocusState private var searchFocused: Bool

    private var chats: [AIChat] {
        let all = app.assistant.chats.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        guard !search.isEmpty else { return all }
        return all.filter { chat in
            chat.title.localizedCaseInsensitiveContains(search) || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconButton(systemImage: "xmark", help: "Close", tint: .secondary, action: close)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).focused($searchFocused)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 2 : 1))
                IconButton(systemImage: "plus.bubble", help: "New Chat", tint: .green) {
                    app.assistant.newChat()
                    close()
                }
            }
            .padding(10)
            Button(editing ? "Done" : "Edit") { editing.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chats) { chat in
                        HStack(alignment: .top, spacing: 10) {
                            if editing {
                                Button { app.assistant.deleteChat(chat.id) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 8)
                            }
                            AppIcon(name: (chat.messages.last { $0.role == .assistant }?.provider ?? app.assistant.provider).iconName, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text((chat.updatedAt ?? chat.createdAt).formatted(.relative(presentation: .named)))
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                Text(chat.messages.first?.typedText ?? chat.messages.first?.text ?? "")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !editing else { return }
                            app.assistant.open(chat)
                            close()
                        }
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .overlay {
                if chats.isEmpty {
                    Text(search.isEmpty ? "No chats yet" : "No matches").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { searchFocused = true }
    }
}

// MARK: - Messages

private struct APIKeyBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let active = app.assistant.active {
            banner(active)
        }
    }

    private func banner(_ active: AIAssistantConfig) -> some View {
        let provider = active.provider
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(name: provider.iconName, size: 22)
                Text("Connect \(provider.displayName)").font(.system(size: 13, weight: .semibold))
            }
            Text("Paste your \(provider.company) API key to chat with \(provider.displayName) about your data. Switch platforms from your profile picture in the toolbar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            APIKeyEditor(assistant: active, compact: true)
        }
        .padding(12)
        .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Here are some questions you can try:" with suggestion bubbles on the right, as in Navicat.
private struct EmptyChat: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Spacer(minLength: 60)
            Text("Here are some questions you can try:")
                .font(.system(size: 13, weight: .medium))
            ForEach(suggestions, id: \.self) { suggestion in
                SuggestionButton(text: suggestion) {
                    app.assistant.draft = suggestion
                    app.assistant.send()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var suggestions: [String] {
        if let table = app.selectedTableTab?.object.name {
            return ["What does the \(table) table store, and how is it used?",
                    "What SQL query would I use to find duplicate rows in \(table)?",
                    "Which indexes would speed up queries on \(table)?"]
        }
        return ["How can I reduce data redundancy in my database structure?",
                "What SQL query would I use to find customers who haven't placed an order in the last year?",
                "What are some common pitfalls to avoid when simplifying a database structure?"]
    }
}

private struct SuggestionButton: View {
    let text: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12.5))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(isHovering ? 0.12 : 0.04)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A user message (blue bubble on the right) or an answer (assistant header, then a gray bubble).
private struct MessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.aiZoom) private var zoom
    let message: AIMessage
    let isLast: Bool
    @State private var isHovering = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: answer
        }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Spacer(minLength: 30)
            HStack(spacing: 0) {
                IconButton(systemImage: "doc.on.doc", help: "Copy", tint: .secondary) { copy(message.typedText ?? message.text) }
                if isLastQuestion {
                    IconButton(systemImage: "pencil", help: "Edit Question", tint: .secondary) { app.assistant.editLastQuestion() }
                }
            }
            .opacity(isHovering ? 1 : 0)
            Text(message.text)
                .font(.system(size: 12.5 * zoom))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
        }
        .onHover { isHovering = $0 }
    }

    private var isLastQuestion: Bool {
        guard let messages = app.assistant.currentChat?.messages else { return false }
        return messages.last(where: { $0.role == .user })?.id == message.id && !app.assistant.isStreaming
    }

    private var answer: some View {
        let provider = message.provider ?? .claude
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AppIcon(name: provider.iconName, size: 16)
                Text(message.assistantName ?? provider.displayName).font(.system(size: 12.5, weight: .semibold))
                if let date = message.createdAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(date.timeIntervalSinceNow > -60 ? "Just now" : date.formatted(.relative(presentation: .named)))
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if isHovering, let model = message.model {
                    Text(model).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(text: message.text, fontSize: 12.5 * zoom)
                if let note = message.note {
                    Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)))
            HStack(spacing: 2) {
                IconButton(systemImage: "doc.on.doc", help: "Copy Raw Message", tint: .accentColor) { copy(message.text) }
                if isLast && app.assistant.canRegenerate && message.isComparison != true {
                    IconButton(systemImage: "arrow.clockwise", help: "Regenerate", tint: .accentColor) { app.assistant.regenerate() }
                }
            }
            .opacity(isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "You can compare this answer with…" and a capsule per other assistant.
private struct CompareOffer: View {
    @Environment(AppModel.self) private var app
    let candidates: [AIAssistantConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You can compare this answer with...").font(.system(size: 12.5))
            FlowLayout(spacing: 6) {
                ForEach(candidates) { candidate in
                    Button {
                        if let last = app.assistant.currentChat?.messages.last { app.assistant.compare(last.id, with: candidate) }
                    } label: {
                        HStack(spacing: 5) {
                            AppIcon(name: candidate.provider.iconName, size: 14)
                            Text(candidate.name).font(.system(size: 12, weight: .semibold))
                            Text("(\(app.assistant.modelName(for: candidate)))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The answer as it streams in, or an animated "Thinking…" before the first words.
private struct StreamingReply: View {
    let provider: AIProvider
    var name: String?
    let text: String
    var showsAvatar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                HStack(spacing: 7) {
                    if showsAvatar { AppIcon(name: provider.iconName, size: 16) }
                    Text("\(name ?? provider.displayName) is thinking").font(.system(size: 12)).foregroundStyle(.secondary)
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
                    Text("Ask AI Assistant...")
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
                    if let context = app.currentContext {
                        Button("Attach Database “\(context.name)”") {
                            assistant.attachSchemas([context.usesSchemas ? (app.currentSchema ?? context.defaultSchema) : nil], in: context)
                        }
                    }
                    Button("Attach Schemas") { showingSchemas = true }
                        .disabled(app.currentContext == nil)
                    Button("Attach Tabs") { showingTabs = true }
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
                    IconButton(systemImage: "paperplane", help: assistant.enterSends ? "Send (↩)" : "Send (⌘↩)", tint: .accentColor,
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
            Section("AI Assistants") {
                ForEach(assistant.assistants) { config in
                    Button {
                        assistant.activate(config.id)
                    } label: {
                        let title = config.name + (assistant.hasAPIKey(for: config) ? "" : " — no API key")
                        if assistant.active?.id == config.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            if let active = assistant.active {
                Section("Model for \(active.name)") {
                    ForEach(assistant.models(for: active.provider)) { option in
                        Button {
                            assistant.setModel(option.id, for: active)
                        } label: {
                            if active.model == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                        }
                    }
                }
            }
            Divider()
            Button("AI Platform…") { app.showingAccountMenu = true }
        } label: {
            PickerLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct PickerLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let assistant = app.assistant
        HStack(spacing: 5) {
            AppIcon(name: assistant.provider.iconName, size: 14)
            Text(assistant.active?.name ?? "No assistant").fontWeight(.semibold).foregroundStyle(.primary)
            Text("(\(assistant.activeModelName))").foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
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
