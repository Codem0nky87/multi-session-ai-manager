import SwiftUI

/// Settings: which buttons the bar under the terminal shows. A switch per
/// button, in the bar's own order, kept on the device. The cog and the collapse
/// arrow are the bar's own and are always there.
struct TerminalToolbarSection: View {
    @AppStorage(TerminalKeyBar.hiddenKey) private var hiddenStored = ""

    var body: some View {
        Section {
            ForEach(TerminalKeyBar.groups.flatMap { $0 }, id: \.self) { key in
                Toggle(isOn: shows(key)) {
                    // A plain row, not a Label: a list shrinks a Label's icon to
                    // its own size, which pushed the badge over the "F1".
                    HStack(spacing: 14) {
                        TerminalBarKeyIcon(key: key, ground: Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(HerdrTheme.accent)
                            .frame(width: 32)
                        Text(key.name)
                    }
                }
                .tint(HerdrTheme.accent)
                .accessibilityIdentifier("settings.toolbar.shows.\(key.rawValue)")
            }
            Button("Show every button") { hiddenStored = "" }
                .disabled(hiddenStored.isEmpty)
                .accessibilityIdentifier("settings.toolbar.shows.all")
        } header: {
            Text("Toolbar")
        } footer: {
            Text("The buttons on the bar under the terminal, left to right. Hiding some leaves more room for the rest; where they do not all fit, the row scrolls sideways.")
        }
    }

    private func shows(_ key: TerminalBarKey) -> Binding<Bool> {
        Binding(
            get: { TerminalKeyBar.shows(key, in: hiddenStored) },
            set: { hiddenStored = TerminalKeyBar.stored(hiddenStored, showing: key, $0) }
        )
    }
}
