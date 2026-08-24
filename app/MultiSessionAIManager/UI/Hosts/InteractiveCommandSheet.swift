import SwiftUI

/// A live terminal running one command on a host, so the user can answer
/// anything it asks — a sudo password above all.
struct InteractiveCommandSheet: View {
    @Bindable var session: InteractiveCommandSession
    let title: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(HerdrTheme.selection)
            TerminalEmulatorView(
                emulator: session.terminal,
                inputEnabled: session.status == .running,
                onInputBytes: { session.terminal.feedInputToPTY($0) },
                onGridChange: { cols, rows in session.resize(cols: cols, rows: rows) },
                forwardsPointerClicks: false,
                // Focus the keyboard here, unlike a Herdr pane: the whole point
                // of this sheet is that the user has something to type.
                automaticallyFocusesInput: true
            )
            .background(Color(session.terminal.colorMap.background))
        }
        .background(HerdrTheme.background)
        .preferredColorScheme(.dark)
        .task { await session.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(HerdrTheme.mono(.footnote, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Button("Done") {
                    Task {
                        await session.stop()
                        onDone()
                    }
                }
                .font(HerdrTheme.mono(.footnote))
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityIdentifier("host.command.done")
            }
            Text(session.command)
                .font(HerdrTheme.mono(.caption))
                .foregroundStyle(HerdrTheme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HerdrTheme.panel)
    }
}
