import Foundation
import Testing
@testable import MultiSessionAIManager

/// Where a browser space is opened from. A tap on a SwiftUI control cannot be
/// made in a hosted unit test, so the wiring is pinned by reading the source.
@Suite struct BrowserSpaceEntryTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func aTapIsOfferedToTheAppBeforeItIsSentToHerdr() throws {
        let view = try source("UI/Terminal/TerminalEmulatorView.swift")
        let handler = try #require(view.range(of: "private func handleTerminalTap"))
        let body = view[handler.lowerBound...]
        let intercept = try #require(body.range(of: "interceptTap(cell.col, cell.row)"))
        let forwarded = try #require(body.range(of: "TerminalMouse.sgr(.press"))
        #expect(intercept.lowerBound < forwarded.lowerBound)
    }

    @Test func newOffersAWorkspaceOrABrowser() throws {
        let root = try source("UI/RootView.swift")
        #expect(root.contains("TerminalNewSpaceButton.isHit("))
        #expect(root.contains("Button(\"Workspace\")"))
        #expect(root.contains("Button(\"Browser\")"))
    }

    @Test func choosingWorkspaceSendsHerdrTheTapItWouldHaveHad() throws {
        let root = try source("UI/RootView.swift")
        let workspace = try #require(root.range(of: "Button(\"Workspace\")"))
        let browser = try #require(root.range(of: "Button(\"Browser\")"))
        let action = root[workspace.lowerBound..<browser.lowerBound]
        #expect(action.contains("TerminalMouse.sgr(.press, col: tap.column, row: tap.row)"))
        #expect(action.contains("TerminalMouse.sgr(.release, col: tap.column, row: tap.row)"))
    }

    @Test func theHostTabsMenuOpensABrowserSpace() throws {
        #expect(try source("UI/HostTabStrip.swift").contains("Button(\"New Browser Space\")"))
        #expect(try source("UI/RootView.swift").contains("onNewBrowserSpace: { openBrowserSpace(in: $0) }"))
    }

    @Test func theBrowserIsNoLongerInPortForwarding() throws {
        let sheet = try source("UI/WebTunnel/SessionWebTunnelSheet.swift")
        #expect(!sheet.contains("Browse Through"))
        #expect(!sheet.contains("HostBrowserScreen"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("UI/WebTunnel/HostBrowserScreen.swift").path))
    }

    @Test func theBrowsersBarHasAPlusThatOpensATab() throws {
        let pane = try source("UI/Browser/HostBrowserPane.swift")
        let button = try #require(pane.range(of: "accessibilityIdentifier(\"browser-space.new-tab\")"))
        let before = pane[..<button.lowerBound]
        let action = try #require(before.range(of: "tabs.add()", options: .backwards))
        #expect(pane.distance(from: action.lowerBound, to: button.lowerBound) < 600, "The plus is what adds the tab")
        #expect(pane.contains("Image(systemName: \"plus\")"))
        #expect(pane.contains(".disabled(!tabs.canAdd)"))
    }

    @Test func theTabsShowOnceThereIsMoreThanOne() throws {
        let pane = try source("UI/Browser/HostBrowserPane.swift")
        #expect(pane.contains("if tabs.tabs.count > 1"))
        #expect(pane.contains("tabs.select(tab.id)"))
        #expect(pane.contains("tabs.close(tab.id)"))
    }

    @Test func theWebViewShownIsTheOneOfTheTabShown() throws {
        // A representable is not made again for a new value by itself: without
        // an identity the first tab's page stayed on screen for every tab.
        #expect(try source("UI/Browser/HostBrowserPane.swift").contains(".id(ObjectIdentifier(webView))"))
    }
}

