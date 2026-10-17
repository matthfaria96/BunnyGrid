import Foundation

/// Claude models offered in the assistant's model picker. `claude-opus-5-5` is the default.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case fable = "claude-fable-5-1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        case .fable: "Claude Fable 5.1"
        }
    }

    /// Server-side refusal fallback (`fallbacks: "default"`) is available on these models;
    /// Haiku has no server-side fallback.
    var supportsDefaultFallback: Bool { self != .haiku }
}

public enum AnthropicError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AIProvider.claude.missingKeyMessage()
        case .http(let status, let message):
            switch status {
            case 401: "The API key was rejected (401). Check it in Settings. \(message)"
            case 429: "Rate limited (429). Wait a moment and try again. \(message)"
            case 529: "The API is overloaded (529). Try again shortly. \(message)"
            default: "API error \(status): \(message)"
            }
        case .stream(let message):
            message
        }
    }
}

/// Things the UI reacts to while a reply streams in.
public enum AssistantStreamEvent: Sendable {
    case textDelta(String)
    /// A safety classifier declined on one model and another model continued.
    case fallback(from: String, to: String)
    case finished(AssistantTurn)
}

/// A completed assistant reply.
public struct AssistantTurn: Sendable {
    /// Content blocks ready to be sent back as the assistant message on the next request.
    public var echoContent: [JSONValue]
    public var text: String
    public var stopReason: String?
    public var model: String?

    public var wasRefused: Bool { stopReason == "refusal" }
}

/// Minimal raw-HTTP client for the Messages API (Swift has no official SDK).
public struct AnthropicClient: Sendable {
    public var apiKey: String
    public var baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// Builds the request body. Thinking is left at the model default (adaptive);
    /// effort is set explicitly because Opus 5.5 defaults to `medium`.
    public static func requestBody(model: ClaudeModel, system: String, messages: [JSONValue], maxTokens: Int = 64_000) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": .int(maxTokens),
            "stream": .bool(true),
            "system": .string(system),
            "messages": .array(messages),
            "output_config": .object(["effort": .string("medium")]),
        ]
        if model.supportsDefaultFallback {
            body["fallbacks"] = .string("default")
        }
        return .object(body)
    }

    public func streamMessage(model: ClaudeModel, system: String, messages: [JSONValue]) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        let body = Self.requestBody(model: model, system: system, messages: messages)
        let apiKey = apiKey
        let url = baseURL.appending(path: "v1/messages")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if model.supportsDefaultFallback {
                        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw AnthropicError.http(status: status, message: Self.errorMessage(from: data))
                    }

                    var parser = SSEParser()
                    var accumulator = MessageAccumulator()
                    for try await line in bytes.lines {
                        guard let event = parser.feed(line) else { continue }
                        for output in try accumulator.apply(event) {
                            continuation.yield(output)
                        }
                    }
                    // `lines` drops the blank line that ends the last event; flush it.
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

    /// Checks the key with `GET /v1/models` and returns the model IDs the account can use.
    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }
        var request = URLRequest(url: baseURL.appending(path: "v1/models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")]))
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AnthropicError.http(status: status, message: Self.errorMessage(from: data)) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           let message = json["error"]?["message"]?.stringValue {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Server-sent events: accumulates `event:`/`data:` lines until a blank line ends the event.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public var name: String
        public var data: String
    }

    private var name = ""
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            defer { name = ""; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(name: name, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            // A new event line also closes a previous event whose blank separator was dropped.
            let pending: Event? = dataLines.isEmpty ? nil : Event(name: name, data: dataLines.joined(separator: "\n"))
            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            dataLines = []
            return pending
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }
}

/// Rebuilds the assistant message from stream events.
public struct MessageAccumulator: Sendable {
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var stopReason: String?
    private var model: String?
    private var text = ""

    public init() {}

    public mutating func apply(_ event: SSEParser.Event) throws -> [AssistantStreamEvent] {
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        switch payload["type"]?.stringValue {
        case "message_start":
            model = payload["message"]?["model"]?.stringValue
        case "content_block_start":
            guard let index = payload["index"]?.intValue, case .object(let block)? = payload["content_block"] else { return [] }
            blocks[index] = block
            if block["type"]?.stringValue == "fallback" {
                return [.fallback(
                    from: block["from"]?["model"]?.stringValue ?? "",
                    to: block["to"]?["model"]?.stringValue ?? ""
                )]
            }
            if block["type"]?.stringValue == "text", let initial = block["text"]?.stringValue, !initial.isEmpty {
                text += initial
                return [.textDelta(initial)]
            }
        case "content_block_delta":
            guard let index = payload["index"]?.intValue, let delta = payload["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let piece = delta["text"]?.stringValue ?? ""
                append(piece, to: "text", at: index)
                text += piece
                return [.textDelta(piece)]
            case "thinking_delta":
                append(delta["thinking"]?.stringValue ?? "", to: "thinking", at: index)
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            default:
                break
            }
        case "message_delta":
            if let reason = payload["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
        case "error":
            throw AnthropicError.stream(payload["error"]?["message"]?.stringValue ?? "The stream reported an error.")
        default:
            break
        }
        return []
    }

    private mutating func append(_ piece: String, to field: String, at index: Int) {
        let current = blocks[index]?[field]?.stringValue ?? ""
        blocks[index]?[field] = .string(current + piece)
    }

    public var turn: AssistantTurn {
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        return AssistantTurn(echoContent: Self.echoContent(ordered), text: text, stopReason: stopReason, model: model)
    }

    /// After a mid-output fallback, blocks the declined model produced before the last
    /// `fallback` marker (thinking, tool use, unpaired server tools) must not be echoed;
    /// text and everything after the marker are kept. The marker itself is dropped.
    static func echoContent(_ blocks: [[String: JSONValue]]) -> [JSONValue] {
        let lastFallback = blocks.lastIndex { $0["type"]?.stringValue == "fallback" }
        var result: [JSONValue] = []
        for (index, block) in blocks.enumerated() {
            let type = block["type"]?.stringValue ?? ""
            if type == "fallback" { continue }
            if let lastFallback, index < lastFallback, type != "text" { continue }
            result.append(.object(block))
        }
        return result
    }
}
