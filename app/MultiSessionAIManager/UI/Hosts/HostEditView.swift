import SwiftUI

/// Create or edit a `Host`. Pure UI glue over `HostStore` (CRUD) and `KeyStore`
/// (generate / import / export key material). KeyStore calls are synchronous and
/// throwing — wrapped in do/catch and surfaced via an alert.
///
/// Presented in a dark "command-center" layout: a `ScrollView` of `GlassCard`
/// sections over `AppBackground`, with a pinned primary Save action. On a
/// successful save it fires a success toast via the shared `ToastCenter`.
struct HostEditView: View {
    let store: HostStore
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore

    /// nil ⇒ creating a new host; non-nil ⇒ editing the host with this id.
    private let existingID: UUID?

    @State private var name: String
    @State private var address: String
    @State private var port: Int
    @State private var username: String
    @State private var defaultWorkdir: String
    @State private var keyID: String

    @State private var keyIDs: [String] = []

    // Import-key paste sheet.
    @State private var showImportSheet = false
    @State private var pastedPEM = ""

    // Show-public-key sheet.
    @State private var publicKeyText: String?

    // Install-key sheet payload (nil ⇒ closed).
    @State private var installPayload: InstallPayload?

    // Workdir picker sheet payload (nil ⇒ closed).
    @State private var workdirPayload: WorkdirPayload?

    // Error surfacing.
    @State private var errorMessage: String?
    @State private var showHostSetup = false
    @State private var showPortForwarding = false
    /// Set while a key deletion is awaiting confirmation.
    @State private var pendingKeyDeletion: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    /// Pass `host` to edit an existing one; omit for a new host.
    init(
        store: HostStore,
        keyStore: KeyStore,
        knownHosts: KnownHostsStore,
        host: Host? = nil
    ) {
        self.store = store
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        self.existingID = host?.id
        _name = State(initialValue: host?.name ?? "")
        _address = State(initialValue: host?.address ?? "")
        _port = State(initialValue: host?.port ?? 22)
        _username = State(initialValue: host?.username ?? "")
        _defaultWorkdir = State(initialValue: host?.defaultWorkdir ?? "")
        _keyID = State(initialValue: host?.keyID ?? "")
    }

    private var isValid: Bool {
        validationError == nil
    }

    private var validationError: Host.ValidationError? {
        do {
            _ = try candidateHost.validated()
            return nil
        } catch let error as Host.ValidationError {
            return error
        } catch {
            // `validated()` only ever throws `Host.ValidationError`; this arm
            // exists solely because the throw is untyped. Gate Save shut rather
            // than open on an impossible error.
            return .missingName
        }
    }

    /// Label for newly created/imported keys: the host name if given, else "ipad".
    private var keyLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "ipad" : trimmed
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    privateSSHSection
                    authSection
                    workdirSection
                    portForwardingSection
                    validationFeedback
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, 100) // clears the pinned Save bar
            }
            .accessibilityIdentifier("host.editor.form")

            saveBar
        }
        .navigationTitle(existingID == nil ? "Add Host" : "Edit Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.textSecondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHostSetup = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Host Setup")
                .accessibilityIdentifier("host.setup.help")
            }
        }
        .onAppear { refreshKeyIDs() }
        // NOTE: SwiftUI only reliably presents ONE `.sheet` modifier per view —
        // stacking several on the same view makes all but the last flaky/dropped
        // (the install sheet would intermittently fail to present). Each sheet is
        // therefore hung off its OWN zero-size background view so they never
        // contend for the single presentation slot.
        .background(
            Color.clear.sheet(isPresented: $showImportSheet) { importSheet }
        )
        .background(
            Color.clear.sheet(item: Binding(
                get: { publicKeyText.map(IdentifiedText.init) },
                set: { if $0 == nil { publicKeyText = nil } }
            )) { wrapped in
                publicKeySheet(wrapped.text)
            }
        )
        .background(
            Color.clear.sheet(item: $installPayload) { payload in
                InstallKeySheet(
                    host: payload.host,
                    publicKey: payload.publicKey,
                    keyMaterial: payload.keyMaterial,
                    knownHosts: knownHosts,
                    initialUsername: username,
                    onDone: { newUsername in
                        username = newUsername
                        installPayload = nil
                    }
                )
            }
        )
        .background(
            Color.clear.sheet(item: $workdirPayload) { payload in
                WorkdirPickerSheet(
                    host: payload.host,
                    keyMaterial: payload.keyMaterial,
                    knownHosts: knownHosts,
                    startPath: defaultWorkdir,
                    onPick: { picked in
                        defaultWorkdir = picked
                        workdirPayload = nil
                    }
                )
            }
        )
        .background(
            Color.clear.sheet(isPresented: $showHostSetup) {
                HostSetupHelpSheet(host: setupHost, keyStore: keyStore, knownHosts: knownHosts)
            }
        )
        .background(
            Color.clear.sheet(isPresented: $showPortForwarding) {
                if let host = portForwardingHost {
                    HerdrPortForwardingSheet(
                        host: host,
                        keyStore: keyStore,
                        knownHosts: knownHosts
                    )
                    .preferredColorScheme(.dark)
                }
            }
        )
        .background(
            Color.clear.alert(
                SSHKeyDeletion.confirmationTitle,
                isPresented: Binding(
                    get: { pendingKeyDeletion != nil },
                    set: { if !$0 { pendingKeyDeletion = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingKeyDeletion = nil }
                Button("Delete", role: .destructive) { confirmKeyDeletion() }
            } message: {
                Text(SSHKeyDeletion.confirmationMessage)
            }
        )
        .alert(
            "Host Setup Error",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var privateSSHSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "SSH")
                Text("This address and port must be reachable from this iPad — over your VPN, tunnel, or local network.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                DarkField(label: "Name", text: $name,
                          placeholder: "My server", autocapitalize: false,
                          accessibilityID: "host.name")
                DarkField(label: "Address", text: $address,
                          placeholder: "example.com", keyboard: .URL,
                          autocapitalize: false, autocorrect: false,
                          accessibilityID: "host.address")
                DarkField(label: "Port", value: $port,
                          accessibilityID: "host.port")
                DarkField(label: "Username", text: $username,
                          placeholder: "root", autocapitalize: false, autocorrect: false,
                          accessibilityID: "host.username")
            }
        }
    }

    @ViewBuilder
    private var validationFeedback: some View {
        if let validationError {
            Label(validationError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body(13))
                .foregroundStyle(Theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xs)
                .accessibilityIdentifier("host.validation.error")
        }
    }

    @ViewBuilder
    private var authSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Authentication")

                if keyIDs.isEmpty {
                    Text("No keys yet. Generate or import one.")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SSH KEY")
                            .font(Theme.label(12))
                            .foregroundStyle(Theme.textMuted)
                        Picker("Key", selection: $keyID) {
                            Text("None").tag("")
                            ForEach(keyIDs, id: \.self) { id in
                                Text(displayName(for: id)).tag(id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                    }
                }

                VStack(spacing: Theme.Space.sm) {
                    GhostButton(title: "Generate new key", systemImage: "key.fill") {
                        generateKey()
                    }
                    GhostButton(title: "Import key…", systemImage: "square.and.arrow.down") {
                        pastedPEM = ""
                        showImportSheet = true
                    }
                    GhostButton(title: "Show public key", systemImage: "eye") {
                        showPublicKey()
                    }
                    .disabled(keyID.isEmpty)
                    .opacity(keyID.isEmpty ? 0.5 : 1)

                    GhostButton(title: "Delete key…", systemImage: "trash") {
                        requestKeyDeletion()
                    }
                    .disabled(keyID.isEmpty)
                    .opacity(keyID.isEmpty ? 0.5 : 1)
                    .accessibilityIdentifier("host.key.delete")
                }

                NeonButton(title: "Install key on host…",
                           systemImage: "arrow.up.forward.app",
                           enabled: !address.trimmingCharacters(in: .whitespaces).isEmpty) {
                    installKey()
                }
            }
        }
    }

    /// Forward a port on THIS host to the iPad.
    ///
    /// Lives here rather than in app settings because a tunnel is a property of
    /// one host: the ports worth forwarding on a dev box are not the ports worth
    /// forwarding on a build server, and the app-level version had to guess
    /// which host you meant from whichever tab happened to be active.
    ///
    /// Needs a SAVED host with a key: the sheet opens an authenticated SSH
    /// connection, and neither an unsaved draft nor a host without a key can
    /// provide one.
    private var portForwardingSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Port forwarding")
                Text(portForwardingHost == nil
                     ? "Save this host and install a key first — a tunnel runs over an authenticated SSH connection."
                     : "Forward a port on this host to the iPad and open it in the in-app browser.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showPortForwarding = true
                } label: {
                    Label("Manage port forwarding", systemImage: "arrow.left.arrow.right")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(portForwardingHost == nil ? Theme.textMuted : Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(portForwardingHost == nil)
                .accessibilityIdentifier("host.port-forwarding.manage")
            }
        }
    }

    /// The saved host these tunnels belong to, or nil while it cannot support one.
    private var portForwardingHost: Host? {
        let candidate = candidateHost
        guard HostPortForwardingAvailability.isOfferable(
            host: candidate, isSaved: existingID != nil
        ) else { return nil }
        return try? candidate.validated()
    }

    private var workdirSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Working directory")
                HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                    DarkField(label: "Default workdir", text: $defaultWorkdir,
                              placeholder: "~/projects", autocapitalize: false, autocorrect: false)
                    Button {
                        browseWorkdir()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(keyID.isEmpty ? Theme.textMuted : Theme.accent)
                            .frame(width: 48, height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pressable()
                    .disabled(keyID.isEmpty)
                    .accessibilityLabel("Browse for folder")
                }
            }
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        VStack(spacing: 0) {
            Spacer()
            NeonButton(title: "Save host", systemImage: "checkmark", enabled: isValid) {
                save()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .background(
                Theme.bg.opacity(0.92)
                    .blur(radius: 0.5)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    // MARK: - Sheets

    private var importSheet: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Paste an unencrypted OpenSSH ed25519 private key:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                TextEditor(text: $pastedPEM)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .border(.quaternary)
                    .padding()
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(pastedPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func publicKeySheet(_ text: String) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add this line to the host's ~/.ssh/authorized_keys")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .padding()
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { publicKeyText = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    /// Refuses rather than asks when another saved host still depends on the key
    /// -- a confirmation the user cannot evaluate ("does anything use this?") is
    /// not a safeguard.
    private func requestKeyDeletion() {
        let blocking = SSHKeyDeletion.blockingHosts(
            keyID: keyID, hosts: store.hosts, editedHostID: existingID
        )
        guard blocking.isEmpty else {
            errorMessage = SSHKeyDeletion.refusalMessage(for: blocking)
            return
        }
        pendingKeyDeletion = keyID
    }

    private func confirmKeyDeletion() {
        guard let id = pendingKeyDeletion else { return }
        pendingKeyDeletion = nil
        keyStore.delete(id: id)
        // Clear the selection: the editor requires a key to save, so this
        // surfaces as "choose another" rather than a host silently pointing at
        // a key that no longer exists.
        if keyID == id { keyID = "" }
        refreshKeyIDs()
    }

    private func refreshKeyIDs() {
        keyIDs = keyStore.allKeyIDs().sorted()
    }

    private func generateKey() {
        do {
            let id = try keyStore.generateEd25519(label: keyLabel)
            refreshKeyIDs()
            keyID = id
        } catch {
            errorMessage = "Could not generate key: \(error)"
        }
    }

    private func importKey() {
        do {
            let id = try keyStore.importOpenSSHEd25519(pem: pastedPEM, label: keyLabel)
            refreshKeyIDs()
            keyID = id
            showImportSheet = false
        } catch {
            showImportSheet = false
            errorMessage = "Could not import key: \(error)"
        }
    }

    private func showPublicKey() {
        do {
            publicKeyText = try keyStore.openSSHPublicKey(id: keyID)
        } catch {
            errorMessage = "Could not export public key: \(error)"
        }
    }

    /// Build a `Host` from the form's current values (for the install / picker
    /// sheets — only address/port/username matter for connecting).
    private var candidateHost: Host {
        Host(
            id: existingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            keyID: keyID,
            defaultWorkdir: defaultWorkdir
        )
    }

    /// A non-persisting snapshot for Help. Unlike `candidateHost`, it retains
    /// exactly what is currently displayed in the draft fields.
    private var setupHost: Host {
        Host(
            id: existingID ?? UUID(),
            name: name,
            address: address,
            port: port,
            username: username,
            keyID: keyID,
            defaultWorkdir: defaultWorkdir
        )
    }

    private func formHost() -> Host { candidateHost }

    /// Install the selected (or freshly generated) key on the host. Generates a
    /// key first when none is selected, then presents the install sheet.
    private func installKey() {
        if keyID.isEmpty {
            do {
                let id = try keyStore.generateEd25519(label: keyLabel)
                refreshKeyIDs()
                keyID = id
            } catch {
                errorMessage = "Could not generate key: \(error)"
                return
            }
        }
        do {
            let publicKey = try keyStore.openSSHPublicKey(id: keyID)
            let keyMaterial = SSHKeyMaterial(ed25519Seed: try keyStore.ed25519Seed(id: keyID))
            installPayload = InstallPayload(
                host: formHost(),
                publicKey: publicKey,
                keyMaterial: keyMaterial
            )
        } catch {
            errorMessage = "Could not prepare key for install: \(error)"
        }
    }

    /// Present the remote folder picker for the selected key.
    private func browseWorkdir() {
        do {
            let keyMaterial = SSHKeyMaterial(ed25519Seed: try keyStore.ed25519Seed(id: keyID))
            workdirPayload = WorkdirPayload(host: formHost(), keyMaterial: keyMaterial)
        } catch {
            errorMessage = "Could not prepare key for browsing: \(error)"
        }
    }

    private func save() {
        do {
            let host = try candidateHost.validated()
            if existingID == nil {
                store.add(host)
            } else {
                store.update(host)
            }
            toasts.success("Host saved")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Friendly label for a key id (`ed25519-<label>-<uuid>`) — show label + short suffix.
    private func displayName(for id: String) -> String {
        let parts = id.split(separator: "-")
        // ed25519 / label.../ uuid (5 dash-separated groups)
        guard parts.count >= 6 else { return id }
        let label = parts[1...(parts.count - 6)].joined(separator: "-")
        let shortUUID = parts.suffix(1).joined()
        let suffix = String(shortUUID.prefix(6))
        return label.isEmpty ? "\(id.prefix(16))…" : "\(label) (\(suffix))"
    }
}

// MARK: - Dark text field

/// A dark, labelled text field used across the editor sections: a small label
/// above a `Theme.surface` rounded field with an accent focus ring. Supports a
/// text binding or a numeric (Int) binding.
struct DarkField: View {
    let label: String
    var text: Binding<String>?
    var value: Binding<Int>?
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true
    var autocorrect: Bool = true
    /// Optional stable identifier for UI testing (the visible field has no label
    /// text in its accessibility tree, so queries need this).
    var accessibilityID: String?

    @FocusState private var focused: Bool

    /// Text-field initializer.
    init(label: String, text: Binding<String>, placeholder: String = "",
         keyboard: UIKeyboardType = .default,
         autocapitalize: Bool = true, autocorrect: Bool = true,
         accessibilityID: String? = nil) {
        self.label = label
        self.text = text
        self.placeholder = placeholder
        self.keyboard = keyboard
        self.autocapitalize = autocapitalize
        self.autocorrect = autocorrect
        self.accessibilityID = accessibilityID
    }

    /// Numeric (Int) initializer — used for the port.
    init(label: String, value: Binding<Int>, accessibilityID: String? = nil) {
        self.label = label
        self.value = value
        self.keyboard = .numberPad
        self.accessibilityID = accessibilityID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.label(12))
                .foregroundStyle(Theme.textMuted)

            field
                .font(Theme.body(16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                .autocorrectionDisabled(!autocorrect)
                .focused($focused)
                .frame(minHeight: 26)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(focused ? Theme.accent : Theme.hairline,
                                      lineWidth: focused ? 1.5 : 1)
                        // Animate only the border overlay (not the text field
                        // itself). Animating a modifier that wraps the editable
                        // TextField can cause SwiftUI to drop in-flight keystrokes
                        // during the focus transition; scoping the animation to the
                        // overlay keeps the focus ring lively without that risk.
                        .animation(Theme.springSnappy, value: focused)
                )
        }
    }

    @ViewBuilder
    private var field: some View {
        if let text {
            TextField(placeholder, text: text)
                .accessibilityIdentifier(accessibilityID ?? "")
        } else if let value {
            TextField(label, value: value, format: .number)
                .accessibilityIdentifier(accessibilityID ?? "")
        }
    }
}

/// Wraps a String so it can drive a `.sheet(item:)`.
private struct IdentifiedText: Identifiable {
    let text: String
    var id: String { text }
}

/// Drives the install-key `.sheet(item:)`.
private struct InstallPayload: Identifiable {
    let id = UUID()
    let host: Host
    let publicKey: String
    let keyMaterial: SSHKeyMaterial
}

/// Drives the workdir-picker `.sheet(item:)`.
private struct WorkdirPayload: Identifiable {
    let id = UUID()
    let host: Host
    let keyMaterial: SSHKeyMaterial
}
