import SwiftUI

public struct ProviderDetailSheet: View {
    public var provider: ProviderQuota
    public var terminals: [TerminalAgentSession]
    public var onContinueSession: ((TerminalAgentSession) -> Void)?
    @Environment(\.dismiss) private var dismiss

    public init(
        provider: ProviderQuota,
        terminals: [TerminalAgentSession],
        onContinueSession: ((TerminalAgentSession) -> Void)? = nil
    ) {
        self.provider = provider
        self.terminals = terminals
        self.onContinueSession = onContinueSession
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            ProviderIconView(providerName: provider.name, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(provider.displayName)
                                        .font(HerdrTheme.mono(.headline, weight: .bold))
                                        .foregroundStyle(HerdrTheme.text)
                                    if let plan = provider.plan {
                                        Text(plan.uppercased())
                                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(HerdrTheme.selection))
                                            .foregroundStyle(HerdrTheme.subtext)
                                    }
                                }
                                Text(provider.state)
                                    .font(HerdrTheme.mono(.caption, weight: .semibold))
                                    .foregroundStyle(provider.isRateLimited ? HerdrTheme.red : HerdrTheme.green)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(provider.usedPercent.rounded()))%")
                                    .font(HerdrTheme.mono(.title2, weight: .bold))
                                    .foregroundStyle(provider.isRateLimited ? HerdrTheme.red : HerdrTheme.text)
                                Text("used")
                                    .font(HerdrTheme.mono(.caption2))
                                    .foregroundStyle(HerdrTheme.subtext)
                            }
                        }

                        // Progress Bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(HerdrTheme.selection)
                                    .frame(height: 8)
                                Capsule()
                                    .fill(provider.isRateLimited ? HerdrTheme.red : HerdrTheme.accent)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(provider.usedPercent / 100.0))), height: 8)
                            }
                        }
                        .frame(height: 8)

                        // Resets countdown & Windows
                        if let resets = provider.resetsAt {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(HerdrTheme.subtext)
                                Text("Resets: \(formatResetDate(resets))")
                                    .font(HerdrTheme.mono(.caption))
                                    .foregroundStyle(HerdrTheme.subtext)
                            }
                        }

                        if !provider.windows.isEmpty {
                            Divider().background(HerdrTheme.selection)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(provider.windows) { win in
                                    HStack {
                                        Text(win.group)
                                            .font(HerdrTheme.mono(.caption))
                                            .foregroundStyle(HerdrTheme.text)
                                        Spacer()
                                        Text("\(Int(win.usedPercent.rounded()))%")
                                            .font(HerdrTheme.mono(.caption, weight: .bold))
                                            .foregroundStyle(win.usedPercent >= 100 ? HerdrTheme.red : HerdrTheme.subtext)
                                    }
                                }
                            }
                        }

                        // Reset credits (e.g. Codex)
                        if let credits = provider.resetCredits, credits.availableCount > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "gift.fill")
                                    .foregroundStyle(HerdrTheme.green)
                                Text("\(credits.availableCount) reset credit\(credits.availableCount == 1 ? "" : "s") available")
                                    .font(HerdrTheme.mono(.caption, weight: .bold))
                                    .foregroundStyle(HerdrTheme.green)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                    .background(HerdrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Active Terminals Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACTIVE AGENTS ON THIS HOST (\(terminals.count))")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)

                        if terminals.isEmpty {
                            Text("No active agent terminals on this host.")
                                .font(HerdrTheme.mono(.caption))
                                .foregroundStyle(HerdrTheme.muted)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .background(HerdrTheme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            ForEach(terminals) { term in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(term.paneID) · \(term.name)")
                                            .font(HerdrTheme.mono(.subheadline, weight: .bold))
                                            .foregroundStyle(HerdrTheme.text)
                                        Spacer()
                                        Text(term.state.uppercased())
                                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(statusColor(term.state).opacity(0.2)))
                                            .foregroundStyle(statusColor(term.state))
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Project: \(term.project)")
                                            .font(HerdrTheme.mono(.caption))
                                            .foregroundStyle(HerdrTheme.subtext)
                                        if let model = term.model {
                                            Text("Model: \(model)")
                                                .font(HerdrTheme.mono(.caption))
                                                .foregroundStyle(HerdrTheme.subtext)
                                        }
                                        if let tokens = term.sessionTokens {
                                            Text("Tokens: \(formatTokens(tokens))")
                                                .font(HerdrTheme.mono(.caption))
                                                .foregroundStyle(HerdrTheme.subtext)
                                        }
                                    }

                                    if term.isLimitReached || provider.isRateLimited {
                                        HStack {
                                            Label("Rate limit reached in session", systemImage: "exclamationmark.triangle.fill")
                                                .font(HerdrTheme.mono(.caption, weight: .semibold))
                                                .foregroundStyle(HerdrTheme.red)
                                            Spacer()
                                            Button {
                                                dismiss()
                                                onContinueSession?(term)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text("Continue session")
                                                    Image(systemName: "arrow.right.circle.fill")
                                                }
                                                .font(HerdrTheme.mono(.caption, weight: .bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Capsule().fill(HerdrTheme.accent))
                                                .foregroundStyle(Color.black)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                                .padding()
                                .background(HerdrTheme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke((term.isLimitReached || provider.isRateLimited) ? HerdrTheme.red.opacity(0.4) : Color.clear, lineWidth: 1)
                                )
                            }
                        }
                    }
                }
                .padding()
            }
            .background(HerdrTheme.background)
            .navigationTitle("Provider Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func statusColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "working": return HerdrTheme.accent
        case "idle", "done": return HerdrTheme.subtext
        case "blocked": return HerdrTheme.red
        default: return HerdrTheme.muted
        }
    }

    private func formatResetDate(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let remaining = date.timeIntervalSinceNow
        if remaining > 0 {
            let hours = Int(remaining) / 3600
            let mins = (Int(remaining) % 3600) / 60
            return "in \(hours)h \(mins)m"
        }
        return "now"
    }

    private func formatTokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
