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
    private var recoverySelectedTabID: UUID?
    private var isRecoveryForeground = false

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
        session.automaticRecoveryEnabled =
            isRecoveryForeground && recoverySelectedTabID == tab.id
        sessions[tab.id] = session
        return session
    }

    /// Applies app lifecycle policy only to sessions that already exist. Stored
    /// tabs remain dormant until the UI selects one and asks for its session.
    func setRecoveryContext(selectedTabID: UUID?, isForeground: Bool) {
        recoverySelectedTabID = selectedTabID
        isRecoveryForeground = isForeground
        for (tabID, session) in sessions {
            session.automaticRecoveryEnabled = isForeground && tabID == selectedTabID
        }
    }

    func closeSession(tabID: UUID) async {
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        await session.stop()
    }

    /// Resolve the selected tab at the instant a key is tapped. Herdr routes
    /// normal keyboard input from this PTY to its currently focused split.
    func sendFunctionKey(_ number: Int) {
        guard let tabID = tabStore.selectedTabID, let session = sessions[tabID],
              session.status == .live, let bytes = TerminalFunctionKey.bytes(for: number) else { return }
        session.terminal.feedInputToPTY(bytes)
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingFileSend = false
    @State private var showingIntelligence = false
    @State private var selectedProviderForDetail: ProviderQuota? = nil
    @State private var showingHardwareMetricsSheet = false
    @State private var showingProviderPulseSheet = false
    @State private var rolloverTargetTerminal: TerminalAgentSession? = nil
    @State private var activeAILoaderState: AILoaderState? = nil
    @State private var activeRolloverTask: Task<Void, Never>? = nil
    /// The downloaded file awaiting the user, if any. Set by the watch pipeline.
    @State private var incomingFile: IncomingFile?
    @State private var isFetchingIncoming = false
    /// The app's only `ToastCenter` injection site. `HostListView`, `HostEditView`,
    /// `InstallKeySheet` and `WorkdirPickerSheet` all read it as a non-optional
    /// `@Environment(ToastCenter.self)`, which traps at runtime if it is absent.
    @State private var toastCenter = ToastCenter()
    /// Phone layout only: how much of the screen the software keyboard covers,
    /// so the quick-key bar can sit above it and the grid can shrink with it.
    @State private var keyboard = KeyboardVisibilityModel()
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
                if selectedTab != nil, !isCompact {
                    if let tab = selectedTab {
                        HostMetricsBarView(metricsModel: tabs.session(for: tab).metrics, hostID: tab.hostID)
                            .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
                        ProviderPulseBarView(pulse: tabs.session(for: tab).metrics.pulse) { provider in
                            selectedProviderForDetail = provider
                        }
                        .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
                    }
                    
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

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingIntelligence.toggle()
                        }
                    } label: {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(showingIntelligence ? HerdrTheme.accent : HerdrTheme.subtext)
                            .frame(
                                width: HerdrChromeMetrics.hostTabBarHeight,
                                height: HerdrChromeMetrics.hostTabBarHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apple Intelligence")
                    .accessibilityIdentifier("msam.intelligence.toggle")
                    .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
                }
                // Phone (compact width): the metrics bar and the five toolbar
                // buttons cannot share 390pt with the tab strip, so every
                // secondary action folds into one overflow menu, alongside 1 hardware
                // icon and 1 AI provider icon.
                if isCompact, let tab = selectedTab {
                    let metrics = tabs.session(for: tab).metrics

                    Button {
                        showingHardwareMetricsSheet = true
                    } label: {
                        Image(systemName: "gauge.with.needle")
                            .foregroundStyle(HerdrTheme.subtext)
                            .frame(width: HerdrChromeMetrics.hostTabBarHeight, height: HerdrChromeMetrics.hostTabBarHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hardware metrics")

                    Button {
                        showingProviderPulseSheet = true
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(metrics.pulse.hasRateLimitedProvider ? HerdrTheme.red : HerdrTheme.accent)
                            if metrics.pulse.hasRateLimitedProvider {
                                Circle()
                                    .fill(HerdrTheme.red)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .frame(width: HerdrChromeMetrics.hostTabBarHeight, height: HerdrChromeMetrics.hostTabBarHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("AI Provider Pulse")

                    Button {
                        showingIntelligence = true
                    } label: {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(showingIntelligence ? HerdrTheme.accent : HerdrTheme.subtext)
                            .frame(width: HerdrChromeMetrics.hostTabBarHeight, height: HerdrChromeMetrics.hostTabBarHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apple Intelligence")
                    .accessibilityIdentifier("msam.compact.intelligence")

                    Menu {
                        Button("Apple Intelligence") { showingIntelligence = true }
                        Button(selection.isSelecting ? "Exit text selection" : "Select text") {
                            if selection.isSelecting { selection.exit() } else { selection.isSelecting = true }
                        }
                        Button("Copy selection") { selection.requestCopy() }
                            .disabled(!selection.hasSelection)
                        Button("Send a file to host") { showingFileSend = true }
                            .disabled(!isSelectedTabLive)
                        Section("Function keys") {
                            ForEach(TerminalFunctionKey.numbers, id: \.self) { number in
                                Button("F\(number)") { tabs.sendFunctionKey(number) }
                                    .disabled(!isSelectedTabLive)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(HerdrTheme.subtext)
                            .frame(
                                width: HerdrChromeMetrics.hostTabBarHeight,
                                height: HerdrChromeMetrics.hostTabBarHeight
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Terminal actions")
                    .accessibilityIdentifier("msam.compact.menu")
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
                HStack(spacing: 0) {
                    HostTerminalView(
                        session: tabs.session(for: tab),
                        selection: selection,
                        theme: tab.themeID.map { TerminalTheme.byID($0) },
                        isCompact: isCompact,
                        keyboard: keyboard
                    )
                    .padding(.horizontal, HerdrChromeMetrics.terminalEdgeInset)
                    // The home-indicator inset is dead space under a terminal --
                    // there is no control down there to keep clear of it, and the
                    // rows it costs are rows of the remote TUI.
                    .ignoresSafeArea(.container, edges: .bottom)
                    .id(tab.id)

                    if showingIntelligence && !isCompact {
                        Divider().background(HerdrTheme.selection)
                        AppleIntelligenceView(
                            activeTerminalText: {
                                tabs.session(for: tab).terminal.visibleText()
                            },
                            onInsertToTerminal: { snippet in
                                tabs.session(for: tab).terminal.feedInputToPTY(Array(snippet.utf8))
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingIntelligence = false
                                }
                            },
                            onApplyAction: { action in
                                try await actionDispatcher.dispatch(action)
                            },
                            runtimeContext: { runtimeContext }
                        )
                        .frame(width: 360)
                        .transition(.move(edge: .trailing))
                    }
                }
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
            updateRecoveryContext()
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
            updateRecoveryContext()
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
            updateRecoveryContext()
            guard phase == .active else { return }
            AppleIntelligenceEngine.shared.checkAvailability()
            guard let tab = selectedTab else { return }
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
        .sheet(item: $selectedProviderForDetail) { provider in
            if let tab = selectedTab {
                let session = tabs.session(for: tab)
                ProviderDetailSheet(
                    provider: provider,
                    terminals: session.metrics.pulse.terminals(for: provider.name),
                    onContinueSession: { term in
                        rolloverTargetTerminal = term
                    }
                )
            }
        }
        .sheet(isPresented: $showingHardwareMetricsSheet) {
            if let tab = selectedTab {
                HardwareMetricsSheet(metrics: tabs.session(for: tab).metrics)
            }
        }
        .sheet(isPresented: $showingProviderPulseSheet) {
            if let tab = selectedTab {
                let session = tabs.session(for: tab)
                NavigationStack {
                    List(session.metrics.pulse.activeProviders) { prov in
                        Button {
                            showingProviderPulseSheet = false
                            selectedProviderForDetail = prov
                        } label: {
                            HStack(spacing: 12) {
                                ProviderIconView(providerName: prov.name, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prov.displayName)
                                        .font(HerdrTheme.mono(.body, weight: .bold))
                                        .foregroundStyle(HerdrTheme.text)
                                    Text("\(Int(prov.usedPercent))% used · \(prov.state)")
                                        .font(HerdrTheme.mono(.caption))
                                        .foregroundStyle(prov.isRateLimited ? HerdrTheme.red : HerdrTheme.subtext)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(HerdrTheme.subtext)
                            }
                        }
                    }
                    .background(HerdrTheme.background)
                    .scrollContentBackground(.hidden)
                    .navigationTitle("AI Provider Pulse")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $rolloverTargetTerminal) { term in
            if let tab = selectedTab {
                let session = tabs.session(for: tab)
                SessionRolloverSheet(
                    terminal: term,
                    availableProviders: session.metrics.pulse.activeProviders,
                    onSelectRollover: { provider, autoApprove, targetTerm in
                        handleSessionRollover(provider: provider, autoApprove: autoApprove, terminal: targetTerm)
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { isCompact && showingIntelligence },
            set: { showingIntelligence = $0 }
        )) {
            if let tab = selectedTab {
                AppleIntelligenceView(
                    activeTerminalText: {
                        tabs.session(for: tab).terminal.visibleText()
                    },
                    onInsertToTerminal: { snippet in
                        tabs.session(for: tab).terminal.feedInputToPTY(Array(snippet.utf8))
                    },
                    onClose: {
                        showingIntelligence = false
                    },
                    onApplyAction: { action in
                        try await actionDispatcher.dispatch(action)
                    },
                    runtimeContext: { runtimeContext }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            } else {
                AppleIntelligenceView(
                    activeTerminalText: { nil },
                    onInsertToTerminal: { _ in },
                    onClose: {
                        showingIntelligence = false
                    },
                    onApplyAction: { action in
                        try await actionDispatcher.dispatch(action)
                    },
                    runtimeContext: { runtimeContext }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .overlay {
            if let loaderState = activeAILoaderState {
                AILoaderModalView(state: loaderState) {
                    activeRolloverTask?.cancel()
                    activeRolloverTask = nil
                    activeAILoaderState = nil
                }
            }
        }
    }

    private func handleSessionRollover(provider: String, autoApprove: Bool, terminal: TerminalAgentSession) {
        guard let selectedTab else { return }
        let session = tabs.session(for: selectedTab)
        guard let service = session.connection.provisioningCommandRunner else {
            toastCenter.error("SSH connection not available to execute rollover")
            return
        }

        activeAILoaderState = AILoaderState(
            provider: provider,
            terminal: terminal,
            statusMessage: "Analyzing previous task on host…",
            detailedMessage: "Evaluating transcript for optimal model and effort"
        )

        activeRolloverTask = Task {
            var model = "gpt-6.1-sol"
            var effort = "high"

            // Phase 1: Background analysis turn on host
            let transcriptPath = terminal.transcriptPath ?? ""
            let analyzeCmd = HerdrSessionRollover.makeAnalysisCommand(transcriptPath: transcriptPath, provider: provider)
            if let output = try? await service.run(analyzeCmd, timeout: .seconds(25), outputLimit: 65536) {
                if let result = HerdrSessionRollover.parseAnalysisResult(json: output.stdoutString) {
                    model = result.model
                    effort = result.effort
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                activeAILoaderState?.statusMessage = "Recommended: \(model) (\(effort) effort)"
                activeAILoaderState?.detailedMessage = "Creating adjacent Herdr tab on host…"
            }

            // Phase 2: Create adjacent tab in Herdr on host
            let workspaceID = HerdrSessionRollover.extractWorkspaceID(from: terminal.tabID)
            let tabLabel = "\(provider.capitalized) - Resume"
            let createCmd = HerdrSessionRollover.makeCreateTabCommand(
                workspaceID: workspaceID,
                cwd: terminal.project,
                label: tabLabel
            )

            var newPaneID: String? = nil
            if let createOutput = try? await service.run(createCmd, timeout: .seconds(10), outputLimit: 16384) {
                if let ids = HerdrSessionRollover.parseCreatedTabResult(json: createOutput.stdoutString) {
                    newPaneID = ids.paneID
                }
            }

            guard !Task.isCancelled else { return }

            // Phase 3: Launch provider agent inside the new Herdr pane on the host
            let launchCmd = HerdrSessionRollover.makeLaunchCommand(
                provider: provider,
                model: model,
                effort: effort,
                autoApprove: autoApprove,
                transcriptPath: terminal.transcriptPath,
                project: terminal.project
            )

            if let targetPane = newPaneID, !targetPane.isEmpty {
                let runCmd = HerdrSessionRollover.makeRunCommand(paneID: targetPane, command: launchCmd)
                _ = try? await service.run(runCmd, timeout: .seconds(10), outputLimit: 1024)
            } else {
                let runCmd = "\(HerdrSessionRollover.pathPrefix); herdr pane run --current \(POSIXShell.quote(launchCmd))"
                _ = try? await service.run(runCmd, timeout: .seconds(10), outputLimit: 1024)
            }

            try? await Task.sleep(nanoseconds: 600_000_000)

            await MainActor.run {
                activeAILoaderState = nil
                activeRolloverTask = nil
                toastCenter.success("Relaunched with \(provider.capitalized) (\(model)) on host")
            }
        }
    }

    func title(for tab: HostTab) -> String {
        HostTabTitle.title(for: tab, hosts: hostStore.hosts)
    }

    var runtimeContext: AppRuntimeContext {
        AppRuntimeContext(
            availableHosts: hostStore.hosts.map(\.name),
            hostTabs: tabStore.tabs.map { title(for: $0) },
            selectedHostTab: selectedTab.map { title(for: $0) },
            activeHostName: selectedHost?.name,
            currentDirectory: selectedTab.flatMap { tabs.session(for: $0).incomingPaths.last }
        )
    }

    var actionDispatcher: AppActionDispatcher {
        AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { [tabStore, tabs] in
                guard let id = tabStore.selectedTabID,
                      let tab = tabStore.tabs.first(where: { $0.id == id }) else {
                    return nil
                }
                return tabs.session(for: tab)
            },
            onOpenSheet: { sheet in
                switch sheet {
                case .metrics: showingHardwareMetricsSheet = true
                case .pulse: showingProviderPulseSheet = true
                case .settings: showingSettings = true
                }
            }
        )
    }

    private var selectedTab: HostTab? {
        guard let id = tabStore.selectedTabID else { return nil }
        return tabStore.tabs.first(where: { $0.id == id })
    }

    /// Phone layout. iPhone (portrait AND landscape) and iPad compact split-view
    /// select the slim top bar with single gauge/sparkles icons and the quick-key
    /// strip; full-screen iPad keeps the expanded metrics bar and toolbar.
    private var isCompact: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
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

    private func updateRecoveryContext() {
        tabs.setRecoveryContext(
            selectedTabID: tabStore.selectedTabID,
            isForeground: scenePhase == .active
        )
    }
}

/// Starts the tab's session and renders its terminal, with a status overlay for
/// every state that is not a live PTY.
struct HostTerminalView: View {
    @Bindable var session: HerdrHostSession
    var selection: TerminalSelectionModel? = nil
    var theme: TerminalTheme? = nil
    /// Phone layout: the terminal gives up rows to a quick-key bar that sits
    /// above the software keyboard, and the keyboard itself shrinks the grid
    /// (fewer rows while typing, full height when dismissed for scrolling).
    var isCompact = false
    /// Owned as @State so observation tracks its notification-driven updates;
    /// the value passed in only seeds a fresh instance (previews).
    @State var keyboard = KeyboardVisibilityModel()

    /// Shared with the emulator view so the quick-key bar can focus/blur the
    /// keyboard and arm sticky Ctrl through the same first responder.
    @State private var inputController = KeyInputController()
    /// Home-indicator inset, measured from the full-screen background below.
    /// The whole view deliberately ignores the bottom safe area (a terminal
    /// wants every row it can get), so the quick-key bar has to lift itself
    /// clear of the swipe-up strip explicitly.
    @State private var homeInset: CGFloat = 0

    /// Space the bar must clear at the bottom: the docked keyboard while it is
    /// up (it covers the home indicator, so the larger figure wins), and the
    /// home-indicator inset when it is down.
    private var barBottomInset: CGFloat {
        return max(homeInset, keyboard.height)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    inputController: inputController,
                    selection: selection,
                    theme: theme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if session.status != .live {
                    HostSessionStatusOverlay(
                        status: session.status,
                        onRetry: { Task { await session.retry() } },
                        onTrustChangedKey: {
                            Task {
                                await session.connection.trustChangedKeyAndReconnect()
                                await session.ensureLive()
                            }
                        }
                    )
                }
            }
            // The quick-key bar shows on iPhone AND iPad: TUIs bind actions to
            // Shift+arrows (Codex queued messages on Shift+Left) and neither
            // the software keyboard nor every hardware case delivers shift to
            // the PTY, so the sticky-Shift strip must always be within reach.
            TerminalQuickKeyBar(
                emulator: session.terminal,
                controller: inputController,
                keyboard: keyboard,
                isLive: session.status == .live,
                onInputBytes: { session.terminal.feedInputToPTY($0) }
            )
            // Lift the bar clear of the keyboard (or the home-indicator
            // strip when the keyboard is hidden); the terminal above it
            // shrinks by the same amount, re-deriving cols/rows.
            .padding(.bottom, barBottomInset)
        }
        .background(
            // Measure the bottom safe-area inset (home indicator) from a layer
            // that spans the full screen, so the quick-key bar can clear it.
            // Preference-based rather than `onGeometryChange`, which is iOS 18+.
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BottomSafeAreaInsetKey.self,
                                value: proxy.safeAreaInsets.bottom)
            }
            .ignoresSafeArea()
        )
        .onPreferenceChange(BottomSafeAreaInsetKey.self) { homeInset = $0 }
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

/// Carries the bottom safe-area inset (home indicator) up from a full-screen
/// background layer to `HostTerminalView`, which needs it to lift the phone
/// quick-key bar clear of the swipe-up strip.
private struct BottomSafeAreaInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
