import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AppActionExtractorTests {
    @Test func extractsSplitPaneActionWithStagedCommandAndStripsBlock() {
        let raw = """
        I will split the window and run the tests for you.
        ```action
        {
          "type": "split_pane",
          "direction": "down",
          "staged_command": "pytest -v"
        }
        ```
        Let me know if you need anything else!
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .splitPane(direction: .down, stagedCommand: "pytest -v"))
        #expect(result.cleanText.contains("I will split the window"))
        #expect(result.cleanText.contains("Let me know if you need anything else!"))
        #expect(!result.cleanText.contains("```action"))
        #expect(!result.cleanText.contains("\"split_pane\""))
    }

    @Test func extractsSplitPaneActionRightWithoutStagedCommand() {
        let raw = """
        ```action
        {
          "type": "split_pane",
          "direction": "right"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .splitPane(direction: .right, stagedCommand: nil))
        #expect(result.cleanText.isEmpty)
    }

    @Test func extractsSwitchHostTabAction() {
        let raw = """
        Switching to the Foundry host tab.
        ```action
        {
          "type": "switch_host_tab",
          "target": "Foundry"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .switchHostTab(name: "Foundry"))
        #expect(!result.cleanText.contains("```action"))
    }

    @Test func extractsCreateHerdrTabAction() {
        let raw = """
        ```action
        {
          "type": "create_herdr_tab",
          "label": "build",
          "staged_command": "cargo check"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .createHerdrTab(label: "build", stagedCommand: "cargo check"))
    }

    @Test func extractsCreateHerdrTabWithTargetFallback() {
        let raw = """
        ```action
        {
          "type": "create_herdr_tab",
          "target": "server-logs"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .createHerdrTab(label: "server-logs", stagedCommand: nil))
    }

    @Test func extractsClosePaneAction() {
        let raw = """
        Closing the pane.
        ```action
        {
          "type": "close_pane"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .closePane)
        #expect(result.cleanText == "Closing the pane.")
    }

    @Test func extractsZoomPaneAction() {
        let raw = """
        Zooming pane.
        ```action
        {
          "type": "zoom_pane"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .zoomPane)
    }

    @Test func extractsOpenHostTabAction() {
        let raw = """
        Opening Mac mini host.
        ```action
        {
          "type": "open_host_tab",
          "target": "Mac mini"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == .openHostTab(hostName: "Mac mini"))
    }

    @Test func extractsOpenAppSheetAction() {
        let rawMetrics = """
        ```action
        {
          "type": "open_sheet",
          "sheet": "metrics"
        }
        ```
        """
        #expect(AppActionExtractor.extract(from: rawMetrics).action == .openAppSheet(sheet: .metrics))

        let rawPulse = """
        ```action
        {
          "type": "open_sheet",
          "sheet": "pulse"
        }
        ```
        """
        #expect(AppActionExtractor.extract(from: rawPulse).action == .openAppSheet(sheet: .pulse))

        let rawSettings = """
        ```action
        {
          "type": "open_sheet",
          "sheet": "settings"
        }
        ```
        """
        #expect(AppActionExtractor.extract(from: rawSettings).action == .openAppSheet(sheet: .settings))

        let rawDefault = """
        ```action
        {
          "type": "open_sheet"
        }
        ```
        """
        #expect(AppActionExtractor.extract(from: rawDefault).action == .openAppSheet(sheet: .settings))
    }

    @Test func handlesTextWithoutAction() {
        let raw = "Here is regular advice without any action blocks."
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == nil)
        #expect(result.cleanText == raw)
    }

    @Test func handlesMalformedActionJsonGracefully() {
        let raw = """
        Trying action:
        ```action
        { not valid json }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == nil)
        #expect(result.cleanText.contains("Trying action:"))
    }

    @Test func handlesUnknownActionTypeGracefully() {
        let raw = """
        ```action
        {
          "type": "unknown_future_command"
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == nil)
        #expect(result.cleanText.isEmpty)
    }

    @Test func handlesEmptyHostTargetsGracefully() {
        let raw = """
        ```action
        {
          "type": "switch_host_tab",
          "target": ""
        }
        ```
        """
        let result = AppActionExtractor.extract(from: raw)
        #expect(result.action == nil)
    }
}
