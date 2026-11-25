//
//  PhoneChrome.swift
//  MultiSessionAIManager
//
//  What a narrow screen (a phone, an iPad window beside another) has around
//  the terminal in place of the tab strip: one line that says where you are,
//  and a drawer for going somewhere else.
//
//  At this width Herdr draws no sidebar. It lists its spaces behind a small
//  "switch" word, as rows of terminal text a thumb can hardly hit. The drawer
//  lists the same spaces as rows the size of a finger, tells Herdr which one
//  to show, and closes.
//

import SwiftUI

/// The one line above the terminal.
struct PhoneTopBar: View {
    /// The space Herdr is showing, or the host while that is not known.
    let title: String
    let subtitle: String
    /// Spaces whose agent has stopped to ask something.
    let waiting: Int
    let openDrawer: () -> Void
    let openMetrics: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: openDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(HerdrTheme.text)
                    .frame(width: 44, height: HerdrChromeMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hosts and spaces")
            .accessibilityIdentifier("msam.drawer.open")

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(HerdrTheme.subtext)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("msam.phone.title")

            if waiting > 0 {
                Text(verbatim: "\(waiting) waiting")
                    .font(HerdrTheme.mono(.caption2, weight: .bold))
                    .foregroundStyle(HerdrTheme.background)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(HerdrTheme.yellow, in: Capsule())
                    .accessibilityIdentifier("msam.phone.waiting")
            }

            Button(action: openMetrics) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HerdrTheme.subtext)
                    .frame(width: 44, height: HerdrChromeMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hardware metrics")
        }
        .frame(height: HerdrChromeMetrics.minimumHitTarget)
    }
}

/// The drawer: the open hosts, the spaces of the one on screen, and the things
/// that used to be buttons in the top bar. It closes when something is chosen.
struct PhoneDrawer: View {
    struct HostRow: Identifiable {
        let id: UUID
        let title: String
        let isSelected: Bool
        let pill: HostAttentionPill?
    }

    let hosts: [HostRow]
    /// The host on screen, for the heading over its spaces. Empty: none is open.
    let hostName: String
    let spaces: [HerdrSpace]
    /// Why the spaces could not be read, if they could not.
    let spacesFailure: String?
    let providersNeedAttention: Bool

    let selectHost: (UUID) -> Void
    let openAnotherHost: () -> Void
    let showSpace: (HerdrSpace) -> Void
    let newWorkspace: () -> Void
    let newBrowser: () -> Void
    let openSettings: () -> Void
    let openMetrics: () -> Void
    let openProviders: () -> Void
    let close: () -> Void

    static let width: CGFloat = 310

    var body: some View {
        ZStack(alignment: .leading) {
            // Anywhere beside the drawer closes it.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("msam.drawer.close")

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heading("Hosts")
                        ForEach(hosts) { host in
                            row(host.title, selected: host.isSelected, id: "msam.drawer.host.\(host.id.uuidString)") {
                                dot(host.isSelected ? HerdrTheme.green : HerdrTheme.muted)
                            } trailing: {
                                if let pill = host.pill { HostAttentionPillView(pill: pill) }
                            } action: {
                                selectHost(host.id)
                            }
                        }
                        row("Open another host", tint: HerdrTheme.accent, id: "msam.drawer.host.add") {
                            icon("plus")
                        } action: { openAnotherHost() }

                        if !hostName.isEmpty {
                            heading("Spaces on \(hostName)")
                            ForEach(spaces) { space in
                                row(space.name, detail: space.detail, selected: space.isFocused,
                                    id: "msam.drawer.space.\(space.id)") {
                                    dot(Self.color(for: space.status))
                                } action: {
                                    showSpace(space)
                                }
                            }
                            if spaces.isEmpty {
                                Text(spacesFailure ?? "Reading the spaces…")
                                    .font(.footnote)
                                    .foregroundStyle(HerdrTheme.subtext)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .accessibilityIdentifier("msam.drawer.spaces.note")
                            }
                            row("New workspace", tint: HerdrTheme.accent, id: "msam.drawer.space.new") {
                                icon("plus")
                            } action: { newWorkspace() }
                            row("New browser", tint: HerdrTheme.accent, id: "msam.drawer.space.browser") {
                                icon("globe")
                            } action: { newBrowser() }
                        }
                    }
                }
                Divider().overlay(TerminalKeyBarStyle.edge)
                VStack(spacing: 0) {
                    row("Settings", id: "msam.settings") { icon(TerminalKeyBar.settingsSymbol) } action: { openSettings() }
                    if !hostName.isEmpty {
                        row("Host metrics", id: "msam.drawer.metrics") { icon("gauge.with.needle") } action: { openMetrics() }
                        row("AI providers", id: "msam.drawer.providers") {
                            icon("sparkles")
                        } trailing: {
                            if providersNeedAttention { dot(HerdrTheme.red) }
                        } action: { openProviders() }
                    }
                }
            }
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .background(HerdrTheme.panel.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle().fill(TerminalKeyBarStyle.edge).frame(width: 1).ignoresSafeArea()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("msam.drawer")
        }
    }

    static func color(for status: HerdrAgentLifecycle) -> Color {
        switch status {
        case .working: HerdrTheme.green
        case .blocked: HerdrTheme.yellow
        case .error: HerdrTheme.red
        case .done: HerdrTheme.accent
        case .idle, .unknown: HerdrTheme.muted
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(HerdrTheme.subtext)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9).frame(width: 22)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17)).frame(width: 22)
    }

    private func row<Leading: View>(_ title: String, detail: String? = nil, selected: Bool = false,
                                    tint: Color = HerdrTheme.text, id: String,
                                    @ViewBuilder leading: () -> Leading,
                                    action: @escaping () -> Void) -> some View {
        row(title, detail: detail, selected: selected, tint: tint, id: id, leading: leading,
            trailing: { EmptyView() }, action: action)
    }

    private func row<Leading: View, Trailing: View>(_ title: String, detail: String? = nil, selected: Bool = false,
                                                    tint: Color = HerdrTheme.text, id: String,
                                                    @ViewBuilder leading: () -> Leading,
                                                    @ViewBuilder trailing: () -> Trailing,
                                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16)).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(HerdrTheme.subtext).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                trailing()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(selected ? HerdrTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
