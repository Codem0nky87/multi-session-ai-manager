import SwiftUI

/// The monitor bar's port-forward indicator for one host: a pill with how many
/// forwards are running. Tapping it lists them, each with its local address and
/// its own Stop, above a Stop all.
struct PortForwardsPill: View {
    let session: PortForwardingSession
    /// Whether the list is open. Owned by the bar, like its other details.
    @Binding var isShowingForwards: Bool
    /// Stops every forward of this host and retires its session.
    let stopAll: () async -> Void

    var body: some View {
        let count = session.activeTunnelCount
        Button {
            isShowingForwards = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .bold))
                Text("\(count)")
                    .font(HerdrTheme.mono(.caption, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(HerdrTheme.selection))
            .foregroundStyle(HerdrTheme.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 port forward running. Tap to manage."
                                       : "\(count) port forwards running. Tap to manage.")
        .accessibilityIdentifier("metrics.port-forwards")
        // Below the pill, like the bar's other details. The bar is the top edge of
        // the screen: a list told to open above it is squeezed to a sliver.
        .popover(isPresented: $isShowingForwards, arrowEdge: .top) {
            forwards
                .padding()
                .frame(width: 300)
                .background(HerdrTheme.background)
                .presentationCompactAdaptation(.popover)
        }
        // The pill goes when the last forward stops. Its list must not come back
        // open by itself with the next forward that is started.
        .onDisappear { isShowingForwards = false }
    }

    private var forwards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PORT FORWARDS")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            ForEach(session.model.running) { tunnel in
                HStack(spacing: 8) {
                    switch session.model.status(for: tunnel.id) {
                    case .listening(let port):
                        Label {
                            // Verbatim: a port is a name, not a quantity to group digits in.
                            Text(verbatim: "\(tunnel.label) · 127.0.0.1:\(port)")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(HerdrTheme.green)
                    default:
                        Label {
                            Text(verbatim: "\(tunnel.label) · starting…")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .foregroundStyle(HerdrTheme.subtext)
                    }
                    Spacer(minLength: 4)
                    Button {
                        Task { await session.model.stop(tunnel.id) }
                    } label: {
                        Image(systemName: "stop.circle")
                            .frame(minWidth: 32, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.red)
                    .accessibilityLabel("Stop \(tunnel.label)")
                }
                .font(HerdrTheme.mono(.caption))
                .lineLimit(1)
            }
            Button(role: .destructive) {
                Task { await stopAll() }
            } label: {
                Label("Stop all", systemImage: "stop.circle")
                    .font(HerdrTheme.mono(.subheadline))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HerdrTheme.red)
            .accessibilityIdentifier("metrics.port-forwards.stop-all")
        }
    }
}
