import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct AppRuntimeContextTests {
    @Test func formatsPromptContextWithTabsAndActiveHost() {
        let ctx = AppRuntimeContext(
            hostTabs: ["Forge", "Foundry", "Spark"],
            selectedHostTab: "Foundry",
            activeHostName: "Foundry",
            currentDirectory: "/home/rufus/Projects/app"
        )
        let prompt = ctx.promptContext
        #expect(prompt.contains("Open Host Tabs: [Forge, Foundry (active), Spark]"))
        #expect(prompt.contains("Active Host: Foundry"))
        #expect(prompt.contains("Working Directory: /home/rufus/Projects/app"))
        #expect(prompt.contains("```action"))
    }

    @Test func formatsPromptContextWithEmptyHostTabs() {
        let ctx = AppRuntimeContext()
        let prompt = ctx.promptContext
        #expect(!prompt.contains("Open Host Tabs:"))
        #expect(!prompt.contains("Active Host:"))
        #expect(!prompt.contains("Working Directory:"))
        #expect(prompt.contains("You are the Apple Intelligence assistant"))
        #expect(prompt.contains("```action"))
    }

    @Test func chatMessageHoldsExtractedAction() {
        let action = AppAction.switchHostTab(name: "Forge")
        let msg = AppleIntelligenceEngine.ChatMessage(
            role: .assistant,
            content: "Switching now",
            action: action
        )
        #expect(msg.action == action)
    }

    @Test func engineExtractsActionFromStreamedResponse() async {
        let responseChunks = [
            "I'll switch you to the Forge host tab right now.\n\n",
            "```action\n",
            "{\"type\": \"switch_host_tab\", \"target\": \"Forge\"}\n",
            "```\n"
        ]
        let mock = MockLanguageModelBackend(available: true, streamChunks: responseChunks)
        let engine = AppleIntelligenceEngine(backend: mock)
        let runtimeContext = AppRuntimeContext(
            hostTabs: ["Forge", "Foundry"],
            selectedHostTab: "Foundry",
            activeHostName: "Foundry",
            currentDirectory: "/home/rufus/Projects"
        )
        await engine.sendPrompt("Switch to Forge", runtimeContext: runtimeContext)

        #expect(mock.lastRuntimeContext == runtimeContext)
        #expect(engine.messages.count == 2)
        let assistantMsg = engine.messages[1]
        #expect(assistantMsg.role == .assistant)
        #expect(assistantMsg.action == .switchHostTab(name: "Forge"))
        #expect(assistantMsg.content == "I'll switch you to the Forge host tab right now.")
        #expect(!assistantMsg.isStreaming)
    }
}
