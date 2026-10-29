import Testing
import Foundation
@testable import MultiSessionAIManager

final class MockLanguageModelBackend: LanguageModelBackend, @unchecked Sendable {
    var state: AppleIntelligenceEngine.AvailabilityState
    var streamChunks: [String]
    var delayNanoseconds: UInt64
    var lastPrompt: String?
    var lastContext: String?
    var lastRuntimeContext: AppRuntimeContext?

    init(
        state: AppleIntelligenceEngine.AvailabilityState = .available,
        available: Bool = true,
        streamChunks: [String] = ["Hello", " world!"],
        delayNanoseconds: UInt64 = 0
    ) {
        if !available {
            self.state = .unsupported(reason: "Mock unsupported device")
        } else {
            self.state = state
        }
        self.streamChunks = streamChunks
        self.delayNanoseconds = delayNanoseconds
    }

    func checkAvailability() -> AppleIntelligenceEngine.AvailabilityState {
        state
    }

    func streamResponse(
        to prompt: String,
        context: String?,
        history: [AppleIntelligenceEngine.ChatMessage],
        runtimeContext: AppRuntimeContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        self.lastPrompt = prompt
        self.lastContext = context
        self.lastRuntimeContext = runtimeContext
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
        #expect(engine.availability.isReady == true)
        #expect(engine.messages.isEmpty)
        #expect(!engine.isGenerating)
    }

    @Test func unsupportedBackendSetsReason() {
        let mock = MockLanguageModelBackend(available: false)
        let engine = AppleIntelligenceEngine(backend: mock)

        engine.checkAvailability()
        #expect(engine.availability.isReady == false)
        if case .unsupported(let reason) = engine.availability {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected .unsupported availability state")
        }
    }

    @Test func downloadingAndNotEnabledBackendStates() {
        let mockDownloading = MockLanguageModelBackend(state: .downloading(reason: "Downloading assets..."))
        let engineDownloading = AppleIntelligenceEngine(backend: mockDownloading)
        #expect(engineDownloading.availability.isReady == false)
        if case .downloading(let reason) = engineDownloading.availability {
            #expect(reason == "Downloading assets...")
        } else {
            Issue.record("Expected .downloading state")
        }

        let mockNotEnabled = MockLanguageModelBackend(state: .notEnabled(reason: "Turn on in Settings"))
        let engineNotEnabled = AppleIntelligenceEngine(backend: mockNotEnabled)
        #expect(engineNotEnabled.availability.isReady == false)
        if case .notEnabled(let reason) = engineNotEnabled.availability {
            #expect(reason == "Turn on in Settings")
        } else {
            Issue.record("Expected .notEnabled state")
        }
    }

    @Test func sendPromptBlockedWhenNotReady() async {
        let mock = MockLanguageModelBackend(available: false)
        let engine = AppleIntelligenceEngine(backend: mock)

        await engine.sendPrompt("Hello?")
        #expect(engine.messages.isEmpty)
        #expect(!engine.isGenerating)
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
