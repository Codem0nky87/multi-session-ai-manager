import SwiftUI

/// The browser of one browser space, sized to its pane: a row of controls and
/// the page. Every request is made by the host (`HostBrowseModel`), so an
/// address is typed as it would be on the host and names are looked up there.
struct HostBrowserPane: View {
    let spaceID: String
    let page: HostBrowserPage
    let forwarding: PortForwardingSession
    let spaces: BrowserSpaceModel

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var browse: HostBrowseModel { forwarding.browse }
    private var hostName: String { forwarding.host.name }

    private var isReady: Bool {
        if case .ready = browse.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().overlay(Theme.hairline)
            ZStack {
                Theme.bg
                content
            }
        }
        .background(Theme.bg)
        .clipped()
        .task { await browse.start() }
        .onChange(of: browse.state, initial: true) { _, state in
            guard case .ready(let endpoint) = state else { return }
            page.attach(to: endpoint, hostID: forwarding.host.id, hostName: hostName, browse: browse)
            // After a reconnect or a relaunch the space is back but its page is not.
            if !page.hasPage, !page.isLoading, page.failure == nil,
               let saved = spaces.savedAddress(for: spaceID), let url = HostBrowserAddress.url(from: saved) {
                page.load(url)
            }
        }
        .onChange(of: page.currentAddress, initial: true) { _, current in
            guard !current.isEmpty else { return }
            // Follow the page, but never overwrite what is being typed.
            if !addressFocused { address = current }
            spaces.remember(address: current, for: spaceID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-space.\(spaceID)")
    }

    private var bar: some View {
        HStack(spacing: Theme.Space.sm) {
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
            .disabled(!page.hasPage && page.failure == nil)
            .accessibilityLabel(page.isLoading ? "Stop" : "Reload")
            Image(systemName: page.currentAddress.hasPrefix("https://") ? "lock.fill" : "globe")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("Address, as seen from \(hostName)", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit(go)
                .accessibilityIdentifier("browser-space.address")
            if page.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .tint(Theme.accent)
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        switch browse.state {
        case .idle, .starting:
            VStack(spacing: Theme.Space.md) {
                ProgressView()
                Text("Connecting through \(hostName)…")
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
                    notice(icon: "globe", tint: Theme.textMuted, title: "Type an address",
                           message: "Addresses are opened by \(hostName), and names are looked up there. A site that only exists on its network works; so do its links, sign-ins and redirects.") {
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
                                // An explicit choice, for this site and port only, until the app is closed.
                                Button("Visit Anyway", role: .destructive) { page.visitAnyway() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("browser-space.visit-anyway")
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
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: 440)
        .padding(Theme.Space.lg)
    }

    private func go() {
        guard isReady, let url = HostBrowserAddress.url(from: address) else { return }
        addressFocused = false
        page.load(url)
    }
}
