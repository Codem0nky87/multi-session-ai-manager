import SwiftUI

/// Collects a username + password and drives `InstallKeyModel` through its three
/// steps (Connect / Install key / Verify), reporting per-step status. The model is
/// built lazily on the first "Install key" tap so it captures the typed username.
///
/// Pure UI glue: no SSH logic lives here beyond assembling the `verify` closure
/// (a key-authenticated `echo` round-trip). The password lives only in `@State`
/// and is never persisted or logged.
struct InstallKeySheet: View {
    let host: Host
    let publicKey: String
    let keyMaterial: SSHKeyMaterial
    let knownHosts: KnownHostsStore
    let initialUsername: String
    /// Called on success with the username that authenticated; the parent writes
    /// it back onto the host and dismisses.
    let onDone: (String) -> Void

    @State private var username: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var model: InstallKeyModel?
    @State private var running = false

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    init(host: Host,
         publicKey: String,
         keyMaterial: SSHKeyMaterial,
         knownHosts: KnownHostsStore,
         initialUsername: String,
         onDone: @escaping (String) -> Void) {
        self.host = host
        self.publicKey = publicKey
        self.keyMaterial = keyMaterial
        self.knownHosts = knownHosts
        self.initialUsername = initialUsername
        self.onDone = onDone
        _username = State(initialValue: initialUsername)
    }

    private var phase: InstallPhase { model?.phase ?? .idle }

    private var canInstall: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !running
    }

    private var isSuccess: Bool { if case .success = phase { return true }; return false }
    private var failedMessage: String? {
        if case .failed(_, let message) = phase { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        explainerCard
                        credentialsCard
                        progressCard

                        if isSuccess {
                            successCard
                        } else if let failedMessage {
                            errorCard(failedMessage)
                        }

                        primaryAction
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Install key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(running)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Cards

    private var explainerCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                Text("Connect once with your password; we'll add this device's key to the host so future logins are passwordless.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var credentialsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Credentials")

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Username")
                        .font(Theme.label(12))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("", text: $username, prompt: Text("username").foregroundColor(Theme.textMuted))
                        .accessibilityIdentifier("install.username")
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .disabled(running)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Password")
                        .font(Theme.label(12))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("", text: $password, prompt: Text("password").foregroundColor(Theme.textMuted))
                                    .accessibilityIdentifier("install.password.visible")
                            } else {
                                SecureField("", text: $password, prompt: Text("password").foregroundColor(Theme.textMuted))
                                    .accessibilityIdentifier("install.password")
                            }
                        }
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .disabled(running)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    .padding(.leading, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
                }
            }
        }
    }

    private var progressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Progress")
                StepRow(title: "Connect", state: stepState(.connect), detail: detail(for: .connect))
                StepRow(title: "Install key", state: stepState(.install), detail: detail(for: .install))
                StepRow(title: "Verify", state: stepState(.verify), detail: detail(for: .verify))
            }
            .animation(Theme.spring, value: phase)
        }
    }

    private var successCard: some View {
        GlassCard {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key installed")
                        .font(Theme.title(16))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Future logins to \(host.name) are passwordless.")
                        .font(Theme.label(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.success.opacity(0.4)))
        .transition(.opacity)
    }

    private func errorCard(_ message: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.danger)
                Text(message)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.danger.opacity(0.4)))
        .transition(.opacity)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isSuccess {
            NeonButton(title: "Done", systemImage: "checkmark") { onDone(username) }
        } else if failedMessage != nil {
            NeonButton(title: "Retry", systemImage: "arrow.clockwise", isLoading: running, enabled: canInstall) { start() }
        } else {
            NeonButton(title: "Install key", systemImage: "key.fill", isLoading: running, enabled: canInstall) { start() }
        }
    }

    // MARK: - Step mapping

    /// Map the model's single `phase` onto a per-step `StepState`.
    private func stepState(_ step: InstallStep) -> StepState {
        switch phase {
        case .idle:
            return .pending
        case .connecting:
            return step == .connect ? .active : .pending
        case .installing:
            switch step {
            case .connect: return .done
            case .install: return .active
            case .verify: return .pending
            }
        case .verifying:
            switch step {
            case .connect, .install: return .done
            case .verify: return .active
            }
        case .success:
            return .done
        case .failed(let failedStep, _):
            if step == failedStep { return .failed }
            return order(step) < order(failedStep) ? .done : .pending
        }
    }

    /// Surface the failure message on the failed step's row.
    private func detail(for step: InstallStep) -> String? {
        if case .failed(let failedStep, let message) = phase, step == failedStep {
            return message
        }
        return nil
    }

    private func order(_ step: InstallStep) -> Int {
        switch step {
        case .connect: return 0
        case .install: return 1
        case .verify: return 2
        }
    }

    // MARK: - Run

    private func start() {
        let typedUsername = username.trimmingCharacters(in: .whitespaces)
        let installer = CitadelKeyInstaller()
        let verify = makeVerify(username: typedUsername)
        let model = InstallKeyModel(
            host: host,
            publicKey: publicKey,
            keyMaterial: keyMaterial,
            knownHosts: knownHosts,
            installer: installer,
            verify: verify
        )
        self.model = model
        let pw = password
        Task {
            running = true
            await model.run(username: typedUsername, password: pw)
            running = false
            switch model.phase {
            case .success:
                toasts.success("Key installed on \(host.name)")
            case .failed(_, let message):
                toasts.error(message)
            default:
                break
            }
        }
    }

    /// Build the verify closure: open a fresh key-authenticated connection and run
    /// `echo msam_key_ok`. The host key was just pinned during install's connect
    /// step, so only a `.match` is accepted here (we do NOT auto-pin). Any throw or
    /// mismatch ⇒ false. Captures only Sendable values.
    private func makeVerify(username: String) -> @Sendable (SSHKeyMaterial) async -> Bool {
        let address = host.address
        let port = host.port
        let knownHostsKey = host.knownHostsKey
        let kh = knownHosts
        return { key in
            let verifyHost = Host(
                name: address,
                address: address,
                port: port,
                username: username,
                keyID: "",
                defaultWorkdir: ""
            )
            let validator: @Sendable (String) -> Bool = { fp in
                kh.verify(host: knownHostsKey, fingerprint: fp) == .match
            }
            let transport = NIOSSHTransport()
            do {
                try await transport.connect(host: verifyHost, key: key, hostKeyValidator: validator)
                let output = try await transport.runCommand("echo msam_key_ok")
                await transport.disconnect()
                return output.contains("msam_key_ok")
            } catch {
                await transport.disconnect()
                return false
            }
        }
    }
}
