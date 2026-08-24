import SwiftUI

// MARK: - Primary CTA with built-in loading state

/// A gradient primary button that shows a spinner + label while `isLoading`,
/// disables itself, and gives press-scale feedback. Satisfies `loading-buttons`,
/// `submit-feedback`, `primary-action`.
struct NeonButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    var enabled = true
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.black).controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(isLoading ? "Working…" : title)
                    .font(Theme.title(16))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(role == .destructive ? .white : .black)
            .background {
                if role == .destructive {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.danger)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.brandGradient)
                }
            }
            .shadow(color: (role == .destructive ? Theme.danger : Theme.accent).opacity(0.35), radius: 14, y: 6)
            .opacity((enabled && !isLoading) ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isLoading)
        .pressable()
    }
}

/// Secondary / ghost button.
struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.label(15))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .pressable()
    }
}

// MARK: - Status pill (provider / availability chips, connection state)

struct StatusPill: View {
    enum Kind { case ok, warn, danger, neutral, info }
    let text: String
    var kind: Kind = .neutral
    var systemImage: String? = nil

    private var color: Color {
        switch kind { case .ok: Theme.success; case .warn: Theme.warning
        case .danger: Theme.danger; case .info: Theme.accent; case .neutral: Theme.textSecondary }
    }
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
            Text(text).font(Theme.mono(12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Multi-step progress (connect / install / start-session)

enum StepState: Equatable { case pending, active, done, failed }

struct StepRow: View {
    let title: String
    let state: StepState
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(bg).frame(width: 26, height: 26)
                switch state {
                case .pending: Image(systemName: "circle").foregroundStyle(Theme.textMuted)
                case .active:  ProgressView().controlSize(.small).tint(Theme.accent)
                case .done:    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                case .failed:  Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(15))
                    .foregroundStyle(state == .pending ? Theme.textMuted : Theme.textPrimary)
                if let detail, state == .failed || state == .active {
                    Text(detail).font(Theme.label(12)).foregroundStyle(state == .failed ? Theme.danger : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .animation(Theme.spring, value: state)
    }
    private var bg: Color {
        switch state { case .done: Theme.success; case .failed: Theme.danger
        case .active: Theme.accent.opacity(0.2); case .pending: Theme.surface }
    }
}

// MARK: - Activity overlay (covers content while a long op runs; never "blank")

/// A glassy centered overlay with an animated brand pulse + title/subtitle. Use
/// over any area that would otherwise sit blank during an async wait
/// (connecting, opening terminal, reconnecting). Satisfies `progressive-loading`.
struct ActivityOverlay: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                PulseRing()
                Text(title).font(Theme.title(18)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(Theme.label(14)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
        }
        .transition(.opacity)
    }
}

/// An animated pulsing brand ring used as a lively "working" indicator.
struct PulseRing: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Theme.brandGradient, lineWidth: 3)
                    .frame(width: 54, height: 54)
                    .scaleEffect(animate ? 1.4 : 0.8)
                    .opacity(animate ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(Double(i) * 0.7), value: animate)
            }
            Circle().fill(Theme.brandGradient).frame(width: 30, height: 30)
                .shadow(color: Theme.accent.opacity(0.6), radius: 12)
        }
        .onAppear { animate = true }
    }
}

// MARK: - Section header

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .kerning(1.5)
    }
}
