import SwiftUI

struct MSAMSettingsView: View {
    let hostStore: HostStore
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore
    @Bindable var terminalSettings: TerminalSettings
    /// The host behind the currently selected tab, so Host Setup and port
    /// forwarding act on the machine the user is actually looking at.
    let onDone: () -> Void

    @State private var showingHosts = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Hosts") {
                    Button {
                        showingHosts = true
                    } label: {
                        settingsRow(
                            "Manage Hosts",
                            detail: hostStore.hosts.isEmpty
                                ? "Add the SSH host that runs Herdr."
                                : "\(hostStore.hosts.count) configured",
                            systemImage: "server.rack"
                        )
                    }
                    .accessibilityIdentifier("settings.hosts.manage")
                }

                TerminalPreferencesSection(settings: terminalSettings)

                Section("About") {
                    LabeledContent("App", value: "MSAM Herdr Client")
                    LabeledContent("Version", value: Self.version)
                    Text("A native iPad client for Herdr over SSH.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("MSAM Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(isPresented: $showingHosts) {
                HostListView(
                    store: hostStore,
                    keyStore: keyStore,
                    knownHosts: knownHosts
                )
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func settingsRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(HerdrTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
