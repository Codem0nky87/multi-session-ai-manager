import SwiftUI
import UIKit

func prepareHopPasswordForTunnelStart(
    passwords: inout [UUID: String],
    previousTunnelID: UUID?,
    nextTunnelID: UUID
) -> String? {
    let nextPassword = passwords[nextTunnelID]
    if let previousTunnelID, previousTunnelID != nextTunnelID {
        passwords.removeValue(forKey: previousTunnelID)
    }
    return nextPassword
}

struct SessionWebTunnelSheet: View {
    let connection: HostConnection
    let onChange: ([SessionWebTunnel]) -> Void
    let onClose: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var tunnels: [SessionWebTunnel]
    @State private var model: SessionWebTunnelModel
    @State private var editorRequest: TunnelEditorRequest?
    @State private var browserRequest: TunnelBrowserRequest?
    @State private var copiedLocalhostURL = false
    @State private var hopPasswords: [UUID: String] = [:]

    init(
        initialTunnels: [SessionWebTunnel],
        connection: HostConnection,
        onClose: @escaping @MainActor () async -> Void = {},
        onChange: @escaping ([SessionWebTunnel]) -> Void
    ) {
        self.connection = connection
        self.onClose = onClose
        self.onChange = onChange
        _tunnels = State(initialValue: initialTunnels)
        _model = State(initialValue: SessionWebTunnelModel(
            server: connection.makeSessionWebTunnelServer()
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                if tunnels.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Web Tunnels", systemImage: "network")
                        } description: {
                            Text("Add any HTTP/HTTPS service reachable from this SSH host. The app opens it through a direct SSH tunnel, even when the iPad cannot route to the target IP itself.")
                        }
                    }
                } else {
                    Section("Configured") {
                        ForEach(tunnels) { tunnel in
                            tunnelRow(tunnel)
                        }
                        .onDelete(perform: delete)
                    }
                }

                Section {
                    Button {
                        editorRequest = TunnelEditorRequest(tunnel: nil)
                    } label: {
                        Label("Add SSH Web Tunnel", systemImage: "plus")
                    }
                } header: {
                    Text("New SSH tunnel")
                } footer: {
                    Text("Configure any HTTP/HTTPS target reachable from the connected SSH host. The listener binds only to 127.0.0.1, and HTTPS certificate exceptions apply only to the exact local tunnel WebView origin.")
                }

                statusSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("SSH Web Tunnels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Task {
                            await model.stop()
                            await onClose()
                            hopPasswords.removeAll()
                            dismiss()
                        }
                    }
                }
            }
            .sheet(item: $editorRequest) { request in
                SessionWebTunnelEditorSheet(
                    tunnel: request.tunnel,
                    hopPassword: request.tunnel.flatMap {
                        hopPasswords[$0.id]
                    } ?? ""
                ) { saved, hopPassword in
                    save(saved, hopPassword: hopPassword)
                }
                .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $browserRequest) { request in
                SessionWebTunnelBrowserScreen(
                    tunnel: request.tunnel,
                    loopbackURL: request.loopbackURL,
                    localhostURL: request.localhostURL,
                    model: model,
                    onStop: stopActiveTunnelAndForgetPassword
                )
                .preferredColorScheme(.dark)
            }
        }
        .onDisappear {
            guard editorRequest == nil, browserRequest == nil else { return }
            hopPasswords.removeAll()
            Task { await model.stop() }
        }
    }

    private func tunnelRow(_ tunnel: SessionWebTunnel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tunnel.label)
                        .font(Theme.label(15))
                    Text("\(tunnel.scheme.rawValue)://\(tunnel.targetHost):\(tunnel.targetPort)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(routeSummary(for: tunnel))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Edit") {
                    editorRequest = TunnelEditorRequest(tunnel: tunnel)
                }
                .buttonStyle(.borderless)
                Button {
                    openInApp(tunnel)
                } label: {
                    Label("In App", systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.bordered)
                .disabled(model.status == .connecting)
                Button {
                    openInSafari(tunnel)
                } label: {
                    Label("Safari", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.status == .connecting)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch model.status {
            case .idle:
                Label("Not running", systemImage: "circle")
                    .foregroundStyle(Theme.textSecondary)
            case .connecting:
                HStack {
                    ProgressView()
                    Text("Starting loopback tunnel…")
                }
            case .listening(let port):
                Label("Listening on 127.0.0.1:\(port)", systemImage: "network")
                    .foregroundStyle(Theme.warning)
            case .open(let port):
                Label("Open on 127.0.0.1:\(port)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            case .failed(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(Theme.danger)
            }

            if let localhostURL = model.localhostURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Safari URL")
                        .font(Theme.label(13))
                    Text(localhostURL.absoluteString)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                Button {
                    openURL(localhostURL)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.string = localhostURL.absoluteString
                    copiedLocalhostURL = true
                } label: {
                    Label(
                        copiedLocalhostURL ? "Copied localhost URL" : "Copy localhost URL",
                        systemImage: copiedLocalhostURL ? "checkmark" : "doc.on.doc"
                    )
                }
                Button(role: .destructive) {
                    Task { await stopActiveTunnelAndForgetPassword() }
                } label: {
                    Label("Stop Tunnel", systemImage: "stop.circle")
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(
                "Keep AI Manager running while you use Safari. iPadOS may suspend "
                + "the tunnel in the background; return to AI Manager and refresh "
                + "Safari if the page stops loading."
            )
        }
    }

    private func save(_ tunnel: SessionWebTunnel, hopPassword: String) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
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
            hopPasswords.removeValue(forKey: id)
        }
        persist()
    }

    private func persist() {
        onChange(tunnels)
    }

    private func routeSummary(for tunnel: SessionWebTunnel) -> String {
        let local = tunnel.localPort.map { "localhost:\($0)" } ?? "automatic local port"
        guard let hop = tunnel.hop else {
            return "\(local) • direct from SSH host"
        }
        return "\(local) • via \(hop.username)@\(hop.host):\(hop.port)"
    }

    private func openInApp(_ tunnel: SessionWebTunnel) {
        Task {
            await start(tunnel)
            if let loopbackURL = model.loopbackURL,
               let localhostURL = model.localhostURL {
                browserRequest = TunnelBrowserRequest(
                    tunnel: tunnel,
                    loopbackURL: loopbackURL,
                    localhostURL: localhostURL
                )
            }
        }
    }

    private func openInSafari(_ tunnel: SessionWebTunnel) {
        Task {
            await start(tunnel)
            if let localhostURL = model.localhostURL {
                openURL(localhostURL)
            }
        }
    }

    private func start(_ tunnel: SessionWebTunnel) async {
        let previousTunnelID = model.activeTunnel?.id
        let hopPassword = prepareHopPasswordForTunnelStart(
            passwords: &hopPasswords,
            previousTunnelID: previousTunnelID,
            nextTunnelID: tunnel.id
        )
        await model.start(
            tunnel,
            hopPassword: hopPassword
        )
    }

    private func stopActiveTunnelAndForgetPassword() async {
        let tunnelID = model.activeTunnel?.id
        await model.stop()
        if let tunnelID {
            hopPasswords.removeValue(forKey: tunnelID)
        }
    }
}

private struct TunnelEditorRequest: Identifiable {
    let id = UUID()
    let tunnel: SessionWebTunnel?
}

private struct TunnelBrowserRequest: Identifiable {
    let id = UUID()
    let tunnel: SessionWebTunnel
    let loopbackURL: URL
    let localhostURL: URL
}

private struct SessionWebTunnelEditorSheet: View {
    let originalID: UUID
    let onSave: (SessionWebTunnel, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var scheme: SessionWebTunnelScheme
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
        onSave: @escaping (SessionWebTunnel, String) -> Void
    ) {
        let tunnel = tunnel ?? SessionWebTunnel(
            label: "",
            scheme: .https,
            targetHost: "",
            targetPort: 443
        )
        originalID = tunnel.id
        self.onSave = onSave
        _label = State(initialValue: tunnel.label)
        _scheme = State(initialValue: tunnel.scheme)
        _targetHost = State(initialValue: tunnel.targetHost)
        _targetPort = State(initialValue: String(tunnel.targetPort))
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
            scheme: scheme,
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
                }
                Section("Remote target") {
                    Picker("Scheme", selection: $scheme) {
                        ForEach(SessionWebTunnelScheme.allCases) { scheme in
                            Text(scheme.rawValue.uppercased()).tag(scheme)
                        }
                    }
                    TextField("Host or IP", text: $targetHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $targetPort)
                        .keyboardType(.numberPad)
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
                        + "Fixed for a stable Safari localhost address."
                    )
                }
                Section {
                    Toggle("Use SSH hop", isOn: $hopEnabled)
                    if hopEnabled {
                        TextField("SSH username", text: $hopUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSH host or IP", text: $hopHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSH port", text: $hopPort)
                            .keyboardType(.numberPad)
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
            .navigationTitle("Web Tunnel")
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
                }
            }
        }
    }
}

private struct SessionWebTunnelBrowserScreen: View {
    let tunnel: SessionWebTunnel
    let loopbackURL: URL
    let localhostURL: URL
    @Bindable var model: SessionWebTunnelModel
    let onStop: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedLocalhostURL = false

    var body: some View {
        NavigationStack {
            ZStack {
                SessionWebTunnelWebView(
                    loopbackURL: loopbackURL,
                    onFinish: { model.webViewDidFinish() },
                    onFailure: { model.webViewDidFail($0) }
                )
                if case .connecting = model.status {
                    loadingOverlay
                }
                if case .failed(let message) = model.status {
                    failureOverlay(message)
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
                        Text("\(tunnel.targetHost):\(tunnel.targetPort) via SSH")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = localhostURL.absoluteString
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
                        openURL(localhostURL)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                    }
                }
            }
        }
        .onDisappear {
            Task { await onStop() }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Theme.bg.opacity(0.82)
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening SSH tunnel…")
                    .font(Theme.label(15))
            }
        }
    }

    private func failureOverlay(_ message: String) -> some View {
        ZStack {
            Theme.bg.opacity(0.9)
            GlassCard {
                VStack(spacing: Theme.Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.danger)
                    Text("Tunnel failed")
                        .font(Theme.title(18))
                    Text(message)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
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
