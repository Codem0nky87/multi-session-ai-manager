import Foundation
import Testing
import WebKit
@testable import MultiSessionAIManager

/// Signing in to a site from a browser space, with a real web view, the app's
/// real proxy, and a site at the far end that checks a Windows sign-in the way
/// a Windows server does (`SignInTestSite`). This is the proof that the
/// handshake itself works, and that one wrong password is one refused sign-in.
///
/// Opt-in: set `MSAM_WEBKIT_IT=1` (as `TEST_RUNNER_MSAM_WEBKIT_IT=1` for
/// `xcodebuild`). It needs WebKit's own processes, and on a simulator without a
/// screen, on a machine that is busy with something else, those are sometimes
/// suspended or killed in the middle of a page: on 2026-11-20 a run of these
/// failed that way, while 480 sign-ins on a quiet machine four days later all
/// went through. A test that fails for that says nothing about the app, so
/// this suite is not part of every run. What the page does with a challenge is
/// tested without WebKit's processes in `HostBrowserSignInPageTests`. Run this
/// suite before shipping a change to the sign-in, and read a failure's own
/// words: it says what the tab and the site were doing.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MSAM_WEBKIT_IT"] == "1"))
@MainActor struct HostBrowserSignInLiveTests {
    private final class NoProxy: HostBrowseProxyServing {
        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            throw SSHTransportError.notConnected
        }
    }

    /// One host's browser, browsing through the proxy to the site: a tab, and
    /// a second one when a test opens it.
    @MainActor private final class Browser {
        private(set) var page: HostBrowserPage?
        private(set) var secondTab: HostBrowserPage?
        private let browse = HostBrowseModel(server: NoProxy(), connect: { nil })
        private let site: SignInTestSite
        private let listener: any HostBrowseProxyListener
        private let endpoint: HostBrowseModel.Endpoint
        private let hostID = UUID()

        init(site: SignInTestSite) async throws {
            self.site = site
            (listener, endpoint) = try await site.proxy()
            let page = HostBrowserPage()
            page.attach(to: endpoint, hostID: hostID, hostName: "first-hop", browse: browse)
            self.page = page
        }

        func open(_ path: String) {
            page?.load(URL(string: "http://intranet\(path)")!)
        }

        /// What "+" does: another page of the same host's browser.
        func openSecondTab(_ path: String) {
            let tab = HostBrowserPage()
            tab.attach(to: endpoint, hostID: hostID, hostName: "first-hop", browse: browse)
            secondTab = tab
            tab.load(URL(string: "http://intranet\(path)")!)
        }

        /// The text of the page that is shown.
        var shown: String {
            get async { await Self.text(of: page) }
        }

        var shownInSecondTab: String {
            get async { await Self.text(of: secondTab) }
        }

        /// Where things stand, for a test that gave up waiting.
        var state: String {
            let tab = page.map { "loading=\($0.isLoading) failure=\($0.failure?.message ?? "none") asking=\($0.signInRequest != nil)" }
            return "tab: \(tab ?? "closed"); the site saw \(site.events)"
        }

        private static func text(of page: HostBrowserPage?) async -> String {
            guard let view = page?.webView else { return "" }
            return (try? await view.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
        }

        /// Lets the tab go, as closing it does, without answering anything first.
        func dropTab() {
            page = nil
        }

        func close() async {
            page?.stopLoading()
            secondTab?.stopLoading()
            page = nil
            secondTab = nil
            await listener.stop()
            await removeTestBrowserData(of: hostID)
        }
    }

    private static let rightUser = "\(SignInTestSite.domain)\\\(SignInTestSite.user)"

    private func eventually(_ what: String, in browser: Browser, timeout: Duration = .seconds(15),
                            _ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out waiting for: \(what). \(browser.state)")
    }

    /// Long enough for a sign-in that should not happen to have happened.
    private func aMoment() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    @Test func aWindowsSiteAsksForASignInAndShowsItsPageOnceItIsGiven() async throws {
        // What IIS offers: Kerberos first, then NTLM.
        let site = SignInTestSite(offers: [.negotiate, .ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")

        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        let asked = try #require(browser.page?.signInRequest)
        #expect(asked.kind == .windows)
        #expect(asked.site == "intranet")
        #expect(!asked.wasRefused)
        #expect(asked.user == "")
        #expect(site.events == ["asked /console"], "Nothing is tried before the user has answered")

        browser.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)

        #expect(browser.page?.signInRequest == nil)
        await eventually("the page", in: browser) { await browser.shown == "signed in at /console" }
        #expect(site.events.last == "ntlm ok \(Self.rightUser) /console")
        #expect(!site.events.contains { $0.hasPrefix("ntlm wrong") })
        await browser.close()
    }

    @Test func theRestOfTheSiteDoesNotAskAgain() async throws {
        // Every page on a connection of its own, so each one has to be signed in to.
        let site = SignInTestSite(offers: [.negotiate, .ntlm], closesAfterEachPage: true)
        let browser = try await Browser(site: site)
        browser.open("/")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        browser.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)
        await eventually("the first page", in: browser) { await browser.shown == "signed in at /" }

        browser.open("/second")

        await eventually("the second page", in: browser) { await browser.shown == "signed in at /second" }
        #expect(browser.page?.signInRequest == nil)
        #expect(site.events.filter { $0.hasPrefix("ntlm ok") } == ["ntlm ok \(Self.rightUser) /", "ntlm ok \(Self.rightUser) /second"])
        await browser.close()
    }

    @Test func aPasswordTheSiteTurnsDownIsAskedForAgainAndNotTriedAgainUnasked() async throws {
        let site = SignInTestSite(offers: [.negotiate, .ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        let first = try #require(browser.page?.signInRequest)

        browser.page?.answerSignIn(user: Self.rightUser, password: "not the password")

        await eventually("the sign-in to be asked for again", in: browser) { browser.page?.signInRequest.map { $0.id != first.id } ?? false }
        let second = try #require(browser.page?.signInRequest)
        #expect(second.wasRefused)
        #expect(second.user == Self.rightUser, "The name stays, to be corrected")
        // One wrong password is one refused sign-in at the server, however long the question waits.
        await aMoment()
        #expect(site.events.filter { $0.hasPrefix("ntlm wrong") }.count == 1)

        browser.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)

        await eventually("the page", in: browser) { await browser.shown == "signed in at /console" }
        #expect(site.events.filter { $0.hasPrefix("ntlm wrong") }.count == 1)
        await browser.close()
    }

    @Test func decliningShowsWhatTheSiteShowsAStranger() async throws {
        let site = SignInTestSite(offers: [.negotiate, .ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }

        browser.page?.declineSignIn()

        #expect(browser.page?.signInRequest == nil)
        await eventually("the site's own refusal", in: browser) { await browser.shown == SignInTestSite.refusalText }
        await aMoment()
        #expect(browser.page?.signInRequest == nil)
        #expect(!site.events.contains { $0.hasPrefix("ntlm") }, "No sign-in was tried")
        await browser.close()
    }

    /// Left to the system after a refusal, the refused password is sent again
    /// without end (1 600 times in 12 seconds when this was first tried), which
    /// locks a Windows account out.
    @Test func decliningAfterAWrongPasswordTriesNothingMore() async throws {
        let site = SignInTestSite(offers: [.negotiate, .ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        let first = try #require(browser.page?.signInRequest)
        browser.page?.answerSignIn(user: Self.rightUser, password: "not the password")
        await eventually("the sign-in to be asked for again", in: browser) { browser.page?.signInRequest.map { $0.id != first.id } ?? false }

        browser.page?.declineSignIn()

        await aMoment()
        #expect(site.events.filter { $0.hasPrefix("ntlm wrong") }.count == 1)
        #expect(browser.page?.signInRequest == nil)

        // And the refused password is not remembered: the page asks afresh.
        browser.open("/console")
        await eventually("the sign-in to be asked for on the next visit", in: browser) { browser.page?.signInRequest != nil }
        #expect(browser.page?.signInRequest?.wasRefused == false)
        #expect(site.events.filter { $0.hasPrefix("ntlm wrong") }.count == 1)
        await browser.close()
    }

    @Test func stoppingThePageWithdrawsTheQuestion() async throws {
        let site = SignInTestSite(offers: [.ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }

        browser.page?.stopLoading()

        #expect(browser.page?.signInRequest == nil)
        await aMoment()
        #expect(!site.events.contains { $0.hasPrefix("ntlm") })
        await browser.close()
    }

    /// WebKit raises an exception when a challenge is never answered, which
    /// would take the app down with the tab.
    @Test func aTabClosedWhileItAsksLeavesTheAppRunning() async throws {
        let site = SignInTestSite(offers: [.ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }

        browser.dropTab()

        await aMoment()
        #expect(!site.events.contains { $0.hasPrefix("ntlm") })
        await browser.close()
    }

    @Test func openingAnotherAddressWithdrawsTheQuestion() async throws {
        let site = SignInTestSite(offers: [.ntlm])
        let browser = try await Browser(site: site)
        browser.open("/console")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        let first = try #require(browser.page?.signInRequest)

        browser.open("/elsewhere")

        #expect(browser.page?.signInRequest == nil, "The question about the page that was left is gone at once")
        // The new page is a page of the same site, so it asks for itself.
        await eventually("the new page's own question", in: browser) { browser.page?.signInRequest != nil }
        #expect(browser.page?.signInRequest?.id != first.id)
        browser.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)
        await eventually("the new page", in: browser) { await browser.shown == "signed in at /elsewhere" }
        #expect(site.events.filter { $0.hasPrefix("ntlm ok") } == ["ntlm ok \(Self.rightUser) /elsewhere"])
        await browser.close()
    }

    @Test func anotherTabOfTheSameHostDoesNotAskAgain() async throws {
        let site = SignInTestSite(offers: [.negotiate, .ntlm], closesAfterEachPage: true)
        let browser = try await Browser(site: site)
        browser.open("/")
        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        browser.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)
        await eventually("the first tab's page", in: browser) { await browser.shown == "signed in at /" }

        browser.openSecondTab("/reports")

        await eventually("the second tab's page", in: browser) { await browser.shownInSecondTab == "signed in at /reports" }
        #expect(browser.secondTab?.signInRequest == nil)
        await browser.close()
    }

    /// Two hosts can reach different machines under one address (the same
    /// private address on two networks). What was typed for one must never be
    /// offered to the other.
    @Test func anotherHostsBrowserIsAskedForItself() async throws {
        let site = SignInTestSite(offers: [.negotiate, .ntlm], closesAfterEachPage: true)
        let first = try await Browser(site: site)
        first.open("/")
        await eventually("the sign-in to be asked for", in: first) { first.page?.signInRequest != nil }
        first.page?.answerSignIn(user: Self.rightUser, password: SignInTestSite.password)
        await eventually("the first host's page", in: first) { await first.shown == "signed in at /" }

        let other = try await Browser(site: site)
        other.open("/")

        await eventually("the other host's browser to ask for itself", in: other) { other.page?.signInRequest != nil }
        await aMoment()
        #expect(site.events.filter { $0.hasPrefix("ntlm ok") }.count == 1, "Nothing was answered on the other host's behalf")
        await first.close()
        await other.close()
    }

    @Test func aPasswordThatWouldTravelReadableIsSaidToBe() async throws {
        let site = SignInTestSite(offers: [.basic(realm: "Files")])
        let browser = try await Browser(site: site)
        browser.open("/files")

        await eventually("the sign-in to be asked for", in: browser) { browser.page?.signInRequest != nil }
        let asked = try #require(browser.page?.signInRequest)
        #expect(asked.kind == .basic)
        #expect(asked.isSentUnprotected, "The test site is plain HTTP")

        browser.page?.answerSignIn(user: SignInTestSite.user, password: SignInTestSite.password)

        await eventually("the page", in: browser) { await browser.shown == "signed in at /files" }
        #expect(site.events.last == "basic ok \(SignInTestSite.user) /files")
        await browser.close()
    }
}
