import SwiftUI

enum HostTabTitle {
    static func title(for tab: HostTab, hosts: [Host]) -> String {
        guard let host = hosts.first(where: { $0.id == tab.hostID }) else { return "unknown host" }
        guard let session = tab.sessionName, !session.isEmpty else { return host.name }
        return "\(host.name):\(session)"
    }
}

/// The app's outer tab bar. Tabs are hosts; the remote Herdr renders below it
/// with its own tab row intact.
struct HostTabStrip: View {
    @Bindable var store: HostTabStore
    let hosts: [Host]
    let onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.tabs) { tab in
                    let selected = tab.id == store.selectedTabID
                    Button {
                        store.select(tab.id)
                    } label: {
                        Text(HostTabTitle.title(for: tab, hosts: hosts))
                            .font(HerdrTheme.mono(.caption2, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? HerdrTheme.background : HerdrTheme.subtext)
                            .padding(.horizontal, 10)
                            .frame(minWidth: HerdrChromeMetrics.hostTabBarHeight * 2,
                                   minHeight: HerdrChromeMetrics.hostTabBarHeight)
                            // `ignoresSafeAreaEdges: []` is load-bearing: a
                            // background ShapeStyle on a view that touches the
                            // safe-area boundary is auto-extended under it, so
                            // the selected tab's accent bled up behind the
                            // status bar and tinted the clock.
                            .background(
                                selected ? HerdrTheme.accent : HerdrTheme.selection,
                                ignoresSafeAreaEdges: []
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("host.tab.\(tab.id.uuidString)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("Close", role: .destructive) { store.close(tab.id) }
                    }
                }

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .foregroundStyle(HerdrTheme.subtext)
                        .frame(width: HerdrChromeMetrics.hostTabBarHeight,
                               height: HerdrChromeMetrics.hostTabBarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New host tab")
                .accessibilityIdentifier("host.tab.add")
            }
        }
        .frame(minHeight: HerdrChromeMetrics.hostTabBarHeight)
        .background(HerdrTheme.panel, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(HerdrTheme.selection).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host.tabstrip")
    }
}
