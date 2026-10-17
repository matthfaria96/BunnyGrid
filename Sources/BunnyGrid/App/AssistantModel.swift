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
    /// For user messages: what was typed, so Edit can put it back in the composer.
    var typedText: String?
    /// Answers to the same question from the other assistants ("Compare with Other Assistants").
    var alternates: [AIAlternate]?
}

/// Another assistant's answer to the same question; display only, never sent back to the API.
struct AIAlternate: Codable, Identifiable, Hashable {
    var id = UUID()
    var provider: AIProvider
    var model: String?
    var text: String
    var note: String?
}

struct AIChat: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var messages: [AIMessage] = []
    var createdAt = Date()
    var updatedAt: Date?
}

/// Context attached to the next message: a file, a schema's structure or an open tab.
struct AIAttachment: Identifiable, Hashable {
    enum Kind: Hashable {
        case file, schema, tab

        var systemImage: String {
            switch self {
            case .file: "paperclip"
            case .schema: "square.stack.3d.up"
            case .tab: "rectangle.on.rectangle"
            }
        }

        var tag: String {
            switch self {
            case .file: "attached_file"
            case .schema: "attached_schema"
            case .tab: "attached_tab"
            }
        }
    }

    let id = UUID()
    let kind: Kind
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

/// The AI Assistant: chats with Claude or ChatGPT about the current database, plus the editor's Ask AI actions.
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
    /// Max Tokens, Effort and Instruction per platform.
    var requestOptions: [AIProvider: AIRequestOptions] = AssistantModel.loadOptions() {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: requestOptions.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(encoded), forKey: "aiRequestOptions")
        }
    }
    /// Navicat's "Action for Enter key": send, or start a new line (then ⌘↩ sends).
    var enterSends = UserDefaults.standard.object(forKey: "aiEnterSends") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enterSends, forKey: "aiEnterSends") }
    }
    /// Navicat's "Enable Compare with Other Assistants".
    var compareEnabled = UserDefaults.standard.object(forKey: "aiCompareEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(compareEnabled, forKey: "aiCompareEnabled") }
    }
    /// OpenAI models for the picker: the suggested ones until the account's list arrives.
    private(set) var openAIModels: [AIModelOption] = OpenAIModels.suggested
    /// Keys saved in the Keychain, read off the main thread at launch.
    private(set) var storedKeys: [AIProvider: String] = [:]
    private(set) var verification: [AIProvider: KeyVerification] = [:]
    /// Saved Ask AI actions from the query editor.
    private(set) var actions: [AIAction] = []

    var draft = ""
    var includeTable = false
    var includeSchema = false
    var attachments: [AIAttachment] = []
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    /// The assistant message whose answer from another platform is streaming in.
    private(set) var comparingMessageID: UUID?
    private(set) var compareText = ""
    var error: String?
    var isExpanded = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let actionStore: JSONListStore<AIAction>
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var compareTask: Task<Void, Never>?

    nonisolated static let apiKeyAccount = "api-key"

    init(storeURL: URL) {
        self.storeURL = storeURL
        actionStore = JSONListStore(fileURL: storeURL.deletingLastPathComponent().appending(path: "ai-actions.json"))
        actions = (try? actionStore.load()) ?? []
        load()
        loadKeys()
    }

    var currentChat: AIChat? {
        chats.first { $0.id == currentChatID }
    }

    // MARK: - Platforms and keys

    /// `BUNNYGRID_ANTHROPIC_BASE_URL` / `BUNNYGRID_OPENAI_BASE_URL` point a platform at a proxy or a local mock.
    static func baseURL(for provider: AIProvider) -> URL? {
        let name = provider == .claude ? "BUNNYGRID_ANTHROPIC_BASE_URL" : "BUNNYGRID_OPENAI_BASE_URL"
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private static func anthropic(_ key: String) -> AnthropicClient {
        baseURL(for: .claude).map { AnthropicClient(apiKey: key, baseURL: $0) } ?? AnthropicClient(apiKey: key)
    }

    private static func openAI(_ key: String) -> OpenAIClient {
        baseURL(for: .chatGPT).map { OpenAIClient(apiKey: key, baseURL: $0) } ?? OpenAIClient(apiKey: key)
    }

    nonisolated private static func keychain(_ provider: AIProvider) -> KeychainStore {
        KeychainStore(service: provider.keychainService)
    }

    private static func loadOptions() -> [AIProvider: AIRequestOptions] {
        guard let data = UserDefaults.standard.data(forKey: "aiRequestOptions"),
              let decoded = try? JSONDecoder().decode([String: AIRequestOptions].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in AIProvider(rawValue: key).map { ($0, value) } })
    }

    func options(for provider: AIProvider) -> AIRequestOptions {
        requestOptions[provider] ?? AIRequestOptions()
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
                    _ = try await Self.anthropic(key).listModels()
                case .chatGPT:
                    let ids = try await Self.openAI(key).listModels()
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

    /// The other platforms that could answer the same question, for Compare.
    var compareProviders: [AIProvider] {
        AIProvider.allCases.filter { $0 != provider && hasAPIKey(for: $0) }
    }

    /// One streamed request to `provider` with its current model and options.
    func stream(_ provider: AIProvider, messages: [JSONValue], system: String = AIPrompts.systemPrompt) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        let key = apiKey(for: provider)
        let options = options(for: provider)
        return switch provider {
        case .claude: Self.anthropic(key).streamMessage(model: claudeModel, system: system, messages: messages, options: options)
        case .chatGPT: Self.openAI(key).streamResponse(model: openAIModel, instructions: system, messages: messages, options: options)
        }
    }

    // MARK: - Chats

    func newChat() {
        cancel()
        currentChatID = nil
        draft = ""
        attachments = []
        error = nil
    }

    func deleteChat(_ id: UUID) {
        if id == currentChatID { cancel() }
        chats.removeAll { $0.id == id }
        if currentChatID == id { currentChatID = chats.first?.id }
        save()
    }

    func deleteCurrentChat() {
        guard let id = currentChatID else { return }
        deleteChat(id)
    }

    func renameChat(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = title
        save()
    }

    func clearAllChats() {
        cancel()
        chats = []
        currentChatID = nil
        save()
    }

    func open(_ chat: AIChat) {
        cancel()
        currentChatID = chat.id
        error = nil
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
            lines.append("Engine: " + AIPrompts.engineLabel(engine: session.config.kind.displayName, version: session.serverVersion))
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
            attachments.append(AIAttachment(kind: .file, name: url.lastPathComponent, content: text))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Navicat's "Attach Schemas": the structure of each chosen schema goes with the next message.
    func attachSchemas(_ schemas: [String?], in context: DatabaseContext) {
        Task {
            for schema in schemas {
                let description = await AIContextBuilder.schemaDescription(context: context, schema: schema)
                let name = context.location(schema: schema)
                attachments.removeAll { $0.kind == .schema && $0.name == name }
                attachments.append(AIAttachment(kind: .schema, name: name, content: description.isEmpty ? "(no tables)" : description))
            }
        }
    }

    /// Navicat's "Attach Tabs": what each chosen tab shows (a query's SQL, a table's structure).
    func attachTabs(_ ids: [UUID]) {
        guard let app else { return }
        for tab in app.tabs where ids.contains(tab.id) {
            let content: String
            switch tab {
            case .query(let model):
                content = model.text
            case .table(let model):
                content = "Table \(model.object.qualifiedName):\n" + model.columns.map { "  \($0.name) \($0.dataType)\($0.isPrimaryKey ? " PRIMARY KEY" : "")\($0.nullable ? "" : " NOT NULL")" }.joined(separator: "\n")
            case .design(let model):
                content = "Table design \(model.tableName):\n" + model.columns.map { "  \($0.name) \($0.type)" }.joined(separator: "\n")
            }
            attachments.removeAll { $0.kind == .tab && $0.name == tab.title }
            attachments.append(AIAttachment(kind: .tab, name: tab.title, content: content))
        }
    }

    // MARK: - Sending

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
        guard hasAPIKey(for: provider) else {
            error = provider.missingKeyMessage()
            return
        }
        error = nil

        var apiText = contextBlock()
        for attachment in attachments {
            apiText += "<\(attachment.kind.tag) name=\"\(attachment.name)\">\n\(attachment.content)\n</\(attachment.kind.tag)>\n\n"
        }
        apiText += text
        let display = attachments.isEmpty ? text : text + "\n📎 " + attachments.map(\.name).joined(separator: ", ")
        let message = AIMessage(role: .user, text: display, apiContent: [.object(["type": .string("text"), "text": .string(apiText)])], typedText: text)

        if currentChatID == nil {
            let chat = AIChat(title: String(text.prefix(40)))
            chats.insert(chat, at: 0)
            currentChatID = chat.id
        }
        guard let chatID = currentChatID else { return }
        append(message, to: chatID)
        draft = ""
        attachments = []
        answer(chatID: chatID, restoreDraft: text)
    }

    /// Streams the reply to the chat's last (user) message with the current platform.
    private func answer(chatID: UUID, restoreDraft: String?) {
        let history = apiHistory(chats.first { $0.id == chatID }?.messages ?? [])
        let provider = provider
        let stream = stream(provider, messages: history)
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
                        let note = Self.note(for: turn, provider: provider) ?? fallbackNote
                        // A refused turn with no content can't be echoed back; keep it out of the API history.
                        let content = turn.echoContent.isEmpty ? [JSONValue.object(["type": .string("text"), "text": .string(turn.text.isEmpty ? "(no answer)" : turn.text)])] : turn.echoContent
                        append(AIMessage(role: .assistant, text: turn.text, apiContent: content, model: turn.model, note: note, provider: provider), to: chatID)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                if let restoreDraft {
                    // Drop the unanswered user message so the conversation stays valid (user/assistant alternation).
                    removeLastMessage(if: .user, from: chatID)
                    draft = restoreDraft
                }
            }
        }
    }

    private static func note(for turn: AssistantTurn, provider: AIProvider) -> String? {
        if turn.wasRefused { return "\(provider.displayName) declined to answer this request." }
        if turn.stopReason == "max_tokens" { return "The answer was cut off at the output limit (Max Tokens in Settings)." }
        return nil
    }

    private func apiHistory(_ messages: [AIMessage]) -> [JSONValue] {
        messages.map { .object(["role": .string($0.role.rawValue), "content": .array($0.apiContent)]) }
    }

    /// Asks again for the last answer, with the current platform and model.
    func regenerate() {
        guard !isStreaming, let chatID = currentChatID, let index = chats.firstIndex(where: { $0.id == chatID }),
              chats[index].messages.last?.role == .assistant else { return }
        guard hasAPIKey(for: provider) else {
            error = provider.missingKeyMessage()
            return
        }
        chats[index].messages.removeLast()
        save()
        error = nil
        answer(chatID: chatID, restoreDraft: nil)
    }

    /// Puts the last question back in the composer and removes it (and its answer) from the chat.
    func editLastQuestion() {
        guard !isStreaming, let chatID = currentChatID, let index = chats.firstIndex(where: { $0.id == chatID }),
              let lastUser = chats[index].messages.lastIndex(where: { $0.role == .user }) else { return }
        let message = chats[index].messages[lastUser]
        draft = message.typedText ?? message.text
        chats[index].messages.removeSubrange(lastUser...)
        if chats[index].messages.isEmpty {
            chats.remove(at: index)
            currentChatID = nil
        }
        save()
    }

    var canRegenerate: Bool {
        !isStreaming && currentChat?.messages.last?.role == .assistant
    }

    /// Gets another platform's answer to the question before `messageID`, shown alongside the original.
    func compare(_ messageID: UUID, with other: AIProvider) {
        guard comparingMessageID == nil, let chatID = currentChatID, let chat = currentChat,
              let index = chat.messages.firstIndex(where: { $0.id == messageID }), index > 0 else { return }
        let history = apiHistory(Array(chat.messages[..<index]))
        let stream = stream(other, messages: history)
        comparingMessageID = messageID
        compareText = ""
        compareTask = Task {
            defer {
                comparingMessageID = nil
                compareText = ""
            }
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let piece): compareText += piece
                    case .fallback: break
                    case .finished(let turn):
                        let alternate = AIAlternate(provider: other, model: turn.model, text: turn.text, note: Self.note(for: turn, provider: other))
                        updateMessage(messageID, in: chatID) { message in
                            message.alternates = (message.alternates ?? []).filter { $0.provider != other } + [alternate]
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = "\(other.displayName): \(error.localizedDescription)"
            }
        }
    }

    /// Opens a chat seeded with an Ask AI exchange so the conversation can continue.
    func continueInNewChat(question: String, apiPrompt: String, answer: String, provider: AIProvider, model: String?) {
        cancel()
        var chat = AIChat(title: String(question.prefix(40)))
        chat.messages = [
            AIMessage(role: .user, text: question, apiContent: [.object(["type": .string("text"), "text": .string(apiPrompt)])], typedText: question),
            AIMessage(role: .assistant, text: answer, apiContent: [.object(["type": .string("text"), "text": .string(answer.isEmpty ? "(no answer)" : answer)])],
                      model: model, provider: provider),
        ]
        chats.insert(chat, at: 0)
        currentChatID = chat.id
        save()
        app?.showAssistant = true
        app?.rightPane = .ai
    }

    func cancel() {
        task?.cancel()
        task = nil
        compareTask?.cancel()
        compareTask = nil
    }

    private func append(_ message: AIMessage, to chatID: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].messages.append(message)
        chats[index].updatedAt = Date()
        save()
    }

    private func updateMessage(_ id: UUID, in chatID: UUID, _ change: (inout AIMessage) -> Void) {
        guard let chatIndex = chats.firstIndex(where: { $0.id == chatID }),
              let messageIndex = chats[chatIndex].messages.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[chatIndex].messages[messageIndex])
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

    // MARK: - Ask AI actions

    @discardableResult
    func saveAction(_ action: AIAction) -> AIAction {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.insert(action, at: 0)
        }
        try? actionStore.save(actions)
        return action
    }

    func deleteAction(_ id: UUID) {
        actions.removeAll { $0.id == id }
        try? actionStore.save(actions)
    }

    func togglePin(_ id: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].isPinned.toggle()
        try? actionStore.save(actions)
    }

    var pinnedActions: [AIAction] { actions.filter(\.isPinned) }

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

/// Builds the database descriptions that go to the AI.
@MainActor
enum AIContextBuilder {
    /// `table(column type PK, …)` for each table and view in the schema; columns come from the driver.
    static func schemaDescription(context: DatabaseContext, schema: String?, limit: Int = 80) async -> String {
        if context.objects(in: schema) == nil { await context.loadObjects(schema: schema) }
        let objects = (context.objects(in: schema) ?? []).filter { $0.kind != .routine }.prefix(limit)
        let driver = context.driver
        let driverSchema = context.driverSchema(schema)
        var lines: [String] = []
        for object in objects {
            let columns = (try? await driver.listColumns(table: object.name, schema: driverSchema)) ?? []
            let described = columns.map { "\($0.name) \($0.dataType)\($0.isPrimaryKey ? " PK" : "")" }.joined(separator: ", ")
            let kind = object.kind == .table ? "" : " -- \(object.kind == .view ? "view" : "materialized view")"
            lines.append("\(object.name)(\(described))\(kind)")
        }
        return lines.joined(separator: "\n")
    }

    /// What the editor's Ask AI actions can draw on for this query tab.
    static func requestContext(for query: QueryTabModel, includeSchema: Bool) async -> AIRequestContext {
        let context = query.context
        let engine = context?.kind.displayName ?? "SQL"
        let version = context?.session?.serverVersion ?? ""
        var schemaText = ""
        if includeSchema, let context {
            schemaText = await schemaDescription(context: context, schema: context.defaultSchema)
        }
        return AIRequestContext(engine: engine, serverVersion: version, selectedText: query.selectedText, allText: query.text, schemaDescription: schemaText)
    }
}
