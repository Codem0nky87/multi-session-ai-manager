import SwiftUI

/// Remote directory picker over `FileBrowserModel`. The user navigates the host's
/// filesystem and taps "Use this folder" to return the current path via `onPick`.
///
/// Pure UI glue: the model is built once in `.task` (the SFTP transfer captures
/// the host + known-hosts store), then the view threads taps through its async
/// navigation methods. This is a *directory* picker — no preview/upload.
struct WorkdirPickerSheet: View {
    let host: Host
    let keyMaterial: SSHKeyMaterial
    let knownHosts: KnownHostsStore
    let startPath: String
    let onPick: (String) -> Void

    @State private var model: FileBrowserModel?
    /// Whether the very first `load()` has returned (so we can show a "Connecting…"
    /// state instead of a blank list while the SFTP session is establishing).
    @State private var firstLoadDone = false

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let model, firstLoadDone {
                    content(model)
                } else {
                    connecting
                }
            }
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model?.showHidden.toggle()
                    } label: {
                        Image(systemName: (model?.showHidden ?? false) ? "eye" : "eye.slash")
                    }
                    .accessibilityLabel("Show hidden folders")
                    .disabled(model == nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if let model { Task { await model.goUp() } }
                    } label: {
                        Label("Up", systemImage: "arrow.up")
                    }
                    .disabled(model?.atRoot ?? true)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if model == nil { model = makeModel() }
            await model?.load()
            withAnimation(Theme.spring) { firstLoadDone = true }
        }
    }

    // MARK: - Connecting (never blank)

    private var connecting: some View {
        VStack(spacing: Theme.Space.md) {
            PulseRing()
            Text("Connecting…")
                .font(Theme.title(16))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: FileBrowserModel) -> some View {
        VStack(spacing: 0) {
            breadcrumbBar(model)

            if let error = model.errorMessage {
                errorCard(error)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.sm)
            }

            directoryList(model)

            footer(model)
        }
    }

    private func directoryList(_ model: FileBrowserModel) -> some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.xs) {
                ForEach(model.visibleEntries, id: \.path) { entry in
                    if entry.isDirectory {
                        Button {
                            Task { await model.open(entry) }
                        } label: {
                            row(name: entry.name, glyph: "folder.fill", glyphColor: Theme.accent, muted: false)
                        }
                        .buttonStyle(.plain)
                        .pressable()
                    } else {
                        row(name: entry.name, glyph: "doc", glyphColor: Theme.textMuted, muted: true)
                            .opacity(0.55)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    private func row(name: String, glyph: String, glyphColor: Color, muted: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: glyph)
                .font(.system(size: 16))
                .foregroundStyle(glyphColor)
                .frame(width: 24)
            Text(name)
                .font(Theme.mono(14))
                .foregroundStyle(muted ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !muted {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(Rectangle())
    }

    private func errorCard(_ message: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.danger)
                Text(message)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.danger.opacity(0.4)))
    }

    private func breadcrumbBar(_ model: FileBrowserModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    let isCurrent = crumb.path == model.currentPath
                    Button {
                        Task { await model.navigate(to: crumb.path) }
                    } label: {
                        Text(crumb.name)
                            .font(Theme.mono(13, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .background(Theme.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func footer(_ model: FileBrowserModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(model.currentPath)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            NeonButton(title: "Use this folder", systemImage: "checkmark") {
                onPick(model.currentPath)
                toasts.success("Workdir set")
                dismiss()
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.bgElevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: - Model

    private func makeModel() -> FileBrowserModel {
        let knownHostsKey = host.knownHostsKey
        let kh = knownHosts
        let transfer = CitadelFileTransfer(
            host: host,
            key: keyMaterial,
            hostKeyValidator: { fp in
                switch kh.verify(host: knownHostsKey, fingerprint: fp) {
                case .match:
                    return true
                case .trustedNew:
                    kh.pin(host: knownHostsKey, fingerprint: fp)
                    return true
                case .mismatch:
                    return false
                }
            }
        )
        return FileBrowserModel(transfer: transfer, root: startPath.isEmpty ? "/" : startPath)
    }
}
