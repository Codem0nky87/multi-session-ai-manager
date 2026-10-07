import SwiftUI

struct FunctionKeyPalette: View {
    let send: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Function keys").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(TerminalFunctionKey.numbers, id: \.self) { number in
                    Button("F\(number)") { send(number) }
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Send F\(number) to active terminal")
                        .accessibilityIdentifier("terminal.function-key.\(number)")
                }
            }
            Text("Sends to the active terminal pane.")
                .font(.caption).foregroundStyle(HerdrTheme.subtext)
        }
        .padding(16)
        .frame(width: 280)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.background)
    }
}
