import Foundation
import Testing
import WebKit
@testable import MultiSessionAIManager

/// Removes what a test's browser kept on the device. Each host's browser has
/// data of its own there, and a test's must not pile up. It can only go once
/// its web views are gone, which takes WebKit a moment after the last one is
/// let go.
@MainActor
func removeTestBrowserData(of hostID: UUID) async {
    for attempt in 1...60 {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: hostID)
            return
        } catch {
            if attempt == 60 { Issue.record("The test's browser data stayed on the device: \(error)") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// What a tab of a browser space does when a site wants proof of who is asking.
/// The challenges are handed to the page as WebKit hands them over, so nothing
/// here needs a network or a page to load; `HostBrowserSignInLiveTests` holds
/// the same page against a site that really checks a Windows sign-in.
@Suite(.serialized) @MainActor struct HostBrowserSignInPageTests {
    private final class NoProxy: HostBrowseProxyServing {
        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            throw SSHTransportError.notConnected
        }
    }

    private final class Nobody: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// What WebKit was told to do with one challenge.
    private struct Answer: Equatable {
        let disposition: URLSession.AuthChallengeDisposition
        var user: String?
        var password: String?
        var keptFor: URLCredential.Persistence?

        static let endedTheRequest = Answer(disposition: .cancelAuthenticationChallenge)
        static let leftToTheSystem = Answer(disposition: .performDefaultHandling)
        static let passedOver = Answer(disposition: .rejectProtectionSpace)
    }

    /// The answers one challenge got. There must only ever be one.
    @MainActor private final class Asked {
        var answers: [Answer] = []

        var handler: @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void {
            { [self] disposition, credential in
                answers.append(Answer(disposition: disposition, user: credential?.user, password: credential?.password,
                                      keptFor: credential?.persistence))
            }
        }
    }

    /// One tab of a host's browser, as a browser space makes it.
    @MainActor private final class Tab {
        private(set) var page: HostBrowserPage?
        private let browse = HostBrowseModel(server: NoProxy(), connect: { nil })
        private let hostID = UUID()
        private var port = 50_990

        init() {
            let page = HostBrowserPage()
            self.page = page
            attach()
        }

        /// Points the tab at a proxy, as a (re)connected host does. Every call
        /// is a new proxy, so the tab gets a new web view.
        func attach() {
            port += 1
            let endpoint = HostBrowseModel.Endpoint(
                port: port, credentials: HostBrowseProxyCredentials(username: "browser", password: "only-the-browser-knows"))
            page?.attach(to: endpoint, hostID: hostID, hostName: "first-hop", browse: browse)
        }

        /// A site (or a proxy) asks who is there, the way WebKit passes it on.
        @discardableResult
        func isAsked(_ method: String, by host: String = "console.internal.example", port: Int = 443, https: Bool = true,
                     asProxy: Bool = false, failures: Int = 0, triedAs user: String? = nil,
                     from view: WKWebView? = nil) throws -> Asked {
            let page = try #require(page)
            let view = try #require(view ?? page.webView)
            let space = asProxy
                ? URLProtectionSpace(proxyHost: host, port: port, type: NSURLProtectionSpaceSOCKSProxy, realm: nil,
                                     authenticationMethod: method)
                : URLProtectionSpace(host: host, port: port, protocol: https ? "https" : "http", realm: nil,
                                     authenticationMethod: method)
            let proposed = user.map { URLCredential(user: $0, password: "what was tried", persistence: .none) }
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: proposed,
                                                       previousFailureCount: failures, failureResponse: nil, error: nil,
                                                       sender: Nobody())
            let asked = Asked()
            page.webView(view, didReceive: challenge, completionHandler: asked.handler)
            return asked
        }

        /// Closing the tab: the page is simply let go.
        func drop() {
            page = nil
        }

        func close() async {
            page?.stopLoading()
            page = nil
            await removeTestBrowserData(of: hostID)
        }
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func aSiteThatWantsAWindowsAccountIsAskedAboutAndAnsweredWithWhatTheUserTyped() async throws {
        let tab = Tab()

        let site = try tab.isAsked(NSURLAuthenticationMethodNTLM, by: "192.0.2.30")

        let request = try #require(tab.page?.signInRequest)
        #expect(request.title == "Sign in to 192.0.2.30")
        #expect(request.kind == .windows)
        #expect(!request.wasRefused)
        #expect(request.user == "")
        #expect(site.answers.isEmpty, "Nothing is answered before the user has")

        tab.page?.answerSignIn(user: "CORP\\operator", password: "what the user typed")

        // Kept for the session: in memory, for this host's browser, until the app closes.
        #expect(site.answers == [Answer(disposition: .useCredential, user: "CORP\\operator", password: "what the user typed",
                                        keptFor: .forSession)])
        #expect(tab.page?.signInRequest == nil)
        await tab.close()
    }

    /// Left to the system, a refused password is sent again without end, which
    /// locks a Windows account out. See `HostBrowserChallenge`.
    @Test func decliningEndsTheRequestAndIsNotLeftToTheSystem() async throws {
        let tab = Tab()
        let site = try tab.isAsked(NSURLAuthenticationMethodNTLM, failures: 1, triedAs: "CORP\\operator")

        tab.page?.declineSignIn()

        #expect(site.answers == [.endedTheRequest])
        #expect(tab.page?.signInRequest == nil)
        await tab.close()
    }

    @Test func aRefusedSignInIsAskedAboutAgainWithTheNameThatWasTried() async throws {
        let tab = Tab()

        let site = try tab.isAsked(NSURLAuthenticationMethodNTLM, failures: 1, triedAs: "CORP\\operator")

        let request = try #require(tab.page?.signInRequest)
        #expect(request.wasRefused)
        #expect(request.user == "CORP\\operator")
        #expect(site.answers.isEmpty, "The refused password is not tried again unasked")
        await tab.close()
    }

    @Test func aBasicSignInWithoutHTTPSIsSaidToTravelReadable() async throws {
        let tab = Tab()

        try tab.isAsked(NSURLAuthenticationMethodHTTPBasic, by: "files.internal.example", port: 8080, https: false)

        let request = try #require(tab.page?.signInRequest)
        #expect(request.kind == .basic)
        #expect(request.site == "files.internal.example:8080")
        #expect(request.isSentUnprotected)
        await tab.close()
    }

    @Test func kerberosIsPassedOverAtOnceSoTheWindowsSignInComesUp() async throws {
        let tab = Tab()

        let first = try tab.isAsked(NSURLAuthenticationMethodNegotiate)
        #expect(first.answers == [.passedOver])
        #expect(tab.page?.signInRequest == nil)

        // Once the site has said no there is no going round again.
        let again = try tab.isAsked(NSURLAuthenticationMethodNegotiate, failures: 1)
        #expect(again.answers == [.endedTheRequest])
        await tab.close()
    }

    @Test func theAppsOwnProxyIsNotAskedAbout() async throws {
        let tab = Tab()

        let proxy = try tab.isAsked(NSURLAuthenticationMethodHTTPBasic, by: "127.0.0.1", port: 50_991, asProxy: true)
        #expect(proxy.answers == [.leftToTheSystem])
        #expect(tab.page?.signInRequest == nil)

        let refused = try tab.isAsked(NSURLAuthenticationMethodHTTPBasic, by: "127.0.0.1", port: 50_991, asProxy: true, failures: 1)
        #expect(refused.answers == [.endedTheRequest])
        #expect(tab.page?.signInRequest == nil)
        await tab.close()
    }

    @Test func aCertificateTheUserHasNotAcceptedIsLeftToTheSystem() async throws {
        let tab = Tab()

        let site = try tab.isAsked(NSURLAuthenticationMethodServerTrust)

        #expect(site.answers == [.leftToTheSystem])
        #expect(tab.page?.signInRequest == nil)
        await tab.close()
    }

    @Test func sitesAreAskedAboutOneAtATime() async throws {
        let tab = Tab()
        let console = try tab.isAsked(NSURLAuthenticationMethodNTLM, by: "console.internal.example")
        let files = try tab.isAsked(NSURLAuthenticationMethodHTTPBasic, by: "files.internal.example")
        #expect(tab.page?.signInRequest?.site == "console.internal.example")

        tab.page?.answerSignIn(user: "CORP\\operator", password: "first")

        #expect(console.answers.map(\.user) == ["CORP\\operator"])
        #expect(files.answers.isEmpty)
        #expect(tab.page?.signInRequest?.site == "files.internal.example")

        tab.page?.declineSignIn()

        #expect(files.answers == [.endedTheRequest])
        #expect(console.answers.count == 1)
        #expect(tab.page?.signInRequest == nil)
        await tab.close()
    }

    @Test(arguments: ["another address", "reload", "stop", "back", "forward", "a new page starting"])
    func leavingThePageWithdrawsItsQuestion(by way: String) async throws {
        let tab = Tab()
        let site = try tab.isAsked(NSURLAuthenticationMethodNTLM)
        // In a scope of its own: a web view that is still held keeps its data on the device.
        do {
            let page = try #require(tab.page)
            let view = try #require(page.webView)
            switch way {
            case "another address": page.load(try #require(URL(string: "http://elsewhere.internal.example/")))
            case "reload": page.reload()
            case "stop": page.stopLoading()
            case "back": page.goBack()
            case "forward": page.goForward()
            default: page.webView(view, didStartProvisionalNavigation: nil)
            }
        }

        #expect(tab.page?.signInRequest == nil)
        #expect(site.answers == [.endedTheRequest])
        await tab.close()
    }

    @Test func aReconnectWithdrawsWhatTheOldWebViewWasAsked() async throws {
        let tab = Tab()
        do {
            let old = try #require(tab.page?.webView)
            let before = try tab.isAsked(NSURLAuthenticationMethodNTLM)

            tab.attach()

            #expect(tab.page?.webView !== old)
            #expect(before.answers == [.endedTheRequest])
            #expect(tab.page?.signInRequest == nil)

            // And what the old web view still asks afterwards has nobody to ask.
            let late = try tab.isAsked(NSURLAuthenticationMethodNTLM, from: old)
            #expect(late.answers == [.endedTheRequest])
            #expect(tab.page?.signInRequest == nil)
        }
        await tab.close()
    }

    /// WebKit raises an exception for a challenge that is never answered, which
    /// takes the whole app down: seen when this was left out.
    @Test func aTabThatIsClosedWhileItAsksStillAnswers() async throws {
        let tab = Tab()
        let site = try tab.isAsked(NSURLAuthenticationMethodNTLM)
        #expect(site.answers.isEmpty)

        tab.drop()

        await eventually("the closed tab's answer") { !site.answers.isEmpty }
        #expect(site.answers == [.endedTheRequest])
        await tab.close()
    }
}
