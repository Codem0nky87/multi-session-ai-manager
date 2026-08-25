import SwiftUI

/// Per-host plugin manager: what is installed, and what can be added.
struct HerdrPluginManagerSheet: View {
    @Bindable var model: HerdrPluginManagerModel
    let hostName: String

    @State private var query = ""
    @State private var manualSource = ""
    @State private var manualRef = ""
    @State private var showingManual = false
    /// A live terminal for a command that may prompt — a sudo password above
    /// all, which an exec channel can never answer.
    @State private var interactive: InteractiveCommandSession?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: Theme.Space.lg) {
                        messages
                        herdrCard
                        installedCard
                        catalogueCard
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay {
                if let operation = model.operation {
                    PluginOperationOverlay(operation: operation)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: model.operation)
            // Nothing behind the modal is safe to touch mid-install, and a
            // swipe-to-dismiss would leave the operation running unseen.
            .interactiveDismissDisabled(model.operation != nil)
            .navigationTitle("Plugins on \(hostName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.plugins.close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.refresh()
            if case .idle = model.catalogueState { await model.search("") }
        }
        .sheet(item: Binding(
            get: { interactive.map { InteractiveCommandBox(session: $0) } },
            set: { if $0 == nil { interactive = nil } }
        )) { box in
            InteractiveCommandSheet(
                session: box.session,
                title: "Run on \(hostName)"
            ) {
                interactive = nil
                // Whatever the user did in there may have changed the host.
                Task { await model.refresh() }
            }
        }
    }

    // MARK: - Messages

    @ViewBuilder private var messages: some View {
        if let error = model.errorMessage {
            noticeRow(error, icon: "exclamationmark.triangle.fill", tint: Theme.danger)
                .accessibilityIdentifier("host.plugins.error")
        }
        if let pending = model.missingToolchain {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Button {
                    Task { await model.installMissingToolchainAndRetry() }
                } label: {
                    Label("Install \(pending.tool.rawValue) on this host and retry",
                          systemImage: "arrow.down.circle")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("host.plugins.install-toolchain")

                // Answered before the button is pressed: "let an app install a
                // compiler on my server" deserves to know whether that means root.
                Label(BuildToolchainInstaller.privilegeNotice, systemImage: "lock.open")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("host.plugins.toolchain-privilege")

                if !model.manualSteps.isEmpty {
                    Text("Or run these on the host yourself:")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 2)
                    ForEach(model.manualSteps, id: \.self) { step in
                        Text(step)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("host.plugins.toolchain-manual")

                    // The escape hatch for anything that PROMPTS. An exec
                    // channel has no terminal on stdin, so a sudo password can
                    // never be answered there; a PTY can.
                    Button {
                        interactive = InteractiveCommandSession(
                            connection: model.connection,
                            command: model.manualSteps
                                .filter { !$0.hasPrefix("#") }
                                .joined(separator: " && ")
                        )
                    } label: {
                        Label("Run it in a terminal (for a sudo password)",
                              systemImage: "terminal")
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("host.plugins.toolchain-terminal")
                }
            }
        }
        if let notice = model.noticeMessage {
            noticeRow(notice, icon: "checkmark.circle.fill", tint: Theme.success)
                .accessibilityIdentifier("host.plugins.notice")
        }
    }

    private func noticeRow(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Installed

    /// Herdr's own version and update state, mirroring the "update ready"
    /// entry in its session menu. Hidden until a status probe answers — the
    /// sheet is about plugins first.
    @ViewBuilder private var herdrCard: some View {
        if let status = model.updateStatus {
            GlassCard {
                HStack(spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.sm) {
                            SectionLabel(text: "Herdr")
                            Text(status.serverVersion ?? status.clientVersion)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                            if status.updateReady {
                                Text("Update ready")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.warning.opacity(0.15)))
                            }
                        }
                        if status.updateReady {
                            Text("A newer Herdr is installed than the server is running.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Theme.Space.sm)
                    if model.busyIdentifier == "herdr.update" {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Button {
                            Task { await model.updateHerdr() }
                        } label: {
                            Text(status.updateReady ? "Apply update" : "Update Herdr")
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(status.updateReady ? Theme.warning : Theme.accent)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("host.plugins.herdrupdate")
                    }
                }
            }
        }
    }

    private var installedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    SectionLabel(text: "Installed")
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh installed plugins")
                    .accessibilityIdentifier("host.plugins.refresh")
                }

                switch model.listState {
                case .idle, .loading:
                    ProgressView("Reading plugins…")
                        .font(.system(.subheadline, design: .rounded))
                        .tint(Theme.accent)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                case .loaded:
                    if model.installed.isEmpty {
                        Text("No plugins installed on this host.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(model.installed) { plugin in
                            installedRow(plugin)
                            if plugin.id != model.installed.last?.id {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func installedRow(_ plugin: InstalledPlugin) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if !plugin.version.isEmpty {
                        Text(plugin.version)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Theme.textMuted)
                    }
                    if !plugin.enabled {
                        Text("disabled")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let origin = plugin.originRepository {
                    Text(origin)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if model.busyIdentifier == plugin.pluginID {
                ProgressView().tint(Theme.accent)
            } else {
                // Only the file viewer can be wired for host -> iPad sending, so
                // the action lives on its row rather than as a separate card.
                // A plugin that ships a keybinding installer (like Ferry's
                // "Install Ferry keybinding") gets it as a button: on a
                // touch-only iPad the keybinding is how the plugin is opened,
                // since no touch gesture produces the right-click that raises
                // Herdr's pane menu.
                ForEach(plugin.keybindingInstallers, id: \.id) { action in
                    Button {
                        Task { await model.installKeybinding(action, for: plugin) }
                    } label: {
                        Text(action.title)
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("host.plugins.keybinding.\(plugin.pluginID).\(action.id)")
                }
                if model.isFileViewer(plugin) {
                    Button {
                        Task { await model.configureFileTransfer(for: plugin) }
                    } label: {
                        Text("Send files here")
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("host.plugins.filetransfer")
                }
                Button(role: .destructive) {
                    Task { await model.uninstall(plugin) }
                } label: {
                    Text("Uninstall")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("host.plugins.uninstall.\(plugin.pluginID)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Catalogue

    private var catalogueCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Add a plugin")

                HStack(spacing: Theme.Space.sm) {
                    DarkField(label: "Search", text: $query,
                              placeholder: "file viewer", autocapitalize: false,
                              autocorrect: false, accessibilityID: "host.plugins.search")
                    Button {
                        Task { await model.search(query) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 48, height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .fill(Theme.surface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search plugins")
                }

                // Said plainly: the topic is self-applied, so the list is not a
                // vetted catalogue and some entries are not plugins at all.
                Text("Community plugins tagged herdr-plugin on GitHub. The tag is self-applied — a listing is not a review.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                switch model.catalogueState {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView("Searching…")
                        .font(.system(.subheadline, design: .rounded))
                        .tint(Theme.accent)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                case .loaded:
                    if model.results.isEmpty {
                        Text("No matching plugins.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(model.results) { plugin in
                            catalogueRow(plugin)
                            if plugin.id != model.results.last?.id {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                }

                Divider().overlay(Theme.hairline)
                manualInstall
            }
        }
    }

    private func catalogueRow(_ plugin: CataloguePlugin) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.repositoryName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(plugin.owner)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                    Label("\(plugin.stars)", systemImage: "star.fill")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if model.busyIdentifier == plugin.fullName {
                ProgressView().tint(Theme.accent)
            } else if model.isInstalled(plugin.fullName) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .labelStyle(.titleAndIcon)
            } else {
                Button {
                    Task { await model.verifyThenInstall(plugin) }
                } label: {
                    Text("Install")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("host.plugins.install.\(plugin.fullName)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var manualInstall: some View {
        DisclosureGroup(isExpanded: $showingManual) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                DarkField(label: "owner/repo", text: $manualSource,
                          placeholder: "smarzban/herdr-file-viewer",
                          autocapitalize: false, autocorrect: false,
                          accessibilityID: "host.plugins.manual.source")
                DarkField(label: "Ref (optional)", text: $manualRef,
                          placeholder: "v1.0.0", autocapitalize: false, autocorrect: false,
                          accessibilityID: "host.plugins.manual.ref")
                Button {
                    Task {
                        await model.install(
                            source: manualSource,
                            ref: manualRef.isEmpty ? nil : manualRef
                        )
                    }
                } label: {
                    Text("Install")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(manualSource.isEmpty ? Theme.textMuted : Theme.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(manualSource.isEmpty || model.isBusy)
                .accessibilityIdentifier("host.plugins.manual.install")
            }
            .padding(.top, Theme.Space.xs)
        } label: {
            Text("Install from a repository")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .tint(Theme.accent)
    }
}


/// `sheet(item:)` needs Identifiable; the session is a reference type driving
/// the sheet's content, so it is boxed rather than made Identifiable itself.
private struct InteractiveCommandBox: Identifiable {
    let session: InteractiveCommandSession
    var id: String { session.command }
}
