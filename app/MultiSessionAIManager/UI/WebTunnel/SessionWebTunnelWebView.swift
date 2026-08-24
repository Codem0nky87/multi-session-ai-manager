import SwiftUI
import WebKit

/// Dedicated WebView for a single local Session Web Tunnel origin.
///
/// Certificate handling lives only in this coordinator, so no other browser can
/// inherit its loopback-only trust exception.
struct SessionWebTunnelWebView: UIViewRepresentable {
    let loopbackURL: URL
    let onFinish: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            loopbackURL: loopbackURL,
            onFinish: onFinish,
            onFailure: onFailure
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: loopbackURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.onFailure = onFailure
        if webView.url == nil {
            webView.load(URLRequest(url: loopbackURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let loopbackURL: URL
        private let certificatePolicy: TunnelCertificatePolicy
        var onFinish: () -> Void
        var onFailure: (String) -> Void

        init(
            loopbackURL: URL,
            onFinish: @escaping () -> Void,
            onFailure: @escaping (String) -> Void
        ) {
            self.loopbackURL = loopbackURL
            certificatePolicy = TunnelCertificatePolicy(loopbackURL: loopbackURL)
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
        ) {
            let space = challenge.protectionSpace
            let trust = space.serverTrust
            if certificatePolicy.allows(
                authenticationMethod: space.authenticationMethod,
                host: space.host,
                port: space.port,
                hasServerTrust: trust != nil
            ), let trust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let requestURL = navigationAction.request.url,
               sameOrigin(requestURL, loopbackURL) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
                && lhs.host?.lowercased() == rhs.host?.lowercased()
                && effectivePort(lhs) == effectivePort(rhs)
        }

        private func effectivePort(_ url: URL) -> Int {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            onFailure("The tunneled page could not load: \(error.localizedDescription)")
        }
    }
}
