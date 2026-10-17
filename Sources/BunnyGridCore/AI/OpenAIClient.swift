import Foundation

/// OpenAI text models offered in the picker; `gpt-6-astra` is OpenAI's recommended default.
public enum OpenAIModels {
    public static let defaultModel = "gpt-6-astra"

    public static let suggested: [AIModelOption] = [
        AIModelOption(id: "gpt-6-astra", name: "GPT-6 Astra"),
        AIModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        AIModelOption(id: "gpt-6-luna", name: "GPT-6 Luna"),
    ]

    /// Whether a model from `GET /v1/models` can hold a text chat through the Responses API.
    public static func isChatModel(_ id: String) -> Bool {
        let id = id.lowercased()
        let family = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id.range(of: #"^o\d"#, options: .regularExpression) != nil
        guard family else { return false }
        let excluded = ["audio", "realtime", "image", "transcribe", "tts", "search", "embedding", "moderation", "whisper", "instruct", "live", "translate"]
        return !excluded.contains { id.contains($0) }
    }

    /// The suggested models first, then the account's other chat models, newest-looking names first.
    public static func options(from ids: [String]) -> [AIModelOption] {
        let chat = Set(ids.filter(isChatModel))
        let suggested = suggested.filter { chat.isEmpty || chat.contains($0.id) }
        let known = Set(suggested.map(\.id))
        let others = chat.subtracting(known).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return suggested + others.map { AIModelOption(id: $0, name: $0) }
    }
}

public enum OpenAIError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AIProvider.chatGPT.missingKeyMessage()
        case .http(let status, let message):
            switch status {
            case 401: "OpenAI rejected the API key (401). Check it in Settings. \(message)"
            case 404: "Model not available to this OpenAI account (404). \(message)"
            case 429: "OpenAI rate limit or quota reached (429). \(message)"
            default: "OpenAI error \(status): \(message)"
            }
        case .stream(let message):
            message
        }
    }
}

/// Minimal raw-HTTP client for OpenAI's Responses API, producing the same stream events as `AnthropicClient`.
public struct OpenAIClient: Sendable {
    public var apiKey: String
    public var baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// `store: false` keeps conversations off OpenAI's servers; the full history is sent each turn.
    /// Effort is sent only when changed from medium, since not every listed model takes `reasoning`.
    public static func requestBody(model: String, instructions: String, input: [JSONValue], options: AIRequestOptions = AIRequestOptions()) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(options.system(instructions)),
            "input": .array(input),
            "stream": .bool(true),
            "store": .bool(false),
        ]
        if let maxTokens = options.maxTokens { body["max_output_tokens"] = .int(maxTokens) }
        if options.effort != .medium { body["reasoning"] = .object(["effort": .string(options.effort.rawValue)]) }
        return .object(body)
    }

    /// Converts Messages-API style history (`{role, content: [blocks]}`) to Responses input messages.
    /// Only text travels: Claude's thinking blocks are signed for Claude and mean nothing to OpenAI.
    public static func input(fromMessages messages: [JSONValue]) -> [JSONValue] {
        messages.compactMap { message in
            guard let role = message["role"]?.stringValue else { return nil }
            let text: String
            if let plain = message["content"]?.stringValue {
                text = plain
            } else {
                text = (message["content"]?.arrayValue ?? [])
                    .filter { $0["type"]?.stringValue == "text" }
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n\n")
            }
            guard !text.isEmpty else { return nil }
            return .object(["role": .string(role), "content": .string(text)])
        }
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    public func streamResponse(model: String, instructions: String, messages: [JSONValue], options: AIRequestOptions = AIRequestOptions()) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        let body = Self.requestBody(model: model, instructions: instructions, input: Self.input(fromMessages: messages), options: options)
        var request = request(path: "v1/responses")
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = try? JSONEncoder().encode(body)
        let apiKey = apiKey
        let finalRequest = request
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
                    let (bytes, response) = try await URLSession.shared.bytes(for: finalRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw OpenAIError.http(status: status, message: AnthropicClient.errorMessage(from: data))
                    }
                    var parser = SSEParser()
                    var accumulator = ResponseAccumulator()
                    for try await line in bytes.lines {
                        guard let event = parser.feed(line) else { continue }
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

    /// The account's model IDs (`GET /v1/models`); also verifies the key.
    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        var request = request(path: "v1/models")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError.http(status: status, message: AnthropicClient.errorMessage(from: data)) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }
}

/// Rebuilds a reply from Responses API stream events.
public struct ResponseAccumulator: Sendable {
    private var text = ""
    private var refusal = ""
    private var model: String?
    private var stopReason: String?

    public init() {}

    public mutating func apply(_ event: SSEParser.Event) throws -> [AssistantStreamEvent] {
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        switch payload["type"]?.stringValue ?? event.name {
        case "response.created", "response.in_progress":
            model = payload["response"]?["model"]?.stringValue ?? model
        case "response.output_text.delta":
            let piece = payload["delta"]?.stringValue ?? ""
            text += piece
            return piece.isEmpty ? [] : [.textDelta(piece)]
        case "response.refusal.delta":
            refusal += payload["delta"]?.stringValue ?? ""
        case "response.completed":
            model = payload["response"]?["model"]?.stringValue ?? model
            stopReason = refusal.isEmpty ? "end_turn" : "refusal"
        case "response.incomplete":
            model = payload["response"]?["model"]?.stringValue ?? model
            let reason = payload["response"]?["incomplete_details"]?["reason"]?.stringValue
            stopReason = reason == "max_output_tokens" ? "max_tokens" : (reason == "content_filter" ? "refusal" : reason)
        case "response.failed":
            throw OpenAIError.stream(payload["response"]?["error"]?["message"]?.stringValue ?? "OpenAI could not complete the response.")
        case "error":
            throw OpenAIError.stream(payload["message"]?.stringValue ?? payload["error"]?["message"]?.stringValue ?? "The stream reported an error.")
        default:
            break
        }
        return []
    }

    /// Echo content uses the Messages-API text block shape so one chat history serves both providers.
    public var turn: AssistantTurn {
        let shown = text.isEmpty ? refusal : text
        let echo: [JSONValue] = shown.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(shown)])]
        return AssistantTurn(echoContent: echo, text: shown, stopReason: stopReason, model: model)
    }
}
