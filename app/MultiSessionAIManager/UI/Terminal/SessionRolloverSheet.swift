import SwiftUI

struct SessionRolloverSheet: View {
    var terminal: TerminalAgentSession
    var availableProviders: [ProviderQuota]
    var service: SSHService?
    var onExecuteRollover: (String, String, TerminalAgentSession) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: String = "codex"
    @State private var autoApprove: Bool = true
    @State private var isAnalyzing: Bool = false
    @State private var analysisStatus: String? = nil

    init(
        terminal: TerminalAgentSession,
        availableProviders: [ProviderQuota],
        service: SSHService? = nil,
        onExecuteRollover: @escaping (String, String, TerminalAgentSession) -> Void
    ) {
        self.terminal = terminal
        self.availableProviders = availableProviders
        self.service = service
        self.onExecuteRollover = onExecuteRollover

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

                if let status = analysisStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(HerdrTheme.accent)
                        Text(status)
                            .font(HerdrTheme.mono(.caption))
                            .foregroundStyle(HerdrTheme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                Button {
                    executeRollover()
                } label: {
                    HStack {
                        Spacer()
                        if isAnalyzing {
                            ProgressView()
                                .tint(Color.black)
                            Text("Analyzing Task…")
                                .font(HerdrTheme.mono(.body, weight: .bold))
                                .foregroundStyle(Color.black)
                        } else {
                            Text("Continue in New Tab 🚀")
                                .font(HerdrTheme.mono(.body, weight: .bold))
                                .foregroundStyle(Color.black)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Capsule().fill(HerdrTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(isAnalyzing)
            }
            .padding()
            .background(HerdrTheme.background)
            .navigationTitle("Continue Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                        .disabled(isAnalyzing)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func permissionFlagDescription(for provider: String) -> String {
        let p = provider.lowercased()
        if p.contains("claude") {
            return "Passes --dangerously-skip-permissions to bypass prompts"
        }
        return "Passes --yolo to bypass dangerous tool approval prompts"
    }

    private func executeRollover() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisStatus = "Analyzing previous task in background…"

        Task {
            var model = "gpt-6.1-sol"
            var effort = "high"

            // Hidden analysis session on host
            if let service {
                let transcriptPath = terminal.transcriptPath ?? ""
                let analyzeCmd = "python3 \"$HOME/.local/libexec/msam-host-agent/current/msam-host-agent.py\" analyze-task \"\(transcriptPath)\" \"\(selectedProvider)\""
                if let output = try? await service.run(analyzeCmd, timeout: .seconds(10), outputLimit: 65536),
                   let data = output.stdoutString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let m = json["model"] as? String { model = m }
                    if let e = json["effort"] as? String { effort = e }
                }
            }

            // Construct continuation command
            let p = selectedProvider.lowercased()
            let transcriptArg = terminal.transcriptPath.map { " at \($0)" } ?? ""
            let taskPrompt = "Continue previous task from session\(transcriptArg) in \(terminal.project). Inspect prior turns and proceed."
            let command: String

            if p.contains("codex") {
                let yoloFlag = autoApprove ? "--yolo " : ""
                command = "codex --model \(model) -c model_effort=\(effort) \(yoloFlag)\"\(taskPrompt)\""
            } else if p.contains("claude") {
                let yoloFlag = autoApprove ? "--dangerously-skip-permissions " : ""
                command = "claude --model \(model) \(yoloFlag)\"\(taskPrompt)\""
            } else if p.contains("anti") || p.contains("agy") {
                let yoloFlag = autoApprove ? "--yolo " : ""
                command = "agy --model \(model) \(yoloFlag)\"\(taskPrompt)\""
            } else if p.contains("hermes") {
                let yoloFlag = autoApprove ? "--yolo " : ""
                command = "hermes -m \(model) \(yoloFlag)-z \"\(taskPrompt)\""
            } else {
                command = "\(selectedProvider) \"\(taskPrompt)\""
            }

            await MainActor.run {
                isAnalyzing = false
                dismiss()
                onExecuteRollover(selectedProvider, command, terminal)
            }
        }
    }
}
