import SwiftUI

struct TerminalPreferencesSection: View {
    @Bindable var settings: TerminalSettings

    var body: some View {
        Section("Terminal") {
            HStack {
                Text("Text size")
                Spacer()
                Button {
                    settings.step(-1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Decrease terminal text size")
                .accessibilityIdentifier("settings.terminal.decrease")
                .buttonStyle(.borderless)

                Text("\(Int(settings.fontSize)) pt")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 52)

                Button {
                    settings.step(1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Increase terminal text size")
                .accessibilityIdentifier("settings.terminal.increase")
                .buttonStyle(.borderless)
            }

            Button("Reset to \(Int(TerminalSettings.defaultSize)) pt") {
                settings.setFontSize(TerminalSettings.defaultSize)
            }
        }
    }
}
