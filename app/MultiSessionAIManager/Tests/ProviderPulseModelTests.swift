import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct ProviderPulseModelTests {
    @Test func decodesProvidersAndTerminalAgentsFromPayload() throws {
        let json = """
        {
            "providers": {
                "claude_code": {
                    "state": "RATE_LIMITED",
                    "used_percent": 100.0,
                    "resets_at": "2026-10-28T17:00:00Z",
                    "plan": "max",
                    "windows": [
                        { "group": "All models", "window_minutes": 10080, "used_percent": 100.0, "resets_at": "2026-10-28T17:00:00Z" }
                    ]
                },
                "codex": {
                    "state": "HEALTHY",
                    "used_percent": 1.0,
                    "resets_at": "2026-11-04T06:35:37Z",
                    "plan": "pro",
                    "windows": [
                        { "group": "codex", "window_minutes": 10080, "used_percent": 1.0, "resets_at": "2026-11-04T06:35:37Z" }
                    ],
                    "reset_credits": {
                        "available_count": 2,
                        "expires_at": ["2026-10-29T19:13:44Z", "2026-11-06T23:38:50Z"]
                    }
                }
            },
            "terminal_agents": [
                {
                    "pane_id": "wD:p7",
                    "tab_id": "wD:t7",
                    "name": "pulse-claude",
                    "provider": "claude_code",
                    "project": "ai-stack",
                    "state": "blocked",
                    "model": "claude-3-7-sonnet",
                    "session_tokens": 1420500,
                    "transcript_path": "/home/rufus/.claude/projects/test/01a.jsonl",
                    "is_limit_reached": true
                }
            ]
        }
        """

        let payload = try JSONDecoder().decode(HostMetricsModel.MetricsPayload.self, from: Data(json.utf8))
        let metrics = HostMetricsModel()
        metrics.update(from: payload)

        let pulse = metrics.pulse
        #expect(pulse.activeProviders.count == 2)
        #expect(pulse.hasRateLimitedProvider == true)

        let claude = try #require(pulse.providers["claude_code"])
        #expect(claude.isRateLimited == true)
        #expect(claude.displayName == "Claude Code")
        #expect(claude.usedPercent == 100.0)

        let codex = try #require(pulse.providers["codex"])
        #expect(codex.isRateLimited == false)
        #expect(codex.resetCredits?.availableCount == 2)

        let terminals = pulse.terminals(for: "claude_code")
        #expect(terminals.count == 1)
        #expect(terminals.first?.isLimitReached == true)
        #expect(terminals.first?.transcriptPath == "/home/rufus/.claude/projects/test/01a.jsonl")
    }
}
