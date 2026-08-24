import SwiftUI

struct HostSetupHelpSheet: View {
    private static let minimumHitTarget: CGFloat = 44

    @State private var model: HostSetupModel
    /// Present only when the caller supplied an SSH connection. Without one the
    /// sheet is pure guidance and the Herdr card is omitted entirely, rather
    /// than shown in a permanently unusable state.
    @State private var installer: HerdrInstaller?
    @Environment(\.dismiss) private var dismiss

    @State private var lifecycle: HerdrSSHConnectionLifecycle?
    /// The Herdr card is inert until the user starts it — see the card body.
    @State private var herdrStarted = false
    @State private var pluginManager: HerdrPluginManagerModel?
    @State private var showingPlugins = false

    /// Pass `keyStore`/`knownHosts` to enable the Herdr install card. Callers
    /// that only want the guidance cards can omit them.
    init(
        host: Host,
        keyStore: KeyStore? = nil,
        knownHosts: KnownHostsStore? = nil,
        transport: (any SSHTransport)? = nil,
        reachability: any TCPReachabilityChecking = TCPReachability()
    ) {
        _model = State(initialValue: HostSetupModel(host: host, reachability: reachability))
        if let keyStore, let knownHosts {
            let connection = HostConnection(
                host: host,
                keyStore: keyStore,
                knownHosts: knownHosts,
                transport: transport ?? NIOSSHTransport()
            )
            let installer = HerdrInstaller(connection: connection)
            _installer = State(initialValue: installer)
            _pluginManager = State(initialValue: HerdrPluginManagerModel(connection: connection))
            _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
                connect: { await connection.connect() },
                disconnect: { await connection.disconnect() }
            ))
        } else {
            _installer = State(initialValue: nil)
            _lifecycle = State(initialValue: nil)
            _pluginManager = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: Theme.Space.lg) {
                        routeCard
                        if let installer { herdrCard(installer) }
                        // Gated on the Herdr card having connected: this card
                        // reuses that connection rather than dialling its own.
                        // Only once Herdr is confirmed present -- `herdr plugin`
                        // is Herdr's own CLI, so there is nothing to talk to
                        // before then.
                        if let pluginManager, isHerdrPresent { pluginsCard(pluginManager) }
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("host.setup.sheet")
            .navigationTitle("Host Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.setup.close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingPlugins) {
            if let pluginManager {
                HerdrPluginManagerSheet(model: pluginManager, hostName: model.host.name)
            }
        }
        .onDisappear {
            model.cancelRouteCheck()
            // Retire the SSH connection with the sheet — leaving it open would
            // leak an authenticated session per visit.
            if let lifecycle {
                Task { await lifecycle.close() }
            }
        }
    }

    private var routeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                setupSectionLabel("1 · Test the private route")
                Text("SSH endpoint: \(model.endpoint.displayName)")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("host.setup.endpoint")

                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.statusTitle)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(model.statusMessage)
                            .font(.system(.subheadline, design: .rounded, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let issueAction = model.issueAction {
                            Text("Next: \(issueAction)")
                                .font(.system(.footnote, design: .rounded, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                primaryActionButton(
                    title: "Test WARP Route",
                    systemImage: "network",
                    isLoading: model.state == .checking,
                    enabled: model.state != .checking
                ) {
                    model.checkRoute()
                }
                .accessibilityIdentifier("host.setup.test.route")

                essentialGuidance("This test opens only a bounded TCP connection. It sends no HTTP, TLS, or SSH application data and cannot prove SSH authentication.")
            }
        }
    }

    /// True once the probe has actually found Herdr on the host.
    private var isHerdrPresent: Bool {
        guard let installer else { return false }
        switch installer.state {
        case .present, .ready: return true
        case .idle, .probing, .absent, .installing, .failed: return false
        }
    }

    /// Browse, install and remove plugins on this host.
    private func pluginsCard(_ model: HerdrPluginManagerModel) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                setupSectionLabel("3 · Plugins")
                Text(pluginSummary(model))
                    .font(.system(.callout, design: .rounded, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                herdrActionButton("Manage plugins", id: "host.setup.plugins.manage") {
                    showingPlugins = true
                }
            }
        }
        // Refreshed the moment the section appears, so the count is current
        // rather than whatever it was when the sheet was last opened.
        .task {
            await model.refresh()
        }
    }

    private func pluginSummary(_ model: HerdrPluginManagerModel) -> String {
        switch model.listState {
        case .idle, .loading:
            return "Reading the plugins installed on this host…"
        case .failed:
            return "Install and remove Herdr plugins on this host."
        case .loaded:
            let count = model.installed.count
            if count == 0 { return "No plugins installed. Browse community plugins and add one." }
            let names = model.installed.prefix(3).map(\.name).joined(separator: ", ")
            return count <= 3
                ? "\(count) installed: \(names)."
                : "\(count) installed: \(names), and \(count - 3) more."
        }
    }

    /// Install/update Herdr on this host over the authenticated SSH connection.
    /// Only rendered when the sheet was given a connection — the host list can
    /// present this sheet purely as guidance, with no SSH session behind it.
    private func herdrCard(_ installer: HerdrInstaller) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                setupSectionLabel("2 · Herdr on this host")
                Text("AI Manager runs Herdr on the host over SSH. Install it here, or update an existing installation.")
                    .font(.system(.callout, design: .rounded, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                herdrConnectionBody(installer)
            }
        }
        // Connects and probes as soon as the sheet opens, rather than behind a
        // "Check this host" tap. That means opening host settings now DIALS the
        // host over SSH -- a deliberate trade for the card being able to say
        // "installed" without being asked, and for the plugin list below it to
        // have something to talk to.
        .task {
            guard !herdrStarted else { return }
            herdrStarted = true
            lifecycle?.connect()
        }
        .task(id: installer.connection.state) {
            if case .connected = installer.connection.state, case .idle = installer.state {
                await installer.probe()
            }
        }
    }

    @ViewBuilder
    private func herdrConnectionBody(_ installer: HerdrInstaller) -> some View {
        Group {
                // The installer needs an authenticated connection, so the
                // connection's own state comes first — otherwise the card would
                // report "authenticate SSH first" while it is mid-handshake.
                switch installer.connection.state {
                case .idle, .connecting:
                    Label("Connecting to this host…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("host.setup.herdr.connecting")
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .regular))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host.setup.herdr.sshfailed")
                case .hostKeyChanged(let fingerprint):
                    Label(
                        "This host's SSH key changed (\(fingerprint)). Resolve it in Port Forwarding before installing Herdr.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.system(.subheadline, design: .rounded, weight: .regular))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("host.setup.herdr.hostkey")
                case .connected:
                    herdrInstallerBody(installer)
                }
        }
    }

    @ViewBuilder
    private func herdrInstallerBody(_ installer: HerdrInstaller) -> some View {
        Group {
                switch installer.state {
                case .idle, .probing:
                    Label("Checking this host…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("host.setup.herdr.probing")

                case .absent(let curlAvailable):
                    Label("Herdr is not installed on this host.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.warning)
                        .accessibilityIdentifier("host.setup.herdr.absent")
                    if curlAvailable {
                        commandRow(
                            title: "Will run on the host",
                            command: HerdrInstaller.installCommand,
                            identifier: "host.setup.herdr.command"
                        )
                        herdrActionButton("Install Herdr", id: "host.setup.herdr.install") {
                            await installer.install()
                        }
                    } else {
                        Label(
                            "This host has no curl, which Herdr's installer needs. Install curl on the host, then try again.",
                            systemImage: "xmark.octagon.fill"
                        )
                        .font(.system(.subheadline, design: .rounded, weight: .regular))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host.setup.herdr.nocurl")
                    }

                case .present(let version):
                    // Nothing to do: state it and stop. An "Install Herdr"
                    // button on a host that already has it is noise the user
                    // has to read past every time.
                    Label("Herdr \(version) installed", systemImage: "checkmark.seal.fill")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.success)
                        .accessibilityIdentifier("host.setup.herdr.present")
                    herdrActionButton("Update to latest", id: "host.setup.herdr.update") {
                        await installer.update()
                    }

                case .installing:
                    Label("Working on the host…", systemImage: "arrow.down.circle")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("host.setup.herdr.installing")

                case .ready(let version):
                    Label("Herdr \(version) is ready.", systemImage: "checkmark.seal.fill")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.success)
                        .accessibilityIdentifier("host.setup.herdr.ready")

                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .regular))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host.setup.herdr.failed")
                    herdrActionButton("Try again", id: "host.setup.herdr.retry") {
                        await installer.probe()
                    }
                }
        }
    }

    private func herdrActionButton(
        _ title: String,
        id: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Self.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.state {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(Theme.textMuted)
        case .checking:
            ProgressView().tint(Theme.accent)
        case .reachable:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
    }

    private func setupButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Self.minimumHitTarget)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text("\(number)")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(.black)
                .padding(6)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(.system(.body, design: .rounded, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commandRow(title: String, command: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(identifier)
                Button {
                    UIPasteboard.general.string = command
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Theme.accent)
                        .frame(
                            minWidth: Self.minimumHitTarget,
                            minHeight: Self.minimumHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(title)")
                .accessibilityIdentifier("\(identifier).copy")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
        }
    }

    private func setupSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .kerning(1.5)
    }

    private func essentialGuidance(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .rounded, weight: .regular))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryActionButton(
        title: String,
        systemImage: String,
        isLoading: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.black).controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(isLoading ? "Working…" : title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Self.minimumHitTarget)
            .padding(.horizontal, 12)
            .foregroundStyle(.black)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.brandGradient)
            )
            .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
            .opacity((enabled && !isLoading) ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isLoading)
    }
}
