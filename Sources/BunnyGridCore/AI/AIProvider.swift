import Foundation

/// The AI platforms the assistant can talk to. Each one is used with the user's own API key.
public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case chatGPT = "chatgpt"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    public var company: String {
        switch self {
        case .claude: "Anthropic"
        case .chatGPT: "OpenAI"
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .claude: "sk-ant-…"
        case .chatGPT: "sk-proj-…"
        }
    }

    /// Where the user creates an API key.
    public var keysURL: URL {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .chatGPT: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// Environment variable read when no key is saved in the Keychain.
    public var environmentKey: String {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .chatGPT: "OPENAI_API_KEY"
        }
    }

    public var keychainService: String {
        switch self {
        case .claude: "app.bunnygrid.anthropic"
        case .chatGPT: "app.bunnygrid.openai"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claude: ClaudeModel.opus.rawValue
        case .chatGPT: OpenAIModels.defaultModel
        }
    }

    /// Models offered before (or without) asking the API for the account's list.
    public var suggestedModels: [AIModelOption] {
        switch self {
        case .claude: ClaudeModel.allCases.map { AIModelOption(id: $0.rawValue, name: $0.displayName) }
        case .chatGPT: OpenAIModels.suggested
        }
    }

    public func missingKeyMessage() -> String {
        "Add your \(company) API key to chat with \(displayName). Click your profile picture or open Settings (⌘,)."
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
    public var menuTitle: String { "\(company) \(displayName)" }

    /// API Host filled in when the provider is chosen.
    public var defaultHost: String {
        switch self {
        case .claude: "https://api.anthropic.com"
        case .chatGPT: "https://api.openai.com"
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
