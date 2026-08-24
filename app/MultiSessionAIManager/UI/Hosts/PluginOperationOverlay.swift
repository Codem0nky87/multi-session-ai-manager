import SwiftUI

/// Modal progress for a long plugin operation.
///
/// Plugin work can take minutes — a source build, a toolchain download — and a
/// row-sized spinner does not carry that: the screen looks idle and the user
/// cannot tell whether anything is happening. This states what is running, and
/// counts, so a slow step reads as slow rather than stuck.
struct PluginOperationOverlay: View {
    let operation: HerdrPluginManagerModel.Operation

    @State private var elapsed: Int = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Dim rather than replace: the list stays visible behind, so the
            // modal reads as "working on this", not as a different screen.
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: Theme.Space.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)

                Text(operation.title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(operation.step)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if operation.isSlow {
                    Text("Building on the host can take several minutes.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Counting is what separates "slow" from "hung" without
                // pretending to know a percentage we cannot measure.
                Text(Self.elapsedLabel(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("host.plugins.progress.elapsed")
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(radius: 24, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host.plugins.progress")
        .onReceive(tick) { _ in elapsed += 1 }
        // Restart the count when the step changes, so "installing cargo" and
        // the retry that follows are timed separately rather than cumulatively.
        .onChange(of: operation.step) { _, _ in elapsed = 0 }
    }

    static func elapsedLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0
            ? String(format: "%d:%02d elapsed", minutes, remainder)
            : "\(remainder)s elapsed"
    }
}
