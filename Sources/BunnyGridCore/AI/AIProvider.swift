import Foundation

/// The AI platforms the assistant can talk to. Each one is used with the user's own API key.
public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case chatGPT = "chatgpt"
    case gemini
    case grok
    case deepSeek = "deepseek"
    case mistral
    case ollama
    case lmStudio = "lmstudio"

    public var id: String { rawValue }

    /// Which wire protocol the provider speaks.
    public enum API: Sendable {
        /// Anthropic Messages API (`/v1/messages`).
        case anthropic
        /// OpenAI Responses API (`/v1/responses`).
        case openAIResponses
        /// OpenAI-compatible Chat Completions (`<host>/chat/completions`): Gemini, Grok, DeepSeek, Mistral, Ollama, LM Studio.
        case chatCompletions
    }

    public var api: API {
        switch self {
        case .claude: .anthropic
        case .chatGPT: .openAIResponses
        default: .chatCompletions
        }
    }

    /// The chat endpoint under the API host.
    public var chatPath: String {
        switch api {
        case .anthropic: "v1/messages"
        case .openAIResponses: "v1/responses"
        case .chatCompletions: "chat/completions"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .deepSeek: "DeepSeek"
        case .mistral: "Mistral"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    public var company: String {
        switch self {
        case .claude: "Anthropic"
        case .chatGPT: "OpenAI"
        case .gemini: "Google"
        case .grok: "xAI"
        case .deepSeek: "DeepSeek"
        case .mistral: "Mistral AI"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    /// Models served on this Mac: no API key, nothing leaves the machine.
    public var isLocal: Bool { self == .ollama || self == .lmStudio }

    public var requiresAPIKey: Bool { !isLocal }

    public var keyPlaceholder: String {
        switch self {
        case .claude: "sk-ant-…"
        case .chatGPT: "sk-proj-…"
        case .gemini: "AIza…"
        case .grok: "xai-…"
        case .deepSeek: "sk-…"
        case .mistral: "API key"
        case .ollama, .lmStudio: "Not needed"
        }
    }

    /// Where the user creates an API key (or downloads the local server).
    public var keysURL: URL {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .chatGPT: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .grok: URL(string: "https://console.x.ai")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
        case .ollama: URL(string: "https://ollama.com/download")!
        case .lmStudio: URL(string: "https://lmstudio.ai")!
        }
    }

    /// Environment variable read when no key is saved in the Keychain.
    public var environmentKey: String {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .chatGPT: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        case .grok: "XAI_API_KEY"
        case .deepSeek: "DEEPSEEK_API_KEY"
        case .mistral: "MISTRAL_API_KEY"
        case .ollama: "OLLAMA_API_KEY"
        case .lmStudio: "LMSTUDIO_API_KEY"
        }
    }

    public var keychainService: String {
        switch self {
        case .claude: "app.bunnygrid.anthropic"
        case .chatGPT: "app.bunnygrid.openai"
        default: "app.bunnygrid.\(rawValue)"
        }
    }

    /// The model a new assistant starts with. Chat Completions providers start empty and take the first model
    /// their `/models` list returns, since those lists change too often to hard-code.
    public var defaultModel: String {
        switch self {
        case .claude: ClaudeModel.opus.rawValue
        case .chatGPT: OpenAIModels.defaultModel
        default: ""
        }
    }

    /// Models offered before (or without) asking the API for the account's list.
    public var suggestedModels: [AIModelOption] {
        switch self {
        case .claude: ClaudeModel.allCases.map { AIModelOption(id: $0.rawValue, name: $0.displayName) }
        case .chatGPT: OpenAIModels.suggested
        default: []
        }
    }

    public func missingKeyMessage() -> String {
        if isLocal { return "Start \(displayName) on this Mac and load a model, then pick it under Model." }
        return "Add your \(company) API key to chat with \(displayName). Click your profile picture or open Settings (⌘,)."
    }
}

/// A model in the assistant's picker.
public struct AIModelOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension AIProvider {
    /// The name in the "+" menu of Settings › AI, as Navicat lists providers.
    public var menuTitle: String {
        company == displayName ? displayName : "\(company) \(displayName)"
    }

    /// API Host filled in when the provider is chosen.
    public var defaultHost: String {
        switch self {
        case .claude: "https://api.anthropic.com"
        case .chatGPT: "https://api.openai.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .grok: "https://api.x.ai/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        }
    }
}

/// One configured assistant (Navicat's Settings › AI › AI Assistant list): a provider with its own
/// host, model and request settings. The API key lives in the Keychain under the assistant's id.
public struct AIAssistantConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: AIProvider
    public var apiHost: String
    public var model: String
    public var maxTokens: Int?
    public var effort: AIEffort
    public var instruction: String

    public init(id: UUID = UUID(), name: String? = nil, provider: AIProvider, apiHost: String? = nil, model: String? = nil,
                maxTokens: Int? = nil, effort: AIEffort = .medium, instruction: String = "") {
        self.id = id
        self.name = name ?? provider.displayName
        self.provider = provider
        self.apiHost = apiHost ?? provider.defaultHost
        self.model = model ?? provider.defaultModel
        self.maxTokens = maxTokens
        self.effort = effort
        self.instruction = instruction
    }

    public var options: AIRequestOptions {
        AIRequestOptions(maxTokens: maxTokens, effort: effort, instruction: instruction)
    }

    /// The host as a URL; an empty or invalid host falls back to the provider's.
    public var baseURL: URL {
        let trimmed = apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil { return url }
        return URL(string: provider.defaultHost)!
    }
}
