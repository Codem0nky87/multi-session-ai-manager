import SwiftUI

struct SessionRolloverSheet: View {
    var terminal: TerminalAgentSession
    var availableProviders: [ProviderQuota]
    var onSelectRollover: (String, Bool, TerminalAgentSession) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: String = "codex"
    @State private var autoApprove: Bool = true

    init(
        terminal: TerminalAgentSession,
        availableProviders: [ProviderQuota],
        onSelectRollover: @escaping (String, Bool, TerminalAgentSession) -> Void
    ) {
        self.terminal = terminal
        self.availableProviders = availableProviders
        self.onSelectRollover = onSelectRollover

        // Pre-select least loaded provider different from source
        let candidates = availableProviders.filter {
            !$0.name.lowercased().contains(terminal.provider.lowercased()) && !$0.isRateLimited
        }
        let best = candidates.min(by: { $0.usedPercent < $1.usedPercent })
        _selectedProvider = State(initialValue: best?.name ?? "codex")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // Current session card
                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT SESSION")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(terminal.paneID) · \(terminal.name)")
                                .font(HerdrTheme.mono(.headline, weight: .bold))
                                .foregroundStyle(HerdrTheme.text)
                            Text("Project: \(terminal.project)")
                                .font(HerdrTheme.mono(.caption))
                                .foregroundStyle(HerdrTheme.subtext)
                        }
                        Spacer()
                        Label("Rate Limited", systemImage: "exclamationmark.triangle.fill")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                            .foregroundStyle(HerdrTheme.red)
                    }
                }
                .padding()
                .background(HerdrTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Replacement selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("SELECT REPLACEMENT PROVIDER")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)

                    ForEach(availableProviders.filter { !$0.name.lowercased().contains(terminal.provider.lowercased()) }) { prov in
                        Button {
                            selectedProvider = prov.name
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedProvider == prov.name ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedProvider == prov.name ? HerdrTheme.accent : HerdrTheme.muted)
                                    .font(.title3)

                                ProviderIconView(providerName: prov.name, size: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prov.displayName)
                                        .font(HerdrTheme.mono(.body, weight: .semibold))
                                        .foregroundStyle(HerdrTheme.text)
                                    Text("\(Int(prov.usedPercent))% used · \(prov.state)")
                                        .font(HerdrTheme.mono(.caption2))
                                        .foregroundStyle(prov.isRateLimited ? HerdrTheme.red : HerdrTheme.subtext)
                                }

                                Spacer()

                                if prov.isRateLimited {
                                    Text("LIMITED")
                                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                                        .foregroundStyle(HerdrTheme.red)
                                } else if let credits = prov.resetCredits, credits.availableCount > 0 {
                                    Text("\(credits.availableCount) reset\(credits.availableCount == 1 ? "" : "s")")
                                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                                        .foregroundStyle(HerdrTheme.green)
                                }
                            }
                            .padding()
                            .background(selectedProvider == prov.name ? HerdrTheme.selection : HerdrTheme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(prov.isRateLimited)
                    }
                }

                // Options
                VStack(alignment: .leading, spacing: 10) {
                    Text("EXECUTION OPTIONS")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)

                    Toggle(isOn: $autoApprove) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-approve commands")
                                .font(HerdrTheme.mono(.subheadline, weight: .medium))
                                .foregroundStyle(HerdrTheme.text)
                            Text(permissionFlagDescription(for: selectedProvider))
                                .font(HerdrTheme.mono(.caption2))
                                .foregroundStyle(HerdrTheme.subtext)
                        }
                    }
                    .tint(HerdrTheme.accent)
                }
                .padding()
                .background(HerdrTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer()

                Button {
                    executeRollover()
                } label: {
                    HStack {
                        Spacer()
                        Text("Resume Task with \(providerDisplayName) 🚀")
                            .font(HerdrTheme.mono(.body, weight: .bold))
                            .foregroundStyle(Color.black)
                        Spacer()
                    }
                    .padding()
                    .background(Capsule().fill(HerdrTheme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(HerdrTheme.background)
            .navigationTitle("Continue Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var providerDisplayName: String {
        let p = selectedProvider.lowercased()
        if p.contains("claude") { return "Claude" }
        if p.contains("codex") { return "Codex" }
        if p.contains("anti") || p.contains("agy") { return "Antigravity" }
        if p.contains("hermes") { return "Hermes" }
        return selectedProvider.capitalized
    }

    private func permissionFlagDescription(for provider: String) -> String {
        let p = provider.lowercased()
        if p.contains("claude") {
            return "Passes --dangerously-skip-permissions to bypass prompts"
        }
        return "Passes --yolo to bypass dangerous tool approval prompts"
    }

    private func executeRollover() {
        dismiss()
        onSelectRollover(selectedProvider, autoApprove, terminal)
    }
}
