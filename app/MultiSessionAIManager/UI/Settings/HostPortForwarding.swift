import SwiftUI

// Moved verbatim out of the old Herdr gateway settings section: port
// forwarding and the SSH connection lifecycle it shares with Host Setup
// outlive that section, which has since been retired.
//
// The session (connection + tunnel model) is now owned by the app-level
// PortForwardingManager, not this sheet: closing the window leaves a started
// tunnel running until the user stops it explicitly.

@MainActor
struct HerdrPortForwardingSheet: View {
    @State private var session: PortForwardingSession
    @State private var showingChangedKeyConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore,
         session: PortForwardingSession? = nil) {
        let resolved = session
            ?? PortForwardingSession(host: host, keyStore: keyStore, knownHosts: knownHosts,
                                     tunnels: PortForwardingManager.loadTunnels(hostID: host.id))
        resolved.isManaged = true
        _session = State(initialValue: resolved)
    }

    var body: some View {
        ZStack {
            switch session.connection.state {
            case .connected:
                SessionWebTunnelSheet(
                    session: session,
                    onChange: { updated in
                        session.tunnels = updated
                        PortForwardingManager.saveTunnels(updated, hostID: session.host.id)
                    }
                )
            case .idle, .connecting:
                statusScreen(
                    title: "Connecting to SSH host",
                    detail: "Port-forward definitions remain on this iPad and start only over the authenticated host connection.",
                    retry: nil
                )
            case .failed(let message):
                statusScreen(title: "SSH connection failed", detail: message) {
                    Task { await session.connection.connect() }
                }
            case .hostKeyChanged(let fingerprint):
                hostKeyChangedScreen(fingerprint: fingerprint)
            }
        }
        .task {
            session.connect()
        }
        .interactiveDismissDisabled()
        .alert("Trust changed SSH host key?", isPresented: $showingChangedKeyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Trust new key & reconnect", role: .destructive) {
                Task { await session.connection.trustChangedKeyAndReconnect() }
            }
        } message: {
            Text("Only trust this fingerprint if the host key change was expected. An unexpected change can mean the SSH connection is being intercepted.")
        }
    }

    private func statusScreen(
        title: String,
        detail: String,
        retry: (() -> Void)?
    ) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                if case .connecting = session.connection.state {
                    ProgressView()
                } else {
                    Image(systemName: "network")
                        .font(.largeTitle)
                        .foregroundStyle(HerdrTheme.accent)
                }
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .navigationTitle("SSH Web Tunnels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func hostKeyChangedScreen(fingerprint: String) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("SSH host key changed").font(.headline)
                Text("Presented fingerprint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Button("Review and trust new key", role: .destructive) {
                    showingChangedKeyConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("SSH Web Tunnels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
