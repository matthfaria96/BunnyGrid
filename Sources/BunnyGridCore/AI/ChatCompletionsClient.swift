import Foundation

public enum ChatCompletionsError: LocalizedError, Sendable {
    case missingAPIKey(AIProvider)
    case noModel(AIProvider)
    case http(AIProvider, status: Int, message: String)
    case unreachable(AIProvider, String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            provider.missingKeyMessage()
        case .noModel(let provider):
            provider.isLocal
                ? "\(provider.displayName) has no model loaded. Load one in \(provider.displayName), then pick it under Model."
                : "Pick a \(provider.displayName) model first (profile picture › Model)."
        case .http(let provider, let status, let message):
            // Gemini and xAI answer a bad key with 400, not 401.
            switch status == 400 && message.localizedCaseInsensitiveContains("api key") ? 401 : status {
            case 401, 403: "\(provider.company) rejected the API key (\(status)). Check it in Settings. \(message)"
            case 404: "Model not available on \(provider.displayName) (404). \(message)"
            case 429: "\(provider.company) rate limit or quota reached (429). \(message)"
            default: "\(provider.displayName) error \(status): \(message)"
            }
        case .unreachable(let provider, let message):
            provider.isLocal
                ? "\(provider.displayName) isn't running on this Mac (\(message)). Start it and try again."
                : "Couldn't reach \(provider.displayName): \(message)"
        case .stream(let message):
            message
        }
    }
}

/// Raw-HTTP client for OpenAI-compatible Chat Completions, which Gemini, Grok, DeepSeek, Mistral, Ollama and
/// LM Studio all serve. `baseURL` already includes the version path (`https://api.x.ai/v1`); requests go to
/// `chat/completions` and `models` under it. Produces the same stream events as `AnthropicClient`.
public struct ChatCompletionsClient: Sendable {
    public var provider: AIProvider
    public var apiKey: String
    public var baseURL: URL

    public init(provider: AIProvider, apiKey: String, baseURL: URL) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// History is sent in full each turn: the system prompt first, then the text of every message.
    public static func requestBody(model: String, system: String, messages: [JSONValue], options: AIRequestOptions = AIRequestOptions()) -> JSONValue {
        let chat = [JSONValue.object(["role": .string("system"), "content": .string(options.system(system))])]
            + OpenAIClient.input(fromMessages: messages)
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(chat),
            "stream": .bool(true),
        ]
        if let maxTokens = options.maxTokens { body["max_tokens"] = .int(maxTokens) }
        return .object(body)
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    public func streamChat(model: String, system: String, messages: [JSONValue], options: AIRequestOptions = AIRequestOptions()) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        var request = request(path: "chat/completions")
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = try? JSONEncoder().encode(Self.requestBody(model: model, system: system, messages: messages, options: options))
        let finalRequest = request
        let provider = provider, apiKey = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !provider.requiresAPIKey || !apiKey.isEmpty else { throw ChatCompletionsError.missingAPIKey(provider) }
                    guard !model.isEmpty else { throw ChatCompletionsError.noModel(provider) }
                    let (bytes, response) = try await Self.perform(provider) { try await URLSession.shared.bytes(for: finalRequest) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw ChatCompletionsError.http(provider, status: status, message: Self.errorMessage(from: data))
                    }
                    var parser = SSEParser()
                    var accumulator = ChatCompletionAccumulator()
                    // `bytes.lines` drops the blank lines that end SSE events, and Chat Completions sends no `event:`
                    // lines to close them either, so every `data:` line is one complete chunk.
                    for try await line in bytes.lines {
                        _ = parser.feed(line)
                        guard line.hasPrefix("data:"), let event = parser.feed("") else { continue }
                        for output in try accumulator.apply(event) { continuation.yield(output) }
                    }
                    if let event = parser.feed("") {
                        for output in try accumulator.apply(event) { continuation.yield(output) }
                    }
                    continuation.yield(.finished(accumulator.turn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The model IDs the host serves (`GET models`); also verifies the key, or that the local server is up.
    public func listModels() async throws -> [String] {
        guard !provider.requiresAPIKey || !apiKey.isEmpty else { throw ChatCompletionsError.missingAPIKey(provider) }
        var request = request(path: "models")
        request.timeoutInterval = 20
        let (data, response) = try await Self.perform(provider) { try await URLSession.shared.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ChatCompletionsError.http(provider, status: status, message: Self.errorMessage(from: data)) }
        return Self.modelIDs(from: data)
    }

    /// `{"data": [{"id": …}]}`; Gemini prefixes ids with `models/`, which its chat endpoint doesn't take.
    public static func modelIDs(from data: Data) -> [String] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let ids = (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        return ids.map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { !$0.contains("embed") }
    }

    /// Error bodies are `{"error": {"message"}}`, `{"error": "…"}` (xAI), `{"message"}`, `{"detail"}` (Mistral) or
    /// (Gemini) an array of those.
    static func errorMessage(from data: Data) -> String {
        guard var json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let first = json.arrayValue?.first { json = first }
        return json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? json["message"]?.stringValue
            ?? json["detail"]?.stringValue ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// Connection failures (local server not started, no network) become a readable error.
    private static func perform<T>(_ provider: AIProvider, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where error.code != .cancelled {
            throw ChatCompletionsError.unreachable(provider, error.localizedDescription)
        }
    }
}

/// Rebuilds a reply from Chat Completions stream chunks (`data: {"choices": [{"delta": {"content"}}]}` … `data: [DONE]`).
public struct ChatCompletionAccumulator: Sendable {
    private var text = ""
    private var model: String?
    private var stopReason: String?

    public init() {}

    public mutating func apply(_ event: SSEParser.Event) throws -> [AssistantStreamEvent] {
        guard event.data != "[DONE]", let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        if let error = payload["error"] {
            throw ChatCompletionsError.stream(error["message"]?.stringValue ?? error.stringValue ?? "The stream reported an error.")
        }
        model = payload["model"]?.stringValue ?? model
        guard let choice = payload["choices"]?.arrayValue?.first else { return [] }
        if let reason = choice["finish_reason"]?.stringValue {
            stopReason = switch reason {
            case "length": "max_tokens"
            case "content_filter": "refusal"
            default: "end_turn"
            }
        }
        let piece = choice["delta"]?["content"]?.stringValue ?? ""
        text += piece
        return piece.isEmpty ? [] : [.textDelta(piece)]
    }

    /// Echo content uses the Messages-API text block shape so one chat history serves every provider.
    public var turn: AssistantTurn {
        let echo: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        return AssistantTurn(echoContent: echo, text: text, stopReason: stopReason, model: model)
    }
}
