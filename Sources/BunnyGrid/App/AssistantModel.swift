import AppKit
import BunnyGridCore
import Foundation
import Observation

struct AIMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    /// What the chat shows.
    var text: String
    /// What the API receives: user text with the context and attachments prepended,
    /// or the assistant's content blocks, echoed back unchanged.
    var apiContent: [JSONValue]
    /// Model that answered, and notes such as a refusal or a fallback.
    var model: String?
    var note: String?
    /// Platform that answered (nil in chats saved before ChatGPT support: those were Claude).
    var provider: AIProvider?
}

struct AIChat: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var messages: [AIMessage] = []
    var createdAt = Date()
}

/// A text file attached to the next message.
struct AIAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let content: String
}

/// Whether a provider's API key has been checked against its API.
enum KeyVerification: Equatable {
    case unknown
    case checking
    case connected
    case failed(String)
}

/// The AI Assistant pane: chats with Claude or ChatGPT about the current database.
@MainActor
@Observable
final class AssistantModel {
    private(set) var chats: [AIChat] = []
    var currentChatID: UUID?
    /// The platform answering new messages; switched from the profile picture or the composer.
    var provider: AIProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider") }
    }
    var claudeModel: ClaudeModel = ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .opus {
        didSet { UserDefaults.standard.set(claudeModel.rawValue, forKey: "claudeModel") }
    }
    var openAIModel: String = UserDefaults.standard.string(forKey: "openAIModel") ?? OpenAIModels.defaultModel {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }
    /// OpenAI models for the picker: the suggested ones until the account's list arrives.
    private(set) var openAIModels: [AIModelOption] = OpenAIModels.suggested
    /// Keys saved in the Keychain, read off the main thread at launch.
    private(set) var storedKeys: [AIProvider: String] = [:]
    private(set) var verification: [AIProvider: KeyVerification] = [:]
    var draft = ""
    var includeTable = false
    var includeSchema = false
    var attachments: [AIAttachment] = []
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    var error: String?
    var isExpanded = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static let apiKeyAccount = "api-key"

    init(storeURL: URL) {
        self.storeURL = storeURL
        load()
        loadKeys()
    }

    var currentChat: AIChat? {
        chats.first { $0.id == currentChatID }
    }

    // MARK: - Platforms and keys

    nonisolated private static func keychain(_ provider: AIProvider) -> KeychainStore {
        KeychainStore(service: provider.keychainService)
    }

    /// Keychain reads can block on an access prompt (ad hoc builds), so they run detached.
    private func loadKeys() {
        Task {
            let keys = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, Self.keychain($0).password(account: Self.apiKeyAccount) ?? "") })
            }.value
            storedKeys = keys
        }
    }

    func apiKey(for provider: AIProvider) -> String {
        if let key = storedKeys[provider], !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment[provider.environmentKey] ?? ""
    }

    func hasAPIKey(for provider: AIProvider) -> Bool { !apiKey(for: provider).isEmpty }

    var hasAPIKey: Bool { hasAPIKey(for: provider) }

    func storedAPIKey(for provider: AIProvider) -> String { storedKeys[provider] ?? "" }

    /// True when the key comes from the environment rather than the Keychain.
    func usesEnvironmentKey(_ provider: AIProvider) -> Bool {
        storedAPIKey(for: provider).isEmpty && hasAPIKey(for: provider)
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        storedKeys[provider] = key
        verification[provider] = .unknown
        Task.detached(priority: .userInitiated) {
            Self.keychain(provider).setPassword(key.isEmpty ? nil : key, account: Self.apiKeyAccount)
        }
        if !key.isEmpty { verify(provider) }
    }

    /// Checks the key against the platform (listing its models) and refreshes the OpenAI model list.
    func verify(_ provider: AIProvider) {
        let key = apiKey(for: provider)
        guard !key.isEmpty else {
            verification[provider] = .unknown
            return
        }
        verification[provider] = .checking
        Task {
            do {
                switch provider {
                case .claude:
                    _ = try await AnthropicClient(apiKey: key).listModels()
                case .chatGPT:
                    let ids = try await OpenAIClient(apiKey: key).listModels()
                    openAIModels = OpenAIModels.options(from: ids)
                    if !openAIModels.contains(where: { $0.id == openAIModel }), let first = openAIModels.first {
                        openAIModel = first.id
                    }
                }
                verification[provider] = .connected
            } catch {
                verification[provider] = .failed(error.localizedDescription)
            }
        }
    }

    func verifyIfNeeded(_ provider: AIProvider) {
        guard hasAPIKey(for: provider), (verification[provider] ?? .unknown) == .unknown else { return }
        verify(provider)
    }

    func models(for provider: AIProvider) -> [AIModelOption] {
        provider == .claude ? provider.suggestedModels : openAIModels
    }

    func selectedModel(for provider: AIProvider) -> String {
        provider == .claude ? claudeModel.rawValue : openAIModel
    }

    func select(_ provider: AIProvider, model: String) {
        self.provider = provider
        switch provider {
        case .claude: if let model = ClaudeModel(rawValue: model) { claudeModel = model }
        case .chatGPT: openAIModel = model
        }
    }

    func modelName(for provider: AIProvider) -> String {
        let id = selectedModel(for: provider)
        return models(for: provider).first { $0.id == id }?.name ?? id
    }

    // MARK: - Chats

    func newChat() {
        cancel()
        currentChatID = nil
        draft = ""
        attachments = []
        error = nil
    }

    func deleteCurrentChat() {
        guard let id = currentChatID else { return }
        cancel()
        chats.removeAll { $0.id == id }
        currentChatID = chats.first?.id
        save()
    }

    func clearAllChats() {
        cancel()
        chats = []
        currentChatID = nil
        save()
    }

    // MARK: - Context

    /// The table the context chip offers: the open table tab's table.
    var contextTable: TableTabModel? { app?.selectedTableTab }

    var contextSchemaName: String? {
        if let table = contextTable { return table.object.schema ?? table.databaseName }
        return app?.currentSchema ?? app?.currentContext?.name
    }

    private func contextBlock() -> String {
        guard let app else { return "" }
        var lines: [String] = []
        let context = app.currentContext
        if let context, let session = context.session {
            lines.append("Engine: \(session.config.kind.displayName) \(session.serverVersion)")
            lines.append("Database: \(context.name)" + (app.currentSchema.map { ", schema: \($0)" } ?? ""))
        }
        if includeTable, let table = contextTable {
            let columns = table.columns.map { "  \($0.name) \($0.dataType)\($0.isPrimaryKey ? " PRIMARY KEY" : "")\($0.nullable ? "" : " NOT NULL")" }
            lines.append("Table \(table.object.qualifiedName):\n" + columns.joined(separator: "\n"))
        }
        if includeSchema, let context {
            let schema = context.usesSchemas ? app.currentSchema : nil
            let objects = (context.objects(in: schema) ?? []).filter { $0.kind != .routine }
            let described = objects.map { object -> String in
                if let columns = context.cachedColumns(for: object.name) { return "  \(object.name)(\(columns.joined(separator: ", ")))" }
                return "  \(object.name)"
            }
            lines.append("Objects in \(schema ?? context.name):\n" + described.joined(separator: "\n"))
        }
        return lines.isEmpty ? "" : "<database_context>\n" + lines.joined(separator: "\n") + "\n</database_context>\n\n"
    }

    /// Column names of every table in the schema, so the schema chip can describe them.
    private func prefetchSchemaColumns() {
        guard includeSchema, let app, let context = app.currentContext else { return }
        let schema = context.usesSchemas ? app.currentSchema : nil
        let names = (context.objects(in: schema) ?? []).filter { $0.kind != .routine }.map(\.name)
        context.prefetchColumns(for: names.map { "FROM \($0)" }.joined(separator: " "))
    }

    func toggleSchemaContext() {
        includeSchema.toggle()
        prefetchSchemaColumns()
    }

    func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else {
                error = "\(url.lastPathComponent) is larger than 1 MB. Attach a smaller file or paste the relevant part."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                error = "\(url.lastPathComponent) is not a text file."
                return
            }
            attachments.append(AIAttachment(name: url.lastPathComponent, content: text))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sending

    private static let systemPrompt = """
        You are the AI assistant inside BunnyGrid, a native macOS database client. You help the user \
        write, explain, optimize and fix SQL for the database they are connected to. Use the SQL dialect \
        of their engine. Put runnable SQL in fenced ```sql code blocks so it can be opened in the query \
        editor. Be concise; explain briefly what a query does and note assumptions about the schema. \
        A <database_context> block, when present, describes the user's current database, table or schema.
        """

    /// Starts a request from the toolbar (e.g. "Fill with AI") with the table chip on.
    func ask(_ prompt: String, includeTable: Bool) {
        app?.showAssistant = true
        app?.rightPane = .ai
        self.includeTable = includeTable
        draft = prompt
        send()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        let provider = provider
        guard hasAPIKey(for: provider) else {
            error = provider.missingKeyMessage()
            return
        }
        error = nil

        var apiText = contextBlock()
        for attachment in attachments {
            apiText += "<attached_file name=\"\(attachment.name)\">\n\(attachment.content)\n</attached_file>\n\n"
        }
        apiText += text
        let display = attachments.isEmpty ? text : text + "\n📎 " + attachments.map(\.name).joined(separator: ", ")
        let message = AIMessage(role: .user, text: display, apiContent: [.object(["type": .string("text"), "text": .string(apiText)])])

        if currentChatID == nil {
            let chat = AIChat(title: String(text.prefix(40)))
            chats.insert(chat, at: 0)
            currentChatID = chat.id
        }
        guard let chatID = currentChatID else { return }
        append(message, to: chatID)
        draft = ""
        attachments = []

        let history = (chats.first { $0.id == chatID }?.messages ?? []).map { message -> JSONValue in
            .object(["role": .string(message.role.rawValue), "content": .array(message.apiContent)])
        }
        let key = apiKey(for: provider)
        let stream = switch provider {
        case .claude: AnthropicClient(apiKey: key).streamMessage(model: claudeModel, system: Self.systemPrompt, messages: history)
        case .chatGPT: OpenAIClient(apiKey: key).streamResponse(model: openAIModel, instructions: Self.systemPrompt, messages: history)
        }
        isStreaming = true
        streamingText = ""
        task = Task {
            defer {
                isStreaming = false
                streamingText = ""
            }
            var fallbackNote: String?
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let piece):
                        streamingText += piece
                    case .fallback(let from, let to):
                        fallbackNote = "\(from) declined this request; \(to) answered instead."
                    case .finished(let turn):
                        var note = fallbackNote
                        if turn.wasRefused {
                            note = "\(provider.displayName) declined to answer this request."
                        } else if turn.stopReason == "max_tokens" {
                            note = "The answer was cut off at the output limit."
                        }
                        // A refused turn with no content can't be echoed back; keep it out of the API history.
                        let content = turn.echoContent.isEmpty ? [JSONValue.object(["type": .string("text"), "text": .string(turn.text.isEmpty ? "(no answer)" : turn.text)])] : turn.echoContent
                        append(AIMessage(role: .assistant, text: turn.text, apiContent: content, model: turn.model, note: note, provider: provider), to: chatID)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                // Drop the unanswered user message so the conversation stays valid (user/assistant alternation).
                removeLastMessage(if: .user, from: chatID)
                draft = text
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func append(_ message: AIMessage, to chatID: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].messages.append(message)
        save()
    }

    private func removeLastMessage(if role: AIMessage.Role, from chatID: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }), chats[index].messages.last?.role == role else { return }
        chats[index].messages.removeLast()
        if chats[index].messages.isEmpty {
            chats.remove(at: index)
            currentChatID = nil
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        chats = (try? decoder.decode([AIChat].self, from: data)) ?? []
        currentChatID = chats.first?.id
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(chats) else { return }
        let url = storeURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
