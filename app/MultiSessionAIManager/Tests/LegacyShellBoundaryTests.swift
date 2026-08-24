import Foundation
import Testing

@Suite struct LegacyShellBoundaryTests {
    @Test func legacyMSAMVSCodeWorkspaceAndTmuxShellAreAbsentFromSources() throws {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let forbiddenPaths = [
            "UI/VSCode",
            "UI/Sessions/AddColumnSheet.swift",
            "UI/Sessions/AttentionBadges.swift",
            "UI/Sessions/CanvasModel.swift",
            "UI/Sessions/ColumnCanvasView.swift",
            "UI/Sessions/ColumnView.swift",
            "UI/Sessions/HostConnection.swift",
            "UI/Sessions/HostScreen.swift",
            "UI/Sessions/SessionListView.swift",
            "UI/Sessions/SessionStrip.swift",
            "UI/Sessions/TerminalScreen.swift",
            "UI/Sessions/WorkspaceBar.swift",
            "UI/Sessions/WorkspacesScreen.swift",
            "UI/Hosts/TmuxConfigSheet.swift",
            "UI/Files/FileBrowserView.swift",
            "UI/Terminal/TerminalToolbar.swift",
            "Tests/AttentionDetectionTests.swift",
            "Core/Backoff.swift",
            "Core/ConnectionRegistry.swift",
            "Core/Reconnector.swift",
            "Core/SessionNaming.swift",
            "Core/SessionStore.swift",
            "Core/TermKey.swift",
            "Core/TmuxConfigEditor.swift",
            "Core/TmuxConfigModel.swift",
            "Core/TmuxParser.swift",
            "Core/Workspace.swift"
        ]

        for path in forbiddenPaths {
            #expect(
                !fileManager.fileExists(atPath: projectRoot.appendingPathComponent(path).path),
                "Legacy source remains at \(path)"
            )
        }

        let sourceRoots = ["App", "Core", "UI"]
        let forbiddenSymbols = [
            "VSCodeEndpoint",
            "VSCodeScreen",
            "VSCodeURL",
            "WebViewConnection",
            "WorkspacesScreen",
            "ColumnCanvasView",
            "WorkspaceStore",
            "SessionStore",
            "TmuxConfigModel",
            "TmuxParser",
            "ClaudePromptSignatures",
            "hasUnseenOutput",
            "didBell",
            "needsInput",
            "columnFocusUsesParentTapGesture"
        ]
        let swiftSources = sourceRoots.flatMap { root -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: projectRoot.appendingPathComponent(root),
                includingPropertiesForKeys: nil
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        let combinedSource = try swiftSources
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for symbol in forbiddenSymbols {
            #expect(!combinedSource.contains(symbol), "Legacy symbol remains: \(symbol)")
        }
        #expect(!combinedSource.localizedCaseInsensitiveContains("code-server"))
        #expect(!combinedSource.localizedCaseInsensitiveContains("vscode"))
        #expect(!combinedSource.localizedCaseInsensitiveContains("tmux"))
    }
}
