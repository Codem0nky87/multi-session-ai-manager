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

    @Test func formatsResetDateInLocalTimezoneWithFractionalSeconds() throws {
        // Raw ISO8601 with microseconds and UTC timezone
        let raw = "2026-10-28T17:00:00.299728+00:00"
        let parsed = try #require(ProviderDetailSheet.parseResetDate(raw))

        // Fixed reference time: 2026-10-28 11:24:00 UTC
        let now = Date(timeIntervalSince1970: 1793186640) // 2026-10-28 11:24:00 UTC
        let timeZone = try #require(TimeZone(secondsFromGMT: 7200)) // SAST (UTC+2)
        let locale = Locale(identifier: "en_GB")

        let formatted = ProviderDetailSheet.formatResetDate(raw, now: now, timeZone: timeZone, locale: locale)
        #expect(formatted.contains("Today"))
        #expect(formatted.contains("19:00"))
        #expect(formatted.contains("in 5h 36m"))
    }

    @Test func matchesProviderAliasesInTerminals() {
        let pulse = ProviderPulseModel()
        let t1 = TerminalAgentSession(paneID: "p1", name: "pantheon", provider: "claude", project: "pantheon")
        let t2 = TerminalAgentSession(paneID: "p2", name: "netapp", provider: "claude_code", project: "netapp")
        let t3 = TerminalAgentSession(paneID: "p3", name: "dev", provider: "agy", project: "tools")
        let t4 = TerminalAgentSession(paneID: "p4", name: "bot", provider: "codex", project: "app")

        pulse.update(providers: [:], terminals: [t1, t2, t3, t4])

        // Query by "claude_code" matches both "claude" and "claude_code"
        let claudeCodeTerms = pulse.terminals(for: "claude_code")
        #expect(claudeCodeTerms.count == 2)

        // Query by "claude" matches both "claude" and "claude_code"
        let claudeTerms = pulse.terminals(for: "claude")
        #expect(claudeTerms.count == 2)

        // Query by "antigravity" matches "agy"
        let agyTerms = pulse.terminals(for: "antigravity")
        #expect(agyTerms.count == 1)
        #expect(agyTerms.first?.paneID == "p3")
    }

    @Test func decodesTerminalAgentWithMissingOptionalFields() throws {
        let minimalJSON = """
        {
            "pane_id": "wD:p9"
        }
        """
        let term = try JSONDecoder().decode(TerminalAgentSession.self, from: Data(minimalJSON.utf8))
        #expect(term.paneID == "wD:p9")
        #expect(term.name == "wD:p9")
        #expect(term.provider == "")
        #expect(term.state == "idle")
        #expect(term.isLimitReached == false)
    }
}
