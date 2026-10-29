import Testing
import Foundation
import SwiftUI
@testable import MultiSessionAIManager

@Suite @MainActor struct OnDeviceCopilotViewTests {
    @Test func codeBlockInsertionDeliversSnippetWithoutNewline() {
        var insertedCode: String?
        let _ = CopilotMessageView(
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

    @Test func copilotViewInitialization() {
        let mockBackend = MockLanguageModelBackend(available: true)
        let engine = AppleIntelligenceEngine(backend: mockBackend)
        var closeCalled = false
        var insertCalledWith: String?

        let view = OnDeviceCopilotView(
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
        let lines = OnDeviceCopilotView.lineCount(of: context)
        #expect(lines == 4)

        #expect(OnDeviceCopilotView.lineCount(of: "") == 0)
        #expect(OnDeviceCopilotView.lineCount(of: "single line") == 1)
    }

    @Test func availabilityPlaceholders() {
        #expect(OnDeviceCopilotView.placeholder(for: .available) == "Ask on-device copilot...")
        #expect(OnDeviceCopilotView.placeholder(for: .downloading(reason: "")) == "Model assets are downloading...")
        #expect(OnDeviceCopilotView.placeholder(for: .notEnabled(reason: "")) == "Enable Apple Intelligence in Settings...")
        #expect(OnDeviceCopilotView.placeholder(for: .unsupported(reason: "")) == "Copilot unsupported on this device")
        #expect(OnDeviceCopilotView.placeholder(for: .checking) == "Checking availability...")
    }

    @Test func availabilityStateIsReady() {
        #expect(AppleIntelligenceEngine.AvailabilityState.available.isReady == true)
        #expect(AppleIntelligenceEngine.AvailabilityState.checking.isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.downloading(reason: "test").isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.notEnabled(reason: "test").isReady == false)
        #expect(AppleIntelligenceEngine.AvailabilityState.unsupported(reason: "test").isReady == false)
    }
}
