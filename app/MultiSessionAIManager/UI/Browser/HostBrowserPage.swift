import Network
import Observation
import SwiftUI
import WebKit

/// The web view of one tab of a browser space and what its pane shows about it.
@MainActor
@Observable
final class HostBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// True once a page has been committed: until then there is nothing to show.
    private(set) var hasPage = false
    private(set) var currentAddress = ""
    /// The page's own title, for its tab.
    private(set) var title = ""
    private(set) var failure: HostBrowserFailure?
    /// The sign-in a site of this page is waiting for, to be asked over the page.
    private(set) var signInRequest: HostBrowserSignInRequest?

    @ObservationIgnored private var endpoint: HostBrowseModel.Endpoint?
    @ObservationIgnored private var hostName = ""
    @ObservationIgnored private weak var browse: HostBrowseModel?
    @ObservationIgnored private var exceptions = HostBrowseCertificateExceptions()
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var titleWatch: NSKeyValueObservation?
    @ObservationIgnored private var signIns = HostBrowserSignIns()

    /// The proxy settings every request of this browser goes through. No
    /// fallback: when the proxy is gone a page fails, it is not fetched directly
    /// from this device.
    static func proxyConfiguration(for endpoint: HostBrowseModel.Endpoint) -> ProxyConfiguration? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: endpoint.port)), endpoint.port > 0 else { return nil }
        var configuration = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
        configuration.applyCredential(username: endpoint.credentials.username, password: endpoint.credentials.password)
        configuration.allowFailover = false
        return configuration
    }

    /// Points the browser at a session's proxy. A new session has a new port and
    /// password, so the web view is made again for it.
    func attach(to endpoint: HostBrowseModel.Endpoint, hostID: UUID, hostName: String, browse: HostBrowseModel) {
        guard endpoint != self.endpoint, let proxy = Self.proxyConfiguration(for: endpoint) else { return }
        self.endpoint = endpoint
        self.hostName = hostName
        self.browse = browse
        // Each host has its own cookies and sign-ins, apart from every other
        // host's and from the rest of the app.
        let store = WKWebsiteDataStore(forIdentifier: hostID)
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        // A page can change its title long after it has loaded.
        titleWatch = view.observe(\.title) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshTitle() }
        }
        // The page that just failed is what was wanted; else the page it was on.
        let reopen = failure != nil ? failedURL : (hasPage ? webView?.url : nil)
        // What the old web view was asked is not this one's to answer.
        abandonSignIns()
        webView = view
        hasPage = false
        failure = nil
        refresh()
        if let reopen { load(reopen) }
    }

    func load(_ url: URL) {
        failure = nil
        abandonSignIns()
        browse?.clearRefusal()
        guard let webView else { return }
        webView.load(URLRequest(url: url))
        // Shown at once: over a slow link the first sign from the page can take a while.
        isLoading = true
    }

    func reload() {
        failure = nil
        abandonSignIns()
        browse?.clearRefusal()
        if let failedURL, webView?.url == nil || !hasPage {
            webView?.load(URLRequest(url: failedURL))
        } else {
            webView?.reload()
        }
    }

    func stopLoading() {
        abandonSignIns()
        webView?.stopLoading()
    }

    func goBack() {
        failure = nil
        abandonSignIns()
        webView?.goBack()
    }

    func goForward() {
        failure = nil
        abandonSignIns()
        webView?.goForward()
    }

    /// The user's answer to the sign-in that is shown. It is kept until the app
    /// closes, for this host's browser only, so the rest of the site and its
    /// later pages do not ask again. Nothing is written to the device.
    func answerSignIn(user: String, password: String) {
        signIns.answer(.credentials(user: user, password: password))
        signInRequest = signIns.current
    }

    /// The user would rather not sign in: the site shows what it shows a stranger.
    func declineSignIn() {
        signIns.answer(.nothing)
        signInRequest = signIns.current
    }

    /// The page the sign-ins were asked for is being left.
    private func abandonSignIns() {
        signIns.abandonAll()
        signInRequest = nil
    }

    /// The user accepts the certificate of the site that just failed.
    func visitAnyway() {
        guard let failedURL, failure?.canVisitAnyway == true else { return }
        exceptions.accept(siteOf: failedURL)
        load(failedURL)
    }

    private func refresh() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        isLoading = webView?.isLoading ?? false
        if let url = webView?.url { currentAddress = url.absoluteString }
        refreshTitle()
    }

    private func refreshTitle() {
        let current = webView?.title ?? ""
        if title != current { title = current }
    }

    private func failed(_ error: Error) {
        let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView?.url
        refresh()
        guard let described = HostBrowserFailure.describe(error, url: url, refusal: browse?.lastRefusal, hostName: hostName) else { return }
        failedURL = url
        failure = described
        // A page also fails when the proxy on this device has stopped
        // listening, and then every page does until it is replaced. A new
        // proxy changes the browser's state, and whoever shows this tab points
        // it there, which opens the page again.
        Task { [weak browse] in await browse?.repair() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        // A sign-in still waiting now belongs to the page this one replaces.
        abandonSignIns()
        refresh()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasPage = true
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if let trust = space.serverTrust,
           exceptions.allows(authenticationMethod: space.authenticationMethod, host: space.host, port: space.port,
                             hasServerTrust: true) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        switch HostBrowserChallenge.of(method: space.authenticationMethod, isProxy: space.isProxy(),
                                       failures: challenge.previousFailureCount) {
        case .ask(let kind):
            // A web view that has been replaced has nobody left to ask.
            guard webView === self.webView else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            signIns.ask(host: space.host, port: space.port, usesTLS: space.protocol == "https", kind: kind,
                        failures: challenge.previousFailureCount, user: challenge.proposedCredential?.user ?? "") { reply in
                switch reply {
                case .credentials(let user, let password):
                    // For the session: WebKit keeps it in memory for this host's
                    // browser and answers the site's other connections with it.
                    completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
                case .nothing:
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            signInRequest = signIns.current
        case .tryTheNextOffer:
            completionHandler(.rejectProtectionSpace, nil)
        case .leaveAlone:
            completionHandler(.performDefaultHandling, nil)
        case .giveUp:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window opens here, in the tab it was tapped in.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct HostBrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
