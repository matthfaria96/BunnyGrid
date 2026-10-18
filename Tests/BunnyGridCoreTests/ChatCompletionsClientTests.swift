import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct ChatCompletionsClientTests {
    private func run(_ raw: String) throws -> (events: [AssistantStreamEvent], turn: AssistantTurn) {
        var parser = SSEParser()
        var accumulator = ChatCompletionAccumulator()
        var events: [AssistantStreamEvent] = []
        for line in raw.components(separatedBy: "\n") + [""] {
            if let event = parser.feed(line) { events += try accumulator.apply(event) }
        }
        return (events, accumulator.turn)
    }

    @Test func requestBodyPutsSystemFirstAndStreams() {
        let messages: [JSONValue] = [
            .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("List tables")])])]),
        ]
        let body = ChatCompletionsClient.requestBody(model: "gemini-x", system: "Be brief.", messages: messages,
                                                     options: AIRequestOptions(maxTokens: 500, instruction: "Use SQLite"))
        #expect(body["model"]?.stringValue == "gemini-x")
        #expect(body["stream"] == .bool(true))
        #expect(body["max_tokens"] == .int(500))
        let chat = body["messages"]?.arrayValue ?? []
        #expect(chat.count == 2)
        #expect(chat.first?["role"]?.stringValue == "system")
        #expect(chat.first?["content"]?.stringValue?.contains("Use SQLite") == true)
        #expect(chat.last == .object(["role": .string("user"), "content": .string("List tables")]))
    }

    @Test func requestBodyOmitsMaxTokensByDefault() {
        let body = ChatCompletionsClient.requestBody(model: "m", system: "s", messages: [])
        #expect(body["max_tokens"] == nil)
    }

    @Test func accumulatesDeltasUntilDone() throws {
        let raw = """
            data: {"id":"c1","model":"deepseek-chat","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

            data: {"id":"c1","model":"deepseek-chat","choices":[{"index":0,"delta":{"content":"SELECT "}}]}

            data: {"id":"c1","model":"deepseek-chat","choices":[{"index":0,"delta":{"content":"1;"},"finish_reason":"stop"}]}

            data: [DONE]
            """
        let (events, turn) = try run(raw)
        #expect(events.count == 2)
        #expect(turn.text == "SELECT 1;")
        #expect(turn.model == "deepseek-chat")
        #expect(turn.stopReason == "end_turn")
        #expect(turn.echoContent == [.object(["type": .string("text"), "text": .string("SELECT 1;")])])
    }

    @Test func lengthFinishMapsToMaxTokens() throws {
        let (_, turn) = try run(#"data: {"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}"#)
        #expect(turn.stopReason == "max_tokens")
    }

    @Test func streamErrorThrows() {
        #expect(throws: ChatCompletionsError.self) {
            try run(#"data: {"error":{"message":"model not loaded"}}"#)
        }
    }

    @Test func modelIDsDropGeminiPrefixAndEmbeddings() {
        let data = Data(#"{"object":"list","data":[{"id":"models/gemini-pro"},{"id":"models/text-embedding-004"},{"id":"llama3"}]}"#.utf8)
        #expect(ChatCompletionsClient.modelIDs(from: data) == ["gemini-pro", "llama3"])
    }

    @Test func errorMessageReadsEveryShape() {
        #expect(ChatCompletionsClient.errorMessage(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)) == "bad key")
        #expect(ChatCompletionsClient.errorMessage(from: Data(#"[{"error":{"code":400,"message":"gemini says no"}}]"#.utf8)) == "gemini says no")
        #expect(ChatCompletionsClient.errorMessage(from: Data(#"{"error":"model not found"}"#.utf8)) == "model not found")
        #expect(ChatCompletionsClient.errorMessage(from: Data("plain".utf8)) == "plain")
    }

    @Test func providersPickTheRightAPI() {
        #expect(AIProvider.claude.api == .anthropic)
        #expect(AIProvider.chatGPT.api == .openAIResponses)
        for provider in [AIProvider.gemini, .grok, .deepSeek, .mistral, .ollama, .lmStudio] {
            #expect(provider.api == .chatCompletions)
            #expect(provider.defaultModel.isEmpty)
            #expect(provider.keychainService == "app.bunnygrid.\(provider.rawValue)")
        }
        #expect(AIProvider.ollama.isLocal && !AIProvider.ollama.requiresAPIKey)
        #expect(AIProvider.gemini.requiresAPIKey)
        #expect(AIProvider.ollama.defaultHost == "http://localhost:11434/v1")
        #expect(AIProvider.lmStudio.defaultHost == "http://localhost:1234/v1")
        #expect(AIProvider.gemini.menuTitle == "Google Gemini")
        #expect(AIProvider.ollama.menuTitle == "Ollama")
        #expect(AIProvider.chatGPT.chatPath == "v1/responses")
    }

    @Test func savedAssistantsStillDecode() throws {
        let json = Data(#"[{"id":"853824A2-9645-449C-85E9-26ABFDB0A6DD","name":"Claude","provider":"claude","apiHost":"https://api.anthropic.com","model":"claude-opus-5-5","effort":"medium","instruction":""}]"#.utf8)
        let saved = try JSONDecoder().decode([AIAssistantConfig].self, from: json)
        #expect(saved.first?.provider == .claude)
    }
}
