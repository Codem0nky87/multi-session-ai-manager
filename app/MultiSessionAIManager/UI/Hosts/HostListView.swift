import SwiftUI

/// Settings screen for the private SSH hosts used to install, repair, and forward
/// Herdr. Runtime workspaces, tabs, and panes are presented only by Herdr's native
/// shell; tapping a host edits that host's connection metadata.
struct HostListView: View {
    @State private var store: HostStore
    private let keyStore: KeyStore
    private let knownHosts: KnownHostsStore

    /// Drives the add/edit sheet. nil ⇒ closed.
    @State private var editTarget: EditTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    init(store: HostStore, keyStore: KeyStore, knownHosts: KnownHostsStore) {
        _store = State(initialValue: store)
        self.keyStore = keyStore
        self.knownHosts = knownHosts
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if store.hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .overlay(alignment: .bottom) { buildBadge }
            .navigationTitle("Hosts")
            // Inline (not the default large) title: inside a `.sheet` the large title
            // does a large→inline collapse on present that reads as the header
            // "flashing then disappearing" — at sheet width the collapsed title ends
            // up clipped above the sheet's rounded top and never settles back. Pinning
            // it inline keeps the "Hosts" header stable from the first frame.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        editTarget = .new
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Add Host")
                }
            }
            .sheet(item: $editTarget) { target in
                NavigationStack {
                    HostEditView(
                        store: store,
                        keyStore: keyStore,
                        knownHosts: knownHosts,
                        host: target.host
                    )
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Build stamp

    /// Tiny version + build-time label so it's unambiguous WHICH build is running
    /// (the binary's modification time changes on every compile, even when the
    /// CFBundleVersion doesn't — e.g. local sim builds).
    private var buildBadge: some View {
        Text(Self.buildStamp)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textMuted)
            .padding(.bottom, 4)
    }

    /// Format: `v<version>.<yy>.<MMddHHmmss>` from the binary's build time, e.g.
    /// `v1.0.26.0621090914` (year 26, built Jun 21 09:09:14). The date suffix
    /// changes on every compile, so it's an unambiguous "which build is running"
    /// marker.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        var suffix = info?["CFBundleVersion"] as? String ?? "?"
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let date = attrs[.modificationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yy.MMddHHmmss"
            suffix = fmt.string(from: date)
        }
        return "v\(version).\(suffix)"
    }()

    // MARK: - List

    private var hostList: some View {
        // A `List` (not `ScrollView`/`LazyVStack`) so `.swipeActions` actually
        // work — they're inert outside a `List`. `.scrollContentBackground(.hidden)`
        // + clear row backgrounds let the dark `AppBackground` show through while
        // the cards keep their look.
        List {
            ForEach(store.hosts) { host in
                Button {
                    editTarget = .edit(host)
                } label: {
                    row(host)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .swipeActions(edge: .leading) {
                    Button {
                        editTarget = .edit(host)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Theme.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        remove(host)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        editTarget = .edit(host)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        remove(host)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Theme.spring, value: store.hosts)
    }

    private func row(_ host: Host) -> some View {
        GlassCard {
            HStack(spacing: Theme.Space.md) {
                serverGlyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name)
                        .font(Theme.title())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Private SSH · \(host.username)@\(host.address):\(host.port)")
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.sm)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var serverGlyph: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
            )
            .frame(width: 44, height: 44)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "server.rack")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Theme.brandGradient)
                .shadow(color: Theme.accent.opacity(0.4), radius: 18)
                .padding(.bottom, Theme.Space.xs)

            Text("No hosts yet")
                .font(Theme.title(22))
                .foregroundStyle(Theme.textPrimary)

            Text("Add an SSH host to start a remote session.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            NeonButton(title: "Add a host", systemImage: "plus") {
                editTarget = .new
            }
            .frame(maxWidth: 280)
            .padding(.top, Theme.Space.sm)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 420)
    }

    // MARK: - Mutations

    private func remove(_ host: Host) {
        withAnimation(Theme.spring) {
            store.remove(host)
        }
        toasts.success("Host removed")
    }
}

/// Identifies the add/edit sheet target. `.new` ⇒ create; `.edit` ⇒ edit a host.
private enum EditTarget: Identifiable {
    case new
    case edit(Host)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let host): return host.id.uuidString
        }
    }

    var host: Host? {
        switch self {
        case .new: return nil
        case .edit(let host): return host
        }
    }
}

#Preview {
    let keyStore = KeyStore(backing: InMemoryKeychain())
    let knownHosts = KnownHostsStore()
    return HostListView(store: HostStore(),
                        keyStore: keyStore,
                        knownHosts: knownHosts)
        .environment(ToastCenter())
}
