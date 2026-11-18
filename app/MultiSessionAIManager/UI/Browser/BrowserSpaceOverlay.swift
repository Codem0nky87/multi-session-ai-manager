import SwiftUI

/// The browser panes of a host tab, each over the cells of its space's pane.
/// Touches inside a pane go to its browser; everywhere else they reach the
/// terminal underneath.
struct BrowserSpaceOverlay: View {
    let spaces: BrowserSpaceModel
    let host: Host
    /// The size of one terminal cell.
    let cell: CGSize

    @Environment(\.portForwardingManager) private var portForwarding
    @State private var forwarding: PortForwardingSession?

    /// The host's forwarding session can be shut down and made again ("Stop all").
    private var current: ObjectIdentifier? {
        portForwarding?.sessions[host.id].map(ObjectIdentifier.init)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let forwarding {
                ForEach(spaces.regions) { region in
                    let frame = BrowserSpaceGeometry.frame(of: region, cell: cell)
                    HostBrowserPane(spaceID: region.id, page: spaces.page(for: region.id),
                                    forwarding: forwarding, spaces: spaces)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Not in `body`: making the session changes the manager, which a view
        // being drawn must not do.
        .task(id: current) { forwarding = portForwarding?.session(for: host) }
    }
}
