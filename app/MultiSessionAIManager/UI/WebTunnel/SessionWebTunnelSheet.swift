import SwiftUI
import UIKit

/// One host's port forwards: the saved connections, each with a Start button, and
/// above them the ones that are running, each with its local address, the two
/// browser shortcuts and a Stop button.
struct SessionWebTunnelSheet: View {
    /// The app-owned session: closing this sheet stops nothing and keeps the SSH
    /// connection — the user stops forwards explicitly.
    let session: PortForwardingSession
    let onChange: ([SessionWebTunnel]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var tunnels: [SessionWebTunnel] {
        get { session.tunnels }
        nonmutating set { session.tunnels = newValue }
    }
    private var model: SessionWebTunnelModel { session.model }
    private var hopPasswords: [UUID: String] {
        get { session.hopPasswords }
        nonmutating set { session.hopPasswords = newValue }
    }
    @State private var editorRequest: TunnelEditorRequest?
    @State private var browserRequest: TunnelBrowserRequest?
    @State private var passwordPrompt: TunnelPasswordPrompt?
    /// The running forward whose address was just copied.
    @State private var copiedTunnelID: UUID?
    /// The running forward being asked whether it speaks TLS, for a browser shortcut.
    @State private var openingTunnelID: UUID?

    init(
        session: PortForwardingSession,
        onChange: @escaping ([SessionWebTunnel]) -> Void
    ) {
        self.session = session
        self.onChange = onChange
    }

    var body: some View {
        NavigationStack {
            List {
                runningSection
                connectionsSection

                Section {
                    Button {
                        editorRequest = TunnelEditorRequest(tunnel: nil)
                    } label: {
                        Label("Add Port Forward", systemImage: "plus")
                    }
                    .accessibilityIdentifier("tunnel.add")
                } footer: {
                    Text("Each forward listens only on 127.0.0.1 of this device. In App and Safari open http or https, whichever the service itself answers in; an HTTPS certificate exception applies only to that forward's own local address.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Port Forwarding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing the window leaves started forwards running; the
                    // monitor bar shows them and the host editor can stop them.
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editorRequest) { request in
                SessionWebTunnelEditorSheet(
                    tunnel: request.tunnel,
                    hopPassword: request.tunnel.flatMap {
                        hopPasswords[$0.id]
                    } ?? "",
                    onDelete: request.tunnel.map { editing in
                        { delete(id: editing.id) }
                    }
                ) { saved, hopPassword in
                    save(saved, hopPassword: hopPassword)
                }
                .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $browserRequest) { request in
                SessionWebTunnelBrowserScreen(tunnel: request.tunnel, address: request.address)
                    .preferredColorScheme(.dark)
            }
            .sheet(item: $passwordPrompt) { prompt in
                TunnelPasswordEntrySheet(tunnel: prompt.tunnel) { password in
                    // An empty answer is a choice too ("use the host's own key"),
                    // remembered so the next start does not ask again.
                    hopPasswords[prompt.tunnel.id] = password
                    Task { await start(prompt.tunnel) }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var runningSection: some View {
        if !model.running.isEmpty {
            Section {
                ForEach(model.running) { tunnel in
                    runningRow(tunnel)
                }
            } header: {
                Text("Running (\(model.runningCount) of \(SessionWebTunnelModel.runningLimit))")
            } footer: {
                Text("Keep AI Manager on screen while a forward is in use. iOS may suspend it in the background; come back here if a connection stalls.")
            }
        }
    }

    private func runningRow(_ tunnel: SessionWebTunnel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tunnel.label)
                    .font(Theme.label(15))
                Spacer()
                Button(role: .destructive) {
                    Task { await model.stop(tunnel.id) }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tunnel.stop")
            }
            switch model.status(for: tunnel.id) {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Starting…")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tunnel.status")
            case .listening(let port):
                listening(tunnel, port: port)
            case .idle, .failed:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func listening(_ tunnel: SessionWebTunnel, port: Int) -> some View {
        let address = "127.0.0.1:\(port)"
        let copied = copiedTunnelID == tunnel.id
        Button {
            UIPasteboard.general.string = address
            copiedTunnelID = tunnel.id
        } label: {
            Label {
                Text(verbatim: copied ? "Copied \(address)" : "Listening on \(address)")
            } icon: {
                Image(systemName: copied ? "checkmark" : "network")
            }
                .font(Theme.mono(13))
                .foregroundStyle(Theme.success)
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Copies the address")
        .accessibilityIdentifier("tunnel.status")

        Text(verbatim: "to \(tunnel.targetAddress)" + (tunnel.hop.map { " via \($0.username)@\($0.host)" } ?? ""))
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)

        if let problem = model.connectionProblem(for: tunnel.id) {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body(12))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tunnel.problem")
        }

        HStack(spacing: 10) {
            Button {
                open(tunnel) { browserRequest = TunnelBrowserRequest(tunnel: tunnel, address: $0) }
            } label: {
                Label("In App", systemImage: "rectangle.inset.filled")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("tunnel.open.inapp")
            Button {
                open(tunnel) { openURL($0.localhostURL) }
            } label: {
                Label("Safari", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("tunnel.open.external")
            if openingTunnelID == tunnel.id {
                ProgressView()
            }
        }
        .disabled(openingTunnelID != nil)
    }

    // MARK: - Connections

    @ViewBuilder
    private var connectionsSection: some View {
        if tunnels.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "network")
                } description: {
                    Text("Add any TCP service reachable from this SSH host: a web page, RDP, VNC, a database. The app serves it on a local port of this device, even when the device cannot route to the target itself.")
                }
            }
        } else {
            Section {
                ForEach(tunnels) { tunnel in
                    connectionRow(tunnel)
                }
                .onDelete(perform: delete)
            } header: {
                Text("Connections")
            } footer: {
                if !model.canStartAnother {
                    Text("\(SessionWebTunnelModel.runningLimit) forwards are running, the most that can run at once. Stop one to start another.")
                }
            }
        }
    }

    private func connectionRow(_ tunnel: SessionWebTunnel) -> some View {
        let status = model.status(for: tunnel.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tunnel.label)
                        .font(Theme.label(15))
                    Text(verbatim: tunnel.targetAddress)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: routeSummary(for: tunnel))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Edit") {
                    editorRequest = TunnelEditorRequest(tunnel: tunnel)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tunnel.edit.\(tunnel.id.uuidString)")
                switch status {
                case .connecting, .listening:
                    Label("Running", systemImage: "checkmark.circle.fill")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.success)
                        .accessibilityIdentifier("tunnel.running")
                case .idle, .failed:
                    Button {
                        Task { await start(tunnel) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!model.canStartAnother)
                    .accessibilityIdentifier("tunnel.start")
                }
            }
            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tunnel.failure")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func save(_ tunnel: SessionWebTunnel, hopPassword: String) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            if tunnels[index] != tunnel {
                // A running forward keeps the settings it was started with, so a
                // changed one is stopped: the next Start uses what was saved.
                Task { await model.stop(tunnel.id) }
            }
            tunnels[index] = tunnel
        } else {
            tunnels.append(tunnel)
        }
        if tunnel.hop != nil, !hopPassword.isEmpty {
            hopPasswords[tunnel.id] = hopPassword
        } else {
            hopPasswords.removeValue(forKey: tunnel.id)
        }
        persist()
    }

    private func delete(at offsets: IndexSet) {
        let deletedIDs = offsets.map { tunnels[$0].id }
        tunnels.remove(atOffsets: offsets)
        for id in deletedIDs {
            forget(id)
        }
        persist()
    }

    private func delete(id: UUID) {
        tunnels.removeAll { $0.id == id }
        forget(id)
        persist()
    }

    /// A deleted forward must not keep listening, or keep its hop password.
    private func forget(_ id: UUID) {
        hopPasswords.removeValue(forKey: id)
        Task { await model.stop(id) }
    }

    private func persist() {
        onChange(tunnels)
    }

    private func routeSummary(for tunnel: SessionWebTunnel) -> String {
        let local = tunnel.localPort.map { "local port \($0)" } ?? "automatic local port"
        guard let hop = tunnel.hop else {
            return "\(local) • direct from SSH host"
        }
        return "\(local) • via \(hop.username)@\(hop.host):\(hop.port)"
    }

    /// Finds out whether the forward carries http or https, then hands its address on.
    private func open(_ tunnel: SessionWebTunnel, _ present: @escaping (TunnelWebAddress) -> Void) {
        guard openingTunnelID == nil else { return }
        openingTunnelID = tunnel.id
        Task {
            defer { openingTunnelID = nil }
            guard let address = await model.webAddress(for: tunnel.id) else { return }
            present(address)
        }
    }

    private func start(_ tunnel: SessionWebTunnel) async {
        // A hop password is never saved, so after a relaunch a hop forward has
        // none. Ask once whether to type one or to rely on the first host's own
        // key; starting without asking would silently fail a password hop.
        guard tunnel.hop == nil || hopPasswords[tunnel.id] != nil else {
            passwordPrompt = TunnelPasswordPrompt(tunnel: tunnel)
            return
        }
        let hopPassword = hopPasswords[tunnel.id].flatMap { $0.isEmpty ? nil : $0 }

        // The forward runs over the session's SSH connection. The settings
        // screen connects it on appear; the host-detail entry point does not,
        // so ensure it here rather than failing with a bare "not connected".
        if case .connected = session.connection.state {
            // already connected
        } else {
            await session.connection.connect()
        }
        // A concurrent connect (metrics bar, sheet re-entry) can supersede the
        // one above; give the session's connection a moment to settle.
        for _ in 0..<60 {
            switch session.connection.state {
            case .connected, .failed, .hostKeyChanged:
                break
            default:
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            break
        }
        await model.start(tunnel, hopPassword: hopPassword)
    }
}

private struct TunnelEditorRequest: Identifiable {
    let id = UUID()
    let tunnel: SessionWebTunnel?
}

private struct TunnelBrowserRequest: Identifiable {
    let id = UUID()
    let tunnel: SessionWebTunnel
    let address: TunnelWebAddress
}

private struct TunnelPasswordPrompt: Identifiable {
    let id = UUID()
    let tunnel: SessionWebTunnel
}

/// Shown when a hop forward is started and the session holds no answer for it
/// yet (first start, or after an app relaunch): type the hop's password, or start
/// without one and let the first host's own key, SSH config or agent log in.
/// Either answer goes straight back into the session and is not asked for again
/// while the app runs.
private struct TunnelPasswordEntrySheet: View {
    let tunnel: SessionWebTunnel
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("SSH password for \(tunnel.hop?.username ?? "the hop")@"
                        + "\(tunnel.hop?.host ?? "")", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                } header: {
                    Text("Hop password")
                } footer: {
                    Text("A password is kept only in memory while AI Manager runs, so it is asked for again after a relaunch.")
                }
                Section {
                    Button("Start without a password") {
                        onSubmit("")
                        dismiss()
                    }
                    .accessibilityIdentifier("tunnel.password.none")
                } footer: {
                    Text("Uses the key, SSH config or agent that the connected first host already has for this hop.")
                }
            }
            .navigationTitle(tunnel.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onSubmit(password)
                        dismiss()
                    }
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("tunnel.password.start")
                }
            }
        }
    }
}

private struct SessionWebTunnelEditorSheet: View {
    let originalID: UUID
    let onSave: (SessionWebTunnel, String) -> Void
    /// Present only when editing an existing tunnel: swipe-to-delete is easy to
    /// miss on a phone row crowded with action buttons, so the editor carries an
    /// explicit Delete command as well.
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var targetHost: String
    @State private var targetPort: String
    @State private var localPortMode: SessionWebTunnelLocalPortMode
    @State private var fixedLocalPort: String
    @State private var hopEnabled: Bool
    @State private var hopUsername: String
    @State private var hopHost: String
    @State private var hopPort: String
    @State private var hopPassword: String
    @State private var showsHopPassword = false

    init(
        tunnel: SessionWebTunnel?,
        hopPassword: String,
        onDelete: (() -> Void)? = nil,
        onSave: @escaping (SessionWebTunnel, String) -> Void
    ) {
        // A new forward starts with an empty port: there is no protocol to
        // guess a default from, and a wrong prefilled number is easy to miss.
        let isNew = tunnel == nil
        let tunnel = tunnel ?? SessionWebTunnel(label: "", targetHost: "", targetPort: 0)
        originalID = tunnel.id
        self.onDelete = onDelete
        self.onSave = onSave
        _label = State(initialValue: tunnel.label)
        _targetHost = State(initialValue: tunnel.targetHost)
        _targetPort = State(initialValue: isNew ? "" : String(tunnel.targetPort))
        _localPortMode = State(
            initialValue: tunnel.localPort == nil ? .automatic : .fixed
        )
        _fixedLocalPort = State(
            initialValue: tunnel.localPort.map(String.init) ?? ""
        )
        _hopEnabled = State(initialValue: tunnel.hop != nil)
        _hopUsername = State(initialValue: tunnel.hop?.username ?? "")
        _hopHost = State(initialValue: tunnel.hop?.host ?? "")
        _hopPort = State(initialValue: String(tunnel.hop?.port ?? 22))
        _hopPassword = State(initialValue: hopPassword)
    }

    private var definition: SessionWebTunnel {
        SessionWebTunnel(
            id: originalID,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            targetHost: targetHost.trimmingCharacters(in: .whitespacesAndNewlines),
            targetPort: Int(targetPort) ?? 0,
            localPort: localPortMode == .automatic
                ? nil
                : Int(fixedLocalPort) ?? 0,
            hop: hopEnabled
                ? SessionWebTunnelHop(
                    username: hopUsername.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    host: hopHost.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: Int(hopPort) ?? 0
                )
                : nil
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Label", text: $label)
                        .accessibilityIdentifier("tunnel.field.label")
                }
                Section {
                    TextField("Host or IP", text: $targetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("tunnel.field.targetHost")
                    TextField("Port", text: $targetPort)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("tunnel.field.targetPort")
                } header: {
                    Text("Remote target")
                } footer: {
                    Text("Where the service listens, as seen from the SSH host, or from the hop when one is set below. Any TCP service can be forwarded.")
                }
                Section {
                    Picker("Local port mode", selection: $localPortMode) {
                        Text("Automatic").tag(SessionWebTunnelLocalPortMode.automatic)
                        Text("Fixed").tag(SessionWebTunnelLocalPortMode.fixed)
                    }
                    .pickerStyle(.segmented)
                    if localPortMode == .fixed {
                        TextField("Fixed local port", text: $fixedLocalPort)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("Local listener")
                } footer: {
                    Text(
                        "The listener is always bound only to 127.0.0.1. Choose "
                        + "Fixed for an address that stays the same, such as one "
                        + "saved in an RDP or VNC client."
                    )
                }
                Section {
                    Toggle("Use SSH hop", isOn: $hopEnabled)
                        .accessibilityIdentifier("tunnel.field.hopEnabled")
                    if hopEnabled {
                        TextField("SSH username", text: $hopUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("tunnel.field.hopUsername")
                        TextField("SSH host or IP", text: $hopHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("tunnel.field.hopHost")
                        TextField("SSH port", text: $hopPort)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("tunnel.field.hopPort")
                        HStack {
                            Group {
                                if showsHopPassword {
                                    TextField("SSH password for this hop", text: $hopPassword)
                                } else {
                                    SecureField(
                                        "SSH password for this hop",
                                        text: $hopPassword
                                    )
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .accessibilityIdentifier("tunnel.field.hopPassword")

                            Button {
                                showsHopPassword.toggle()
                            } label: {
                                Image(
                                    systemName: showsHopPassword
                                        ? "eye.slash"
                                        : "eye"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tunnel.field.hopPasswordReveal")
                            .accessibilityLabel(
                                showsHopPassword ? "Hide SSH password" : "Show SSH password"
                            )
                        }
                    }
                } header: {
                    Text("Optional SSH hop")
                } footer: {
                    Text(SessionWebTunnel.hopCredentialExplanation)
                }
                if let error = definition.validationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("Port Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(definition, hopEnabled ? hopPassword : "")
                        dismiss()
                    }
                    .disabled(definition.validationError != nil)
                    .accessibilityIdentifier("tunnel.save")
                }
                if onDelete != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) {
                            onDelete?()
                            dismiss()
                        }
                        .accessibilityIdentifier("tunnel.delete")
                    }
                }
            }
        }
    }
}

/// The in-app browser for one running forward. It only looks at the forward:
/// closing it stops nothing, and a page that will not load is the page's problem,
/// shown here, not a failure of the forward.
private struct SessionWebTunnelBrowserScreen: View {
    let tunnel: SessionWebTunnel
    let address: TunnelWebAddress

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedLocalhostURL = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SessionWebTunnelWebView(
                    loopbackURL: address.loopbackURL,
                    onFinish: { failure = nil },
                    onFailure: { failure = $0 }
                )
                if let failure {
                    failureOverlay(failure)
                }
            }
            .navigationTitle(tunnel.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(tunnel.label)
                            .font(.headline)
                        Text(verbatim: "\(tunnel.targetAddress) via SSH")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = address.localhostURL.absoluteString
                        copiedLocalhostURL = true
                    } label: {
                        Label(
                            copiedLocalhostURL ? "Copied" : "Copy URL",
                            systemImage: copiedLocalhostURL
                                ? "checkmark"
                                : "doc.on.doc"
                        )
                    }
                    Button {
                        openURL(address.localhostURL)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                }
            }
        }
    }

    private func failureOverlay(_ message: String) -> some View {
        ZStack {
            Theme.bg.opacity(0.9)
            GlassCard(fillsWidth: false) {
                VStack(spacing: Theme.Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.danger)
                    Text("The page did not load")
                        .font(Theme.title(18))
                    Text(message)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("The forward is still running. If this port is not a web page, use its address in the app that speaks its protocol.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
            .frame(maxWidth: 440)
            .padding(Theme.Space.lg)
        }
    }
}
