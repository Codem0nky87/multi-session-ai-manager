import Observation
import SwiftUI
import UIKit

/// Owns one live session per open tab. Two tabs on the same host are independent
/// sessions, so a named session never shares a connection with the default one.
@MainActor
@Observable
final class HostTabsModel {
    private let hostStore: HostStore
    private let tabStore: HostTabStore
    private let keyStore: KeyStore
    private let knownHosts: KnownHostsStore
    private let makeTransport: () -> any SSHTransport

    private(set) var sessions: [UUID: HerdrHostSession] = [:]

    init(
        hostStore: HostStore,
        tabStore: HostTabStore,
        keyStore: KeyStore,
        knownHosts: KnownHostsStore,
        makeTransport: @escaping () -> any SSHTransport = { NIOSSHTransport() }
    ) {
        self.hostStore = hostStore
        self.tabStore = tabStore
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        self.makeTransport = makeTransport
    }

    func session(for tab: HostTab) -> HerdrHostSession {
        if let existing = sessions[tab.id] { return existing }
        let host = hostStore.hosts.first(where: { $0.id == tab.hostID }) ?? Host.placeholder
        let session = HerdrHostSession(
            connection: HostConnection(
                host: host,
                keyStore: keyStore,
                knownHosts: knownHosts,
                transport: makeTransport()
            ),
            sessionName: tab.sessionName,
            // The tab's persisted id: stable across relaunches, unique per tab.
            watchIdentity: tab.id.uuidString
        )
        sessions[tab.id] = session
        return session
    }

    func closeSession(tabID: UUID) async {
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        await session.stop()
    }

    /// Retire sessions whose tab is gone, so closing a tab from the strip's
    /// context menu does not leave an SSH channel and its terminal running.
    ///
    /// The live tab set is read from `tabStore` here, at execution time, rather
    /// than captured by the caller when it enqueued its task. Two tab changes in
    /// quick succession enqueue two tasks that can run out of order, and an older
    /// task carrying a stale snapshot would stop a session opened after that
    /// snapshot was taken -- surfacing as a live tab reverting to "Not connected."
    func retireSessions() async {
        for tabID in Array(sessions.keys) {
            guard !tabStore.tabs.contains(where: { $0.id == tabID }) else { continue }
            await closeSession(tabID: tabID)
        }
    }
}

/// The app shell: host tabs on top, the selected tab's remote Herdr terminal
/// below, a host picker behind `+`, and app configuration behind the cog.
struct RootView: View {
    @Bindable var hostStore: HostStore
    @Bindable var tabStore: HostTabStore
    @Bindable var tabs: HostTabsModel
    @Bindable var terminalSettings: TerminalSettings

    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingFileSend = false
    /// The downloaded file awaiting the user, if any. Set by the watch pipeline.
    @State private var incomingFile: IncomingFile?
    @State private var isFetchingIncoming = false
    /// The app's only `ToastCenter` injection site. `HostListView`, `HostEditView`,
    /// `InstallKeySheet` and `WorkdirPickerSheet` all read it as a non-optional
    /// `@Environment(ToastCenter.self)`, which traps at runtime if it is absent.
    @State private var toastCenter = ToastCenter()
    /// True while a pane copy is in flight, so the button cannot be double-fired.
    /// Modal text selection, shared with the terminal so the top bar can enable
    /// Copy only when a range exists, and so a tab switch can force-exit.
    @State private var selection = TerminalSelectionModel()
    private let keyStore = KeyStore(backing: RealKeychain())
    private let knownHosts = KnownHostsStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HostTabStrip(store: tabStore, hosts: hostStore.hosts) { showingPicker = true }
                // Copies the focused Herdr pane's text to the iPad pasteboard.
                // Only shown with a live tab: it asks Herdr over that tab's own
                // authenticated SSH connection.
                if selectedTab != nil {
                    Button {
                        if selection.isSelecting { selection.exit() } else { selection.isSelecting = true }
                    } label: {
                        Image(systemName: selection.isSelecting
                              ? "selection.pin.in.out"
                              : "square.dashed")
                            .foregroundStyle(selection.isSelecting ? HerdrTheme.accent : HerdrTheme.subtext)
                            .frame(
                                width: HerdrChromeMetrics.hostTabBarHeight,
                                height: HerdrChromeMetrics.hostTabBarHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selection.isSelecting ? "Exit text selection" : "Select text")
                    .accessibilityIdentifier("msam.select.text")
                    .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])

                    // Copies the SELECTED text. Inert until a range exists, so the
                    // control states plainly whether tapping it will do anything.
                    Button {
                        selection.requestCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(selection.hasSelection ? HerdrTheme.accent : HerdrTheme.muted)
                            .frame(
                                width: HerdrChromeMetrics.hostTabBarHeight,
                                height: HerdrChromeMetrics.hostTabBarHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!selection.hasSelection)
                    .accessibilityLabel("Copy selected text")
                    .accessibilityIdentifier("msam.copy.selection")
                    .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
                    // Sends a file (clipboard image, photo, or anything from
                    // Files) to the host and types its path into the pane. Live
                    // tabs only: the upload rides that tab's own SSH connection,
                    // and the path is typed into that tab's PTY.
                    Button {
                        showingFileSend = true
                    } label: {
                        Image(systemName: "paperclip")
                            .foregroundStyle(isSelectedTabLive ? HerdrTheme.subtext : HerdrTheme.muted)
                            .frame(
                                width: HerdrChromeMetrics.hostTabBarHeight,
                                height: HerdrChromeMetrics.hostTabBarHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSelectedTabLive)
                    .accessibilityLabel("Send a file to host")
                    .accessibilityIdentifier("msam.send.file")
                    .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(HerdrTheme.subtext)
                        .frame(
                            width: HerdrChromeMetrics.hostTabBarHeight,
                            height: HerdrChromeMetrics.hostTabBarHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("MSAM settings")
                .accessibilityIdentifier("msam.settings")
                .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
            }
            .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])

            if let tab = selectedTab {
                HostTerminalView(
                    session: tabs.session(for: tab),
                    selection: selection
                )
                .padding(.horizontal, HerdrChromeMetrics.terminalEdgeInset)
                // The home-indicator inset is dead space under a terminal --
                // there is no control down there to keep clear of it, and the
                // rows it costs are rows of the remote TUI.
                .ignoresSafeArea(.container, edges: .bottom)
                .id(tab.id)
            } else {
                EmptyHostState { showingPicker = true }
            }
        }
        .background(HerdrTheme.background)
        .environment(terminalSettings)
        .preferredColorScheme(.dark)
        // The status bar is deliberately VISIBLE: its inset is what separates
        // the tab strip from the physical edge, and the clock is wanted. Do not
        // re-add `.statusBarHidden(true)` -- it collapses that inset to zero and
        // the strip goes flush against the bezel again.
        .task {
            tabStore.prune(existingHostIDs: Set(hostStore.hosts.map(\.id)))
        }
        .onChange(of: hostStore.hosts.map(\.id)) { _, ids in
            tabStore.prune(existingHostIDs: Set(ids))
        }
        .onChange(of: tabStore.tabs.map(\.id)) { _, _ in
            Task { await tabs.retireSessions() }
        }
        // Leaving a tab must not strand it in select mode: the terminal would
        // stay unscrollable and deaf to Herdr on a tab the user came back to.
        .onChange(of: tabStore.selectedTabID) { _, _ in
            selection.exit()
        }
        // A path queued by `msam-send` on the host. Downloaded here rather than
        // in the session so the session stays free of UI concerns, and only for
        // the SELECTED tab -- a background tab quietly filling the screen with
        // somebody's file would be a surprise.
        .onChange(of: selectedTabIncomingCount) { _, count in
            guard count > 0, incomingFile == nil, !isFetchingIncoming else { return }
            fetchNextIncoming()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let tab = selectedTab else { return }
            Task { await tabs.session(for: tab).ensureLive() }
        }
        .sheet(isPresented: $showingPicker) {
            HostPickerSheet(hosts: hostStore.hosts) { hostID, sessionName in
                tabStore.open(hostID: hostID, sessionName: sessionName)
                showingPicker = false
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingFileSend) {
            if let tab = selectedTab {
                FileSendSheet(
                    session: tabs.session(for: tab),
                    hostName: selectedHost?.name ?? "host",
                    onFinished: { path in
                        showingFileSend = false
                        toastCenter.success("Uploaded to \(path)")
                    },
                    onCancel: { showingFileSend = false }
                )
            }
        }
        .sheet(item: $incomingFile) { file in
            IncomingFileSheet(file: file) {
                incomingFile = nil
                // Anything queued while this one was open follows immediately.
                fetchNextIncoming()
            }
        }
        .sheet(isPresented: $showingSettings) {
            MSAMSettingsView(
                hostStore: hostStore,
                keyStore: keyStore,
                knownHosts: knownHosts,
                terminalSettings: terminalSettings,
                onDone: { showingSettings = false }
            )
            .environment(toastCenter)
            .toastHost(toastCenter)
        }
    }

    private var selectedTab: HostTab? {
        guard let id = tabStore.selectedTabID else { return nil }
        return tabStore.tabs.first(where: { $0.id == id })
    }

    /// The image button needs a LIVE tab, not merely a selected one: an idle or
    /// failed tab has no authenticated connection to upload over and no PTY to
    /// type the path into.
    private var isSelectedTabLive: Bool {
        guard let tab = selectedTab else { return false }
        return tabs.session(for: tab).status == .live
    }

    private var selectedTabIncomingCount: Int {
        guard let tab = selectedTab else { return 0 }
        return tabs.session(for: tab).incomingPaths.count
    }

    private func fetchNextIncoming() {
        guard let tab = selectedTab, !isFetchingIncoming else { return }
        let session = tabs.session(for: tab)
        guard let path = session.takeNextIncomingPath() else { return }
        isFetchingIncoming = true
        Task {
            do {
                incomingFile = try await session.fetchIncoming(path)
            } catch {
                // The path is already off the queue, so a failure must be said
                // out loud -- otherwise the file the user sent simply never
                // arrives and nothing explains why.
                toastCenter.error(IncomingFileFailure.message(for: error))
            }
            isFetchingIncoming = false
        }
    }

    private var selectedHost: Host? {
        guard let hostID = selectedTab?.hostID else { return nil }
        return hostStore.hosts.first(where: { $0.id == hostID })
    }
}

/// Starts the tab's session and renders its terminal, with a status overlay for
/// every state that is not a live PTY.
struct HostTerminalView: View {
    @Bindable var session: HerdrHostSession
    var selection: TerminalSelectionModel? = nil

    var body: some View {
        ZStack {
            TerminalEmulatorView(
                emulator: session.terminal,
                // Keeps the remote's bottom row out of the window-resize grip,
                // which swallows clicks before the app can forward them.
                bottomInset: HerdrChromeMetrics.resizeGripClearance,
                inputEnabled: session.status == .live,
                onInputBytes: { session.terminal.feedInputToPTY($0) },
                onGridChange: { cols, rows in session.resize(cols: cols, rows: rows) },
                forwardsPointerClicks: true,
                // Remote Herdr panes opt out so launching (or reconnecting) the
                // session never covers its workspace with the software keyboard --
                // and never fires the grid resize/SIGWINCH that raising it implies.
                automaticallyFocusesInput: false,
                selection: selection
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.status != .live {
                HostSessionStatusOverlay(
                    status: session.status,
                    onRetry: { Task { await session.ensureLive() } },
                    onTrustChangedKey: {
                        Task {
                            await session.connection.trustChangedKeyAndReconnect()
                            await session.ensureLive()
                        }
                    }
                )
            }
        }
        // The terminal's OWN background, painted behind everything and allowed
        // past the safe area.
        //
        // A character grid quantises: the row count is floored, so up to one
        // cell height is always left over at the bottom, and the home-indicator
        // strip sits below that. Those points cannot be given to the remote --
        // there is no such thing as a partial row -- so the only way they stop
        // reading as a gap is to be the same colour as what Herdr paints. Taking
        // the colour from the emulator's palette (not the app theme) keeps them
        // matching even when the remote changes theme.
        .background(Color(session.terminal.colorMap.background).ignoresSafeArea())
        .clipped()
        .task { await session.ensureLive() }
    }
}

struct HostSessionStatusOverlay: View {
    let status: HerdrHostSession.Status
    let onRetry: () -> Void
    /// Trusting a changed host key is a security decision, so it is a separate,
    /// explicitly destructive action -- never folded into Retry.
    let onTrustChangedKey: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(HerdrTheme.mono(.footnote))
                .foregroundStyle(HerdrTheme.text)
                .multilineTextAlignment(.center)
            if case .hostKeyChanged = status {
                Button("Trust new key & reconnect", role: .destructive, action: onTrustChangedKey)
                    .font(HerdrTheme.mono(.footnote, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
                    .accessibilityIdentifier("host.session.trustChangedKey")
            } else if showsRetry {
                Button("Retry", action: onRetry)
                    .font(HerdrTheme.mono(.footnote, weight: .semibold))
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.background.opacity(0.92))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host.session.status")
    }

    private var message: String {
        switch status {
        case .idle: "Not connected."
        case .connecting: "Connecting…"
        case .live: ""
        case .herdrMissing: "Herdr is not installed on this host.\nInstall it with: brew install herdr"
        case .hostKeyChanged(let fingerprint):
            """
            SSH host key changed.

            Presented fingerprint
            \(fingerprint)

            Only trust this fingerprint if the host key change was expected. \
            An unexpected change can mean the SSH connection is being intercepted.
            """
        case .failed(let reason): reason
        }
    }

    private var showsRetry: Bool {
        switch status {
        case .idle, .herdrMissing, .failed: true
        case .connecting, .live, .hostKeyChanged: false
        }
    }
}

struct EmptyHostState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No host open")
                .font(HerdrTheme.mono(.body, weight: .semibold))
                .foregroundStyle(HerdrTheme.text)
            Button("Open a host", action: onAdd)
                .font(HerdrTheme.mono(.footnote, weight: .semibold))
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host.empty")
    }
}
