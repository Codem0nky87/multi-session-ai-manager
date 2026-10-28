import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

resources_dir = Path(__file__).resolve().parent.parent / "app" / "MultiSessionAIManager" / "Resources"


class ProviderPulseTests(unittest.TestCase):
    def setUp(self):
        target_path = resources_dir / "msam-provider-pulse.py"
        spec = importlib.util.spec_from_file_location("msam_provider_pulse", target_path)
        self.pulse_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.pulse_module)
        self.temp_dir = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_collect_claude_quota_parses_usage_and_respects_cache(self):
        creds_file = self.tmp_path / ".credentials.json"
        cache_file = self.tmp_path / "claude_cache.json"
        creds_file.write_text(json.dumps({
            "claudeAiOauth": {
                "accessToken": "test-token-123",
                "subscriptionType": "max",
                "expiresAt": 9999999999000
            }
        }))

        mock_usage_response = {
            "five_hour": {"utilization": 0.0, "resets_at": "2026-10-28T17:00:00Z"},
            "seven_day": {"utilization": 100.0, "resets_at": "2026-10-28T17:00:00Z"}
        }

        with patch.object(self.pulse_module, "http_get_json") as mock_http:
            mock_http.return_value = (200, mock_usage_response, {})
            res1 = self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            self.assertEqual(res1["state"], "RATE_LIMITED")
            self.assertEqual(res1["used_percent"], 100.0)
            self.assertEqual(res1["plan"], "max")
            self.assertEqual(res1["resets_at"], "2026-10-28T17:00:00Z")
            self.assertEqual(mock_http.call_count, 1)

            # Second call within cooldown must use cache without calling HTTP again
            res2 = self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            self.assertEqual(res2["state"], "RATE_LIMITED")
            self.assertEqual(res2["used_percent"], 100.0)
            self.assertEqual(mock_http.call_count, 1)

    def test_collect_codex_quota_parses_limits_and_reset_credits(self):
        limits_data = {
            "rateLimits": [
                {"group": "codex", "windowMinutes": 10080, "usedPercent": 1.0, "resetsAt": "2026-11-04T06:35:37Z"}
            ]
        }
        usage_data = {
            "resetCredits": {
                "availableCount": 2,
                "expiresAt": ["2026-10-29T19:13:44Z", "2026-11-06T23:38:50Z"]
            },
            "plan": "pro"
        }

        with patch.object(self.pulse_module, "query_codex_app_server") as mock_query:
            mock_query.return_value = (limits_data, usage_data)
            res = self.pulse_module.collect_codex_quota()
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["used_percent"], 1.0)
            self.assertEqual(res["plan"], "pro")
            self.assertEqual(res["reset_credits"]["available_count"], 2)
            self.assertEqual(len(res["reset_credits"]["expires_at"]), 2)

    def test_collect_antigravity_quota_parses_cli_output(self):
        mock_cli_output = """
        Gemini Models: 39% used, resets in 3d 21h (2026-11-01T07:29:52Z)
        Claude and GPT models: 0% used
        """
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=mock_cli_output)
            res = self.pulse_module.collect_antigravity_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["used_percent"], 39.0)
            self.assertEqual(res["resets_at"], "2026-11-01T07:29:52Z")

    def test_collect_antigravity_quota_parses_real_agy_usage_output(self):
        real_output = (
            "Gemini Models\tWeekly Limit Remaining\t52%\t2026-11-01T07:29:52Z\n"
            "Gemini Models\tFive Hour Limit Remaining\t64%\t2026-10-28T10:34:19Z\n"
            "Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-11-04T10:18:17Z\n"
            "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-28T15:18:17Z\n"
            "Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t7%\t2026-10-31T09:43:14Z\n"
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=real_output, stderr="")
            res = self.pulse_module.collect_antigravity_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["used_percent"], 93.0)
            self.assertEqual(res["resets_at"], "2026-10-28T10:34:19Z")
            self.assertEqual(len(res["windows"]), 5)
            # 52% remaining -> 48% used
            self.assertEqual(res["windows"][0]["used_percent"], 48.0)
            # 64% remaining -> 36% used
            self.assertEqual(res["windows"][1]["used_percent"], 36.0)

    def test_collect_terminal_agents_reads_agents_json_cache(self):
        state_dir = self.tmp_path / ".local" / "state" / "msam-host-agent"
        state_dir.mkdir(parents=True)
        agents_cache = state_dir / "agents.json"
        agents_cache.write_text(json.dumps({
            "sessions": [
                {
                    "session": "default",
                    "socketPath": "/tmp/herdr.sock",
                    "agents": [
                        {
                            "agent": "claude",
                            "pane_id": "wD:p1",
                            "tab_id": "wD:t1",
                            "name": "pantheon",
                            "cwd": "/home/rufus/Projects/pantheon",
                            "agent_status": "idle"
                        },
                        {
                            "agent": "claude",
                            "pane_id": "wD:p2",
                            "tab_id": "wD:t2",
                            "name": "netapp-dashboard",
                            "cwd": "/home/rufus/Projects/netapp-dashboard",
                            "agent_status": "idle"
                        }
                    ]
                }
            ]
        }))

        terminals = self.pulse_module.collect_terminal_agents(home_dir=self.tmp_path)
        self.assertEqual(len(terminals), 2)
        self.assertEqual(terminals[0]["provider"], "claude_code")
        self.assertEqual(terminals[0]["name"], "pantheon")
        self.assertEqual(terminals[1]["provider"], "claude_code")
        self.assertEqual(terminals[1]["name"], "netapp-dashboard")

    def test_collect_terminal_agents_matches_transcripts(self):
        codex_session_dir = self.tmp_path / ".codex" / "sessions" / "2026" / "10"
        codex_session_dir.mkdir(parents=True)
        transcript_file = codex_session_dir / "01a18130-047b-7e41-9b76-cff8c8e195c4.jsonl"
        transcript_file.write_text(
            json.dumps({"type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}) + "\n" +
            json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 23082435}}}}) + "\n"
        )

        agents_list_json = json.dumps({
            "result": {
                "agents": [
                    {
                        "agent": "codex",
                        "pane_id": "wD:p7",
                        "tab_id": "wD:t7",
                        "name": "pulse-codex",
                        "cwd": "/home/rufus/Projects/ai-stack",
                        "agent_status": "idle",
                        "agent_session": {"value": "01a18130-047b-7e41-9b76-cff8c8e195c4"}
                    }
                ]
            }
        })

        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=agents_list_json)
            terminals = self.pulse_module.collect_terminal_agents(home_dir=self.tmp_path)
            self.assertEqual(len(terminals), 1)
            t = terminals[0]
            self.assertEqual(t["pane_id"], "wD:p7")
            self.assertEqual(t["provider"], "codex")
            self.assertEqual(t["model"], "gpt-6.1-sol")
            self.assertEqual(t["session_tokens"], 23082435)
            self.assertEqual(Path(t["transcript_path"]).resolve(), transcript_file.resolve())
            self.assertFalse(t["is_limit_reached"])

    def test_analyze_session_task_selects_model_and_effort(self):
        transcript_file = self.tmp_path / "test-transcript.jsonl"
        transcript_file.write_text(
            json.dumps({"type": "user", "message": "Refactor architecture and build release binary with swift and python"}) + "\n" +
            json.dumps({"type": "assistant", "message": "Encountered compiler deadlock in build_app and requires full restructure"}) + "\n"
        )

        recommendation = self.pulse_module.analyze_session_task(str(transcript_file), target_provider="codex")
        self.assertEqual(recommendation["model"], "gpt-6.1-sol")
        self.assertEqual(recommendation["effort"], "high")
        self.assertIn("summary", recommendation)


if __name__ == '__main__':
    unittest.main()
