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
        BrowserSpacePaneLayout(regions: forwarding == nil ? [] : spaces.regions, cell: cell) { region in
            if let forwarding {
                HostBrowserPane(spaceID: region.id, tabs: spaces.tabs(for: region.id),
                                forwarding: forwarding, spaces: spaces)
            }
        }
        // Not in `body`: making the session changes the manager, which a view
        // being drawn must not do.
        .task(id: current) { forwarding = portForwarding?.session(for: host) }
    }
}

/// Each pane over the cells of its region, without any say in how large the
/// terminal under it is.
///
/// A pane is as large as the host last drew it. When the terminal has just
/// become shorter (the keyboard came up) the pane is still the old height, and
/// a pane that took part in the layout held the terminal's height up: the
/// terminal could then only shrink a few rows for every redraw from the host,
/// and Herdr laid the whole screen out again for each of them. So the panes are
/// drawn over a base that takes exactly the space it is given, and cut off at
/// its edges.
struct BrowserSpacePaneLayout<Pane: View>: View {
    let regions: [BrowserSpaceRegion]
    let cell: CGSize
    @ViewBuilder let pane: (BrowserSpaceRegion) -> Pane

    var body: some View {
        Color.clear
            // Outside the panes every touch belongs to the terminal underneath.
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(regions) { region in
                        let frame = BrowserSpaceGeometry.frame(of: region, cell: cell)
                        pane(region)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .clipped()
    }
}
