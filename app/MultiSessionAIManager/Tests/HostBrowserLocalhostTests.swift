import Foundation
import Testing
import WebKit
@testable import MultiSessionAIManager

/// `localhost` in a browser space means the host. A web view on an iPad keeps
/// `localhost` to itself (user report with the page's own words, 2026-11-24:
/// "the browser did not ask it for localhost"), so it is given a stand-in
/// address for it, and everything the user reads says `localhost` again.
@Suite(.serialized) @MainActor struct HostBrowserLocalhostTests {
    private final class NoProxy: HostBrowseProxyServing {
        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            throw SSHTransportError.notConnected
        }
    }

    /// One tab with a browser of its own; no page is ever fetched.
    @MainActor private final class Tab {
        let page = HostBrowserPage()
        private let browse = HostBrowseModel(server: NoProxy(), connect: { nil })
        let hostID = UUID()

        init() {
            let endpoint = HostBrowseModel.Endpoint(
                port: 50_981, credentials: HostBrowseProxyCredentials(username: "browser", password: "only-the-browser-knows"))
            page.attach(to: endpoint, hostID: hostID, hostName: "Forge", browse: browse)
        }
    }

    @Test func aPageOnTheHostsOwnLoopbackReadsLocalhost() async throws {
        let hostID: UUID
        do {
            let tab = Tab()
            hostID = tab.hostID
            let view = try #require(tab.page.webView)

            tab.page.load(try #require(HostBrowserAddress.url(from: "https://localhost:8443/app")))
            tab.page.webView(view, didStartProvisionalNavigation: nil)

            #expect(view.url?.host == HostBrowserAddress.hostItself, "The web view is given the stand-in")
            #expect(tab.page.currentAddress == "https://localhost:8443/app")
            tab.page.stopLoading()
        }
        await removeTestBrowserData(of: hostID)
    }

    /// What WebKit asks the page about before it follows a link or a redirect.
    private func asked(_ address: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: address)))
        request.httpMethod = method
        request.setValue("https://qas.internal.example/", forHTTPHeaderField: "Referer")
        return request
    }

    @Test func aPagesOwnLinkToLocalhostIsOpenedThroughTheHost() throws {
        let instead = try #require(HostBrowserPage.replacement(for: try asked("http://localhost:3000/callback?code=1", method: "POST"),
                                                               inMainFrame: true))

        // Not where it says, which would be this device: the same page by the stand-in.
        #expect(instead.url?.absoluteString == "http://192.0.2.1:3000/callback?code=1")
        // And otherwise as it was asked for.
        #expect(instead.httpMethod == "POST")
        #expect(instead.value(forHTTPHeaderField: "Referer") == "https://qas.internal.example/")
    }

    @Test func everyOtherLinkGoesWhereItSays() throws {
        #expect(HostBrowserPage.replacement(for: try asked("https://qas.internal.example/login"), inMainFrame: true) == nil)
        // The stand-in itself is already on its way to the host.
        #expect(HostBrowserPage.replacement(for: try asked("http://192.0.2.1:3000/next"), inMainFrame: true) == nil)
        #expect(HostBrowserPage.replacement(for: try asked("mailto:someone@localhost"), inMainFrame: true) == nil)
        // A frame inside a page cannot be sent elsewhere by loading the whole tab anew.
        #expect(HostBrowserPage.replacement(for: try asked("http://localhost:3000/widget"), inMainFrame: false) == nil)
    }
}

/// With a real web view, through the app's real proxy: `localhost` typed into
/// a browser space is opened on the host, a redirect to `localhost` follows it
/// there, and the address reads `localhost` throughout. Opt-in like
/// `HostBrowserSignInLiveTests`, for the same reason.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MSAM_WEBKIT_IT"] == "1"))
@MainActor struct HostBrowserLocalhostLiveTests {
    private final class NoProxy: HostBrowseProxyServing {
        func start(credentials: HostBrowseProxyCredentials,
                   onRefusal: @escaping @Sendable (HostBrowseRefusal) -> Void) async throws -> any HostBrowseProxyListener {
            throw SSHTransportError.notConnected
        }
    }

    @Test func localhostIsOpenedOnTheHostAndStaysLocalhostToTheUser() async throws {
        // A service on the host that sends whoever arrives on to another of its pages, by its own name.
        let transport = FakeSSHTransport()
        transport.onDirectTCPIPOpened = { _, channel in
            channel.onSend = { [weak channel] data in
                let asksForNext = String(decoding: data, as: UTF8.self).hasPrefix("GET /next")
                let body = "arrived on the host"
                let answer = asksForNext
                    ? "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    : "HTTP/1.1 302 Found\r\nLocation: http://localhost:3000/next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                channel?.emit(Data(answer.utf8))
            }
        }
        let host = Host(name: "Forge", address: "192.0.2.24", port: 22, username: "operator", keyID: "test-key", defaultWorkdir: "/")
        let service = SSHService(host: host, transport: transport,
                                 knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "localhost-live-\(UUID().uuidString)")!))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        let credentials = HostBrowseProxyCredentials(username: "browser", password: "only-the-browser-knows")
        let listener = try await NIOHostBrowseProxyServer(service: service).start(credentials: credentials) { _ in }
        let browse = HostBrowseModel(server: NoProxy(), connect: { nil })
        let hostID = UUID()
        do {
            let page = HostBrowserPage()
            page.attach(to: HostBrowseModel.Endpoint(port: listener.localPort, credentials: credentials), hostID: hostID,
                        hostName: "Forge", browse: browse)

            page.load(try #require(HostBrowserAddress.url(from: "localhost:3000")))

            var shown = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while shown != "arrived on the host", ContinuousClock.now < deadline {
                shown = (try? await page.webView?.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
                try? await Task.sleep(for: .milliseconds(25))
            }
            #expect(shown == "arrived on the host", "failure: \(page.failure?.message ?? "none")")
            #expect(!transport.openedDirectTCPIPTargets.isEmpty)
            #expect(transport.openedDirectTCPIPTargets.allSatisfy { $0 == .init(host: "localhost", port: 3000) },
                    "The host is asked for its own localhost: \(transport.openedDirectTCPIPTargets)")
            #expect(page.webView?.url?.absoluteString == "http://192.0.2.1:3000/next", "The redirect was followed by the stand-in")
            #expect(page.currentAddress == "http://localhost:3000/next")
            page.stopLoading()
        }
        await listener.stop()
        await removeTestBrowserData(of: hostID)
    }
}
