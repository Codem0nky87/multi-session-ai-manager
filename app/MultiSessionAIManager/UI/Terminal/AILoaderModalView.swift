import SwiftUI

/// State representing an active background AI model & effort analysis and session rollover.
public struct AILoaderState: Equatable, Sendable {
    public var provider: String
    public var terminal: TerminalAgentSession
    public var statusMessage: String
    public var detailedMessage: String?
    public var isComplete: Bool = false

    public init(
        provider: String,
        terminal: TerminalAgentSession,
        statusMessage: String = "Analyzing previous session task…",
        detailedMessage: String? = nil,
        isComplete: Bool = false
    ) {
        self.provider = provider
        self.terminal = terminal
        self.statusMessage = statusMessage
        self.detailedMessage = detailedMessage
        self.isComplete = isComplete
    }
}

/// Modal overlay presented while the host evaluates the session task complexity
/// and launches the selected AI provider in an adjacent Herdr tab.
public struct AILoaderModalView: View {
    public let state: AILoaderState
    public var onCancel: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0

    public init(state: AILoaderState, onCancel: (() -> Void)? = nil) {
        self.state = state
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            // Fullscreen backdrop dimming
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Pulsing provider icon
                ZStack {
                    Circle()
                        .fill(HerdrTheme.accent.opacity(0.15))
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulseScale)

                    ProviderIconView(providerName: state.provider, size: 40)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulseScale = 1.2
                    }
                }

                VStack(spacing: 8) {
                    Text("AI Session Rollover")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)
                        .textCase(.uppercase)

                    Text("Analyzing Task with \(providerDisplayName)…")
                        .font(HerdrTheme.mono(.headline, weight: .bold))
                        .foregroundStyle(HerdrTheme.text)
                        .multilineTextAlignment(.center)

                    Text(state.statusMessage)
                        .font(HerdrTheme.mono(.subheadline))
                        .foregroundStyle(HerdrTheme.accent)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)

                    if let details = state.detailedMessage {
                        Text(details)
                            .font(HerdrTheme.mono(.caption2))
                            .foregroundStyle(HerdrTheme.subtext)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }

                ProgressView()
                    .controlSize(.regular)
                    .tint(HerdrTheme.accent)

                if let onCancel {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(HerdrTheme.mono(.caption, weight: .medium))
                    .foregroundStyle(HerdrTheme.muted)
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(HerdrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(HerdrTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
    }

    private var providerDisplayName: String {
        let p = state.provider.lowercased()
        if p.contains("claude") { return "Claude" }
        if p.contains("codex") { return "Codex" }
        if p.contains("anti") || p.contains("agy") { return "Antigravity" }
        if p.contains("hermes") { return "Hermes" }
        return state.provider.capitalized
    }
}
