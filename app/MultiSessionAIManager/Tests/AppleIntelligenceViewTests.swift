import Testing
import Foundation
import SwiftUI
@testable import MultiSessionAIManager

@Suite @MainActor struct AppleIntelligenceViewTests {
    @Test func codeBlockInsertionDeliversSnippetWithoutNewline() {
        var insertedCode: String?
        let _ = AppleIntelligenceMessageView(
            message: AppleIntelligenceEngine.ChatMessage(
                role: .assistant,
                content: "Run this command:\n```bash\ngit status --short\n```"
            ),
            onInsertToTerminal: { code in
                insertedCode = code
            }
        )

        // Verify the code block parser extracts clean snippet
        let segments = CodeBlockExtractor.parse(markdown: "```bash\ngit status --short\n```")
        #expect(segments.count == 1)
        if case .codeBlock(let code, let lang) = segments[0].type {
            #expect(code == "git status --short")
            #expect(lang == "bash")
            #expect(!code.hasSuffix("\n"))
            #expect(!code.hasSuffix("\r"))
        } else {
            Issue.record("Expected code block segment")
        }
    }

    @Test func intelligenceViewInitialization() {
        let mockBackend = MockLanguageModelBackend(available: true)
        let engine = AppleIntelligenceEngine(backend: mockBackend)
        var closeCalled = false
        var insertCalledWith: String?

        let view = AppleIntelligenceView(
            engine: engine,
            activeTerminalText: { "line 1\nline 2\nline 3" },
            onInsertToTerminal: { insertCalledWith = $0 },
            onClose: { closeCalled = true }
        )

        #expect(view.activeTerminalText() == "line 1\nline 2\nline 3")
        view.onClose()
        #expect(closeCalled == true)
        view.onInsertToTerminal("echo test")
        #expect(insertCalledWith == "echo test")
    }

    @Test func terminalContextLineCounter() {
        let context = "line 1\nline 2\nline 3\nline 4"
        let lines = AppleIntelligenceView.lineCount(of: context)
        #expect(lines == 4)

        #expect(AppleIntelligenceView.lineCount(of: "") == 0)
        #expect(AppleIntelligenceView.lineCount(of: "single line") == 1)
    }

    @Test func availabilityPlaceholders() {
        #expect(AppleIntelligenceView.placeholder(for: .available) == "Ask Apple Intelligence...")
        #expect(AppleIntelligenceView.placeholder(for: .downloading(reason: "")) == "Model assets are downloading...")
        #expect(AppleIntelligenceView.placeholder(for: .notEnabled(reason: "")) == "Enable Apple Intelligence in Settings...")
        #expect(AppleIntelligenceView.placeholder(for: .unsupported(reason: "")) == "Unavailable on this device")
        #expect(AppleIntelligenceView.placeholder(for: .checking) == "Checking availability...")
    }

    @Test func availabilityStateIsReady() {
        #expect(AppleIntelligenceEngine.AvailabilityState.available.isReady == true)
        #expect(AppleIntelligenceEngine.AvailabilityState.checking.isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.downloading(reason: "test").isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.notEnabled(reason: "test").isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.unsupported(reason: "test").isReady == false)
    }
}
