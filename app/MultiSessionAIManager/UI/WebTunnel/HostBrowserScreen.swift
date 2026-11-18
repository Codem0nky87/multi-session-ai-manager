import Network
import Observation
import SwiftUI
import WebKit

/// "Browse through this host": an In App browser whose every request is made by
/// the SSH host. Type an address as you would on the host; names are looked up
/// there. The proxy behind it runs only while this screen is open.
struct HostBrowserScreen: View {
    let session: PortForwardingSession

    @Environment(\.dismiss) private var dismiss
    @State private var page = HostBrowserPage()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var browse: HostBrowseModel { session.browse }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                Divider().overlay(Theme.hairline)
                ZStack {
                    Theme.bg
                    content
                }
            }
            .background(Theme.bg)
            .navigationTitle("Browse through \(session.host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("browse.done")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { page.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!page.canGoBack)
                        .accessibilityLabel("Back")
                    Button { page.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!page.canGoForward)
                        .accessibilityLabel("Forward")
                    Button {
                        if page.isLoading { page.stopLoading() } else { page.reload() }
                    } label: {
                        Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                    }
                    .disabled(!page.hasPage)
                    .accessibilityLabel(page.isLoading ? "Stop" : "Reload")
                }
            }
        }
        .task { await browse.start() }
        // The proxy lives as long as the browser: nothing listens once it is closed.
        .onDisappear { Task { await browse.stop() } }
        .onChange(of: browse.state, initial: true) { _, state in
            if case .ready(let endpoint) = state {
                page.attach(to: endpoint, hostID: session.host.id, hostName: session.host.name, browse: browse)
            }
        }
        .onChange(of: page.currentAddress) { _, current in
            // Follow the page, but never overwrite what is being typed.
            if !addressFocused, !current.isEmpty { address = current }
        }
    }

    private var addressBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: page.currentAddress.hasPrefix("https://") ? "lock.fill" : "globe")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("Address, as seen from \(session.host.name)", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .font(Theme.mono(14))
                .onSubmit(go)
                .accessibilityIdentifier("browse.address")
            if page.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Go", action: go)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(HostBrowserAddress.url(from: address) == nil || !isReady)
                .accessibilityIdentifier("browse.go")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var isReady: Bool {
        if case .ready = browse.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch browse.state {
        case .idle, .starting:
            VStack(spacing: Theme.Space.md) {
                ProgressView()
                Text("Connecting through \(session.host.name)…")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            notice(icon: "exclamationmark.triangle.fill", tint: Theme.danger,
                   title: "Browsing is not available", message: message) {
                Button("Try Again") { Task { await browse.start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        case .ready:
            if let webView = page.webView {
                HostBrowserWebView(webView: webView)
                    .opacity(page.hasPage ? 1 : 0)
                if !page.hasPage, page.failure == nil, !page.isLoading {
                    notice(icon: "globe", tint: Theme.textMuted,
                           title: "Type an address",
                           message: "Addresses are opened by \(session.host.name), and names are looked up there. A site that only exists on its network works; so do its links, sign-ins and redirects.") {
                        EmptyView()
                    }
                }
                if let failure = page.failure {
                    Theme.bg.opacity(0.94)
                    notice(icon: failure.canVisitAnyway ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill",
                           tint: failure.canVisitAnyway ? Theme.warning : Theme.danger,
                           title: failure.canVisitAnyway ? "This site's certificate is not trusted" : "The page did not load",
                           message: failure.message) {
                        HStack(spacing: Theme.Space.sm) {
                            Button("Try Again") { page.reload() }
                                .buttonStyle(.bordered)
                            if failure.canVisitAnyway {
                                // An explicit choice, for this site and port only, until the browser closes.
                                Button("Visit Anyway", role: .destructive) { page.visitAnyway() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("browse.visit-anyway")
                            }
                        }
                    }
                }
            }
        }
    }

    private func notice<Actions: View>(icon: String, tint: Color, title: String, message: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.title(18))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: 460)
        .padding(Theme.Space.lg)
    }

    private func go() {
        guard isReady, let url = HostBrowserAddress.url(from: address) else { return }
        addressFocused = false
        page.load(url)
    }
}

/// The web view of one browsing session and what the screen shows about it.
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
    private(set) var failure: HostBrowserFailure?

    @ObservationIgnored private var endpoint: HostBrowseModel.Endpoint?
    @ObservationIgnored private var hostName = ""
    @ObservationIgnored private weak var browse: HostBrowseModel?
    @ObservationIgnored private var exceptions = HostBrowseCertificateExceptions()
    @ObservationIgnored private var failedURL: URL?

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
        let reopen = hasPage ? webView?.url : nil
        webView = view
        hasPage = false
        failure = nil
        refresh()
        if let reopen { load(reopen) }
    }

    func load(_ url: URL) {
        failure = nil
        browse?.clearRefusal()
        guard let webView else { return }
        webView.load(URLRequest(url: url))
        // Shown at once: over a slow link the first sign from the page can take a while.
        isLoading = true
    }

    func reload() {
        failure = nil
        browse?.clearRefusal()
        if let failedURL, webView?.url == nil || !hasPage {
            webView?.load(URLRequest(url: failedURL))
        } else {
            webView?.reload()
        }
    }

    func stopLoading() { webView?.stopLoading() }
    func goBack() { failure = nil; webView?.goBack() }
    func goForward() { failure = nil; webView?.goForward() }

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
    }

    private func failed(_ error: Error) {
        let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView?.url
        refresh()
        guard let described = HostBrowserFailure.describe(error, url: url, refusal: browse?.lastRefusal, hostName: hostName) else { return }
        failedURL = url
        failure = described
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
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
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window opens here: there is one page at a time.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private struct HostBrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
