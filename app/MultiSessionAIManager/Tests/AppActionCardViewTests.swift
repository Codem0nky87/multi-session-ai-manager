import Foundation
import SwiftUI
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct AppActionCardViewTests {
    // 1. Title mappings for all AppAction variants
    @Test func actionCardTitleMappings() {
        #expect(AppActionCardView.title(for: .splitPane(direction: .down, stagedCommand: "pytest")) == "Split Pane Down")
        #expect(AppActionCardView.title(for: .splitPane(direction: .right, stagedCommand: nil)) == "Split Pane Right")
        #expect(AppActionCardView.title(for: .closePane) == "Close Pane")
        #expect(AppActionCardView.title(for: .zoomPane) == "Toggle Pane Zoom")
        #expect(AppActionCardView.title(for: .createHerdrTab(label: "tests", stagedCommand: nil)) == "Create Tab: tests")
        #expect(AppActionCardView.title(for: .switchHostTab(name: "Foundry")) == "Switch to Foundry")
        #expect(AppActionCardView.title(for: .openHostTab(hostName: "Spark")) == "Open Tab: Spark")
        #expect(AppActionCardView.title(for: .openAppSheet(sheet: .metrics)) == "Open Metrics Sheet")
        #expect(AppActionCardView.title(for: .openAppSheet(sheet: .pulse)) == "Open Pulse Sheet")
        #expect(AppActionCardView.title(for: .openAppSheet(sheet: .settings)) == "Open Settings Sheet")
    }

    // 2. Icon mappings for all AppAction variants
    @Test func actionCardIconMappings() {
        #expect(AppActionCardView.iconName(for: .splitPane(direction: .down, stagedCommand: nil)) == "rectangle.split.1x2.fill")
        #expect(AppActionCardView.iconName(for: .splitPane(direction: .right, stagedCommand: nil)) == "rectangle.split.2x1.fill")
        #expect(AppActionCardView.iconName(for: .closePane) == "xmark.rectangle.fill")
        #expect(AppActionCardView.iconName(for: .zoomPane) == "arrow.up.left.and.arrow.down.right")
        #expect(AppActionCardView.iconName(for: .createHerdrTab(label: "dev", stagedCommand: nil)) == "plus.rectangle.fill")
        #expect(AppActionCardView.iconName(for: .switchHostTab(name: "Foundry")) == "macwindow.on.rectangle")
        #expect(AppActionCardView.iconName(for: .openHostTab(hostName: "Spark")) == "macwindow.on.rectangle")
        #expect(AppActionCardView.iconName(for: .openAppSheet(sheet: .metrics)) == "chart.bar.fill")
        #expect(AppActionCardView.iconName(for: .openAppSheet(sheet: .pulse)) == "waveform.path.ecg")
        #expect(AppActionCardView.iconName(for: .openAppSheet(sheet: .settings)) == "gearshape.fill")
    }

    // 3. Staged command extraction
    @Test func stagedCommandExtraction() {
        let splitWithCommand = AppAction.splitPane(direction: .down, stagedCommand: "pytest tests/unit")
        #expect(AppActionCardView.stagedCommand(for: splitWithCommand) == "pytest tests/unit")

        let splitWithoutCommand = AppAction.splitPane(direction: .right, stagedCommand: nil)
        #expect(AppActionCardView.stagedCommand(for: splitWithoutCommand) == nil)

        let tabWithCommand = AppAction.createHerdrTab(label: "logs", stagedCommand: "tail -f app.log")
        #expect(AppActionCardView.stagedCommand(for: tabWithCommand) == "tail -f app.log")

        let tabWithoutCommand = AppAction.createHerdrTab(label: "logs", stagedCommand: nil)
        #expect(AppActionCardView.stagedCommand(for: tabWithoutCommand) == nil)

        #expect(AppActionCardView.stagedCommand(for: .closePane) == nil)
        #expect(AppActionCardView.stagedCommand(for: .zoomPane) == nil)
        #expect(AppActionCardView.stagedCommand(for: .switchHostTab(name: "Foundry")) == nil)
        #expect(AppActionCardView.stagedCommand(for: .openHostTab(hostName: "Spark")) == nil)
        #expect(AppActionCardView.stagedCommand(for: .openAppSheet(sheet: .metrics)) == nil)
    }

    // 4. State transitions: pending -> applied
    @Test func stateTransitionSuccessfulApply() async {
        var applied = false
        let nextState = await AppActionCardView.transition(from: .pending) {
            applied = true
        }
        #expect(applied == true)
        #expect(nextState == .applied)
    }

    // 5. State transitions: pending -> failed
    @Test func stateTransitionFailedApply() async {
        struct DummyError: LocalizedError {
            var errorDescription: String? { "Host disconnected unexpectedly" }
        }

        let nextState = await AppActionCardView.transition(from: .pending) {
            throw DummyError()
        }
        #expect(nextState == .failed("Host disconnected unexpectedly"))
    }

    // 6. State transitions: failed -> applied on retry
    @Test func stateTransitionRetryFromFailed() async {
        var retried = false
        let nextState = await AppActionCardView.transition(from: .failed("some error")) {
            retried = true
        }
        #expect(retried == true)
        #expect(nextState == .applied)
    }

    // 7. Card view construction and dismiss callback
    @Test func actionCardDismissCallbackInvoked() {
        var dismissed = false
        let view = AppActionCardView(
            action: .closePane,
            onApply: {},
            onDismiss: { dismissed = true }
        )
        view.onDismiss()
        #expect(dismissed == true)
    }

    // 8. MessageView renders with action handlers
    @Test func messageViewIntegratesActionCardHandlers() async throws {
        let action = AppAction.splitPane(direction: .down, stagedCommand: "cargo build")
        let msg = AppleIntelligenceEngine.ChatMessage(
            role: .assistant,
            content: "I can split the pane for you.",
            action: action
        )

        var appliedAction: AppAction?
        var dismissedMessageID: UUID?

        let view = AppleIntelligenceMessageView(
            message: msg,
            onInsertToTerminal: { _ in },
            onApplyAction: { appliedAction = $0 },
            onDismissAction: { dismissedMessageID = $0 }
        )

        try await view.onApplyAction?(action)
        #expect(appliedAction == action)

        view.onDismissAction?(msg.id)
        #expect(dismissedMessageID == msg.id)
    }

    // 9. AppleIntelligenceEngine dismissAction clears action
    @Test func engineDismissActionClearsAction() async {
        let responseWithAction = """
        Splitting pane now.
        ```action
        {"type": "split_pane", "direction": "down"}
        ```
        """
        let mockBackend = MockLanguageModelBackend(
            available: true,
            streamChunks: [responseWithAction]
        )
        let engine = AppleIntelligenceEngine(backend: mockBackend)

        await engine.sendPrompt("Please split pane")

        #expect(engine.messages.count == 2)
        let assistantMsg = engine.messages[1]
        #expect(assistantMsg.role == .assistant)
        #expect(assistantMsg.action == .splitPane(direction: .down, stagedCommand: nil))

        engine.dismissAction(for: assistantMsg.id)
        #expect(engine.messages[1].action == nil)
    }
}
