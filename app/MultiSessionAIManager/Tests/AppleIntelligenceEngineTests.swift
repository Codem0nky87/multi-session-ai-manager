import Testing
import Foundation
@testable import MultiSessionAIManager

final class MockLanguageModelBackend: LanguageModelBackend, @unchecked Sendable {
    var available: Bool
    var streamChunks: [String]
    var delayNanoseconds: UInt64
    var lastPrompt: String?
    var lastContext: String?

    init(available: Bool = true, streamChunks: [String] = ["Hello", " world!"], delayNanoseconds: UInt64 = 0) {
        self.available = available
        self.streamChunks = streamChunks
        self.delayNanoseconds = delayNanoseconds
    }

    func isAvailable() -> Bool {
        available
    }

    func streamResponse(
        to prompt: String,
        context: String?,
        history: [AppleIntelligenceEngine.ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        self.lastPrompt = prompt
        self.lastContext = context
        let chunks = streamChunks
        let delay = delayNanoseconds

        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    if Task.isCancelled { break }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

@Suite @MainActor struct AppleIntelligenceEngineTests {
    @Test func initialAvailabilityAndCheckState() {
        let mock = MockLanguageModelBackend(available: true)
        let engine = AppleIntelligenceEngine(backend: mock)

        engine.checkAvailability()
        #expect(engine.availability == .available)
        #expect(engine.messages.isEmpty)
        #expect(!engine.isGenerating)
    }

    @Test func unsupportedBackendSetsReason() {
        let mock = MockLanguageModelBackend(available: false)
        let engine = AppleIntelligenceEngine(backend: mock)

        engine.checkAvailability()
        if case .unsupported = engine.availability {
            // expected
        } else {
            Issue.record("Expected .unsupported availability state")
        }
    }

    @Test func sendPromptAppendsUserAndStreamsAssistantMessage() async throws {
        let mock = MockLanguageModelBackend(available: true, streamChunks: ["The ", "answer ", "is 42."])
        let engine = AppleIntelligenceEngine(backend: mock)
        engine.checkAvailability()

        await engine.sendPrompt("What is the meaning of life?", terminalContext: "exit code 0")

        #expect(engine.messages.count == 2)
        #expect(engine.messages[0].role == .user)
        #expect(engine.messages[0].content == "What is the meaning of life?")
        #expect(engine.messages[0].attachedTerminalContext == "exit code 0")

        #expect(engine.messages[1].role == .assistant)
        #expect(engine.messages[1].content == "The answer is 42.")
        #expect(!engine.messages[1].isStreaming)
        #expect(!engine.isGenerating)
        #expect(mock.lastContext == "exit code 0")
    }

    @Test func stopGenerationCancelsActiveStream() async throws {
        let mock = MockLanguageModelBackend(
            available: true,
            streamChunks: ["Step 1", "Step 2", "Step 3"],
            delayNanoseconds: 50_000_000
        )
        let engine = AppleIntelligenceEngine(backend: mock)
        engine.checkAvailability()

        let task = Task {
            await engine.sendPrompt("Long task")
        }

        // Wait brief moment for generation to start
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(engine.isGenerating)

        engine.stopGeneration()
        await task.value

        #expect(!engine.isGenerating)
    }

    @Test func clearHistoryResetsMessages() async {
        let mock = MockLanguageModelBackend(available: true)
        let engine = AppleIntelligenceEngine(backend: mock)
        engine.checkAvailability()

        await engine.sendPrompt("Hello")
        #expect(!engine.messages.isEmpty)

        engine.clearHistory()
        #expect(engine.messages.isEmpty)
    }
}
