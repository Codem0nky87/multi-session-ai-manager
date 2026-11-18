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
