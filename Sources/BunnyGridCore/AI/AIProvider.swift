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
