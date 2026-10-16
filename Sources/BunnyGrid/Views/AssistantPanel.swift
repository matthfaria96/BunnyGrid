import AppKit
import BunnyGridCore
import SwiftUI

/// The right pane: chat with Claude about the current database.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var app

    private var assistant: AssistantModel { app.assistant }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            Composer()
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                if assistant.chats.isEmpty { Text("No chats yet") }
                ForEach(assistant.chats) { chat in
                    Button(chat.title) { assistant.currentChatID = chat.id }
                }
                Divider()
                Button("Clear All Chats", role: .destructive) { assistant.clearAllChats() }
                    .disabled(assistant.chats.isEmpty)
            } label: {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Chats")

            Menu {
                ForEach(assistant.chats) { chat in
                    Button(chat.title) { assistant.currentChatID = chat.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle").foregroundStyle(.orange)
                    Text(assistant.currentChat?.title ?? "New Chat")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            IconButton(systemImage: "plus.bubble", help: "New Chat", tint: .accentColor) { assistant.newChat() }
            Menu {
                Button("Delete This Chat", role: .destructive) { assistant.deleteCurrentChat() }
                    .disabled(assistant.currentChat == nil)
                Divider()
                SettingsLink { Text("AI Settings…") }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            IconButton(systemImage: assistant.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: assistant.isExpanded ? "Narrow" : "Widen", tint: .accentColor) {
                assistant.isExpanded.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !assistant.hasAPIKey {
                        APIKeyBanner()
                    }
                    if let chat = assistant.currentChat {
                        ForEach(chat.messages) { message in
                            MessageView(message: message)
                        }
                    } else if !assistant.isStreaming {
                        EmptyChat()
                    }
                    if assistant.isStreaming {
                        VStack(alignment: .leading, spacing: 6) {
                            if assistant.streamingText.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").foregroundStyle(.secondary).font(.system(size: 12))
                                }
                            } else {
                                MarkdownText(text: assistant.streamingText)
                            }
                        }
                    }
                    if let error = assistant.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: assistant.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.currentChat?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct APIKeyBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect the AI Assistant", systemImage: "key.fill").font(.system(size: 13, weight: .semibold))
            Text("Add your Anthropic API key in Settings to chat with Claude about your data. The key is stored in your Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            SettingsLink { Text("Open Settings…") }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

private struct EmptyChat: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(.orange)
                Text("Ask AI Assistant").font(.system(size: 14, weight: .semibold))
            }
            Text("Write, explain, optimize and fix SQL. Add the open table or schema as context with the chips below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    app.assistant.draft = suggestion
                } label: {
                    Text(suggestion)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestions: [String] {
        if let table = app.selectedTableTab?.object.name {
            return ["Explain what the \(table) table stores", "Write a query to find duplicate rows in \(table)", "Suggest indexes for \(table)"]
        }
        return ["Write a query that joins two tables", "Explain the difference between LEFT and INNER JOIN", "How do I find the slowest queries?"]
    }
}

private struct MessageView: View {
    @Environment(AppModel.self) private var app
    let message: AIMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: message.text)
                if let note = message.note {
                    Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange)
                }
                HStack(spacing: 4) {
                    IconButton(systemImage: "arrow.turn.down.right", help: "Open SQL in a New Query", tint: .accentColor,
                               isEnabled: !MarkdownText.sqlBlocks(in: message.text).isEmpty) {
                        app.openQuery(text: MarkdownText.sqlBlocks(in: message.text).joined(separator: "\n\n"))
                    }
                    IconButton(systemImage: "doc.on.doc", help: "Copy Answer", tint: .accentColor) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    Spacer()
                    if let model = message.model {
                        Text(model).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// Renders the assistant's Markdown: paragraphs with inline styles, and fenced code blocks.
struct MarkdownText: View {
    @Environment(AppModel.self) private var app
    let text: String

    private enum Segment: Hashable {
        case prose(String)
        case code(language: String, body: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.inline(prose))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let body):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "code" : language).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            if ["sql", "", "postgresql", "mysql", "sqlite"].contains(language.lowercased()) {
                                Button("Open in Query") { app.openQuery(text: body) }
                                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.accentColor)
                            }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(body, forType: .string)
                            }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(Self.highlightSQL(body))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if code != nil {
                    segments.append(.code(language: language, body: code!.joined(separator: "\n")))
                    code = nil
                } else {
                    if !prose.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(.prose(prose.joined(separator: "\n")))
                    }
                    prose = []
                    language = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code!.append(line)
            } else {
                prose.append(line)
            }
        }
        // An unterminated fence while streaming still renders as code.
        if let code { segments.append(.code(language: language, body: code.joined(separator: "\n"))) }
        if !prose.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.prose(prose.joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        return segments
    }

    static func sqlBlocks(in text: String) -> [String] {
        segments(text).compactMap { segment in
            if case .code(let language, let body) = segment, ["sql", "", "postgresql", "mysql", "sqlite"].contains(language.lowercased()) {
                return body
            }
            return nil
        }
    }

    /// Bold, italics, links and `code` (in red monospace, as Navicat's assistant shows it).
    private static func inline(_ markdown: String) -> AttributedString {
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            // Headings and bullets aren't handled by inline Markdown; keep them readable.
            var line = line
            if line.hasPrefix("### ") || line.hasPrefix("## ") || line.hasPrefix("# ") {
                line = "**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            return line
        }
        var result = (try? AttributedString(markdown: lines.joined(separator: "\n"), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].foregroundColor = .red
            result[run.range].font = .system(size: 12, design: .monospaced)
        }
        return result
    }

    static func highlightSQL(_ sql: String) -> AttributedString {
        var result = AttributedString(sql)
        let ns = sql as NSString
        let rules: [(String, NSRegularExpression.Options, Color)] = [
            ("\\b(" + SQLKeywords.all.joined(separator: "|") + ")\\b", .caseInsensitive, .blue),
            ("\\b\\d+(\\.\\d+)?\\b", [], .purple),
            ("'(?:[^']|'')*'?", [], .red),
            ("--[^\\n]*", [], .secondary),
        ]
        for (pattern, options, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            for match in regex.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: sql),
                      let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[lower..<upper].foregroundColor = color
            }
        }
        return result
    }
}

/// Input box with context chips, model picker, attachment and send buttons.
private struct Composer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var assistant = app.assistant
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask AI Assistant...", text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .onSubmit { assistant.send() }
                .disabled(assistant.isStreaming)

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
                    ForEach(assistant.attachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text(attachment.name).lineLimit(1)
                            Button {
                                assistant.attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(ClaudeModel.allCases) { model in
                        Button {
                            assistant.model = model
                        } label: {
                            if assistant.model == model { Label(model.displayName, systemImage: "checkmark") } else { Text(model.displayName) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle").foregroundStyle(.orange)
                        Text("Claude").foregroundStyle(.primary)
                        Text("(\(assistant.model.rawValue))").foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                IconButton(systemImage: "paperclip", help: "Attach a Text File", tint: .accentColor) { assistant.attachFile() }
                if assistant.isStreaming {
                    IconButton(systemImage: "stop.circle.fill", help: "Stop", tint: .red) { assistant.cancel() }
                } else {
                    IconButton(systemImage: "arrow.up.circle.fill", help: "Send (Return)", tint: .accentColor,
                               isEnabled: !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        assistant.send()
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
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
