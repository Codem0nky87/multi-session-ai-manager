import SwiftUI

enum HostTabTitle {
    static func title(for tab: HostTab, hosts: [Host]) -> String {
        guard let host = hosts.first(where: { $0.id == tab.hostID }) else { return "unknown host" }
        guard let session = tab.sessionName, !session.isEmpty else { return host.name }
        return "\(host.name):\(session)"
    }

    /// The tab's name and, when something waits on its host, what: the pill shows
    /// a colour and a number, which mean nothing read aloud.
    static func spoken(for tab: HostTab, hosts: [Host], attention: HostAttention?) -> String {
        let title = title(for: tab, hosts: hosts)
        guard let summary = attention?.spokenSummary else { return title }
        return "\(title), \(summary)"
    }
}

/// The count beside a host's name: red for agents that are blocked, amber for a
/// rate-limited provider, blue for agents that have finished.
struct HostAttentionPillView: View {
    let pill: HostAttentionPill
    /// The selected tab is filled with the accent colour, which is the "finished"
    /// blue; there the pill is drawn dark with coloured digits so it stays visible.
    var onSelectedTab = false

    static func color(for level: HostAttentionLevel) -> Color {
        switch level {
        case .error: HerdrTheme.red
        case .warning: HerdrTheme.yellow
        case .info: HerdrTheme.accent
        }
    }

    var body: some View {
        let color = Self.color(for: pill.level)
        Text(verbatim: pill.count > 99 ? "99+" : "\(pill.count)")
            .font(HerdrTheme.mono(.caption2, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(onSelectedTab ? color : HerdrTheme.background)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(Capsule().fill(onSelectedTab ? HerdrTheme.background : color))
            .accessibilityHidden(true)
    }
}

/// The app's outer tab bar. Tabs are hosts; the remote Herdr renders below it
/// with its own tab row intact.
struct HostTabStrip: View {
    @Bindable var store: HostTabStore
    let hosts: [Host]
    /// What is waiting on each tab's host. Nil (previews, tests) shows no pills.
    var attention: HostAttentionCenter? = nil
    let onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.tabs) { tab in
                    let selected = tab.id == store.selectedTabID
                    let waiting = attention?.attention(for: tab)
                    Button {
                        store.select(tab.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(HostTabTitle.title(for: tab, hosts: hosts))
                            if let pill = waiting?.pill {
                                HostAttentionPillView(pill: pill, onSelectedTab: selected)
                            }
                        }
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
                    .accessibilityLabel(HostTabTitle.spoken(for: tab, hosts: hosts, attention: waiting))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .draggable(tab.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let droppedString = items.first,
                              let sourceID = UUID(uuidString: droppedString),
                              sourceID != tab.id else { return false }
                        withAnimation(Theme.spring) {
                            store.moveTab(id: sourceID, toTargetID: tab.id)
                        }
                        return true
                    }
                    .contextMenu {
                        // What the pill is counting. Choosing a row goes to that host.
                        if let sections = waiting?.menuSections, !sections.isEmpty {
                            ForEach(sections, id: \.title) { section in
                                Section(section.title) {
                                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                        Button(row) { store.select(tab.id) }
                                    }
                                }
                            }
                            Divider()
                        }
                        Menu("Theme") {
                            Button("Default (Global)") {
                                store.setTheme(nil, for: tab.id)
                            }
                            Divider()
                            ForEach(TerminalTheme.all) { theme in
                                Button(theme.name) {
                                    store.setTheme(theme.id, for: tab.id)
                                }
                            }
                        }
                        Divider()
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
