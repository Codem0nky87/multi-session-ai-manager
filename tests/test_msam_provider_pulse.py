import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import sys

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

    def test_collect_claude_quota_parses_spend_allowance(self):
        creds_file = self.tmp_path / ".credentials.json"
        creds_file.write_text(json.dumps({
            "claudeAiOauth": {
                "accessToken": "test-token-123",
                "subscriptionType": "max",
                "expiresAt": 9999999999000
            }
        }))

        # Field names as returned by /api/oauth/usage on 2026-11-10.
        def usage(enabled, used_minor):
            return {
                "five_hour": {"utilization": 0.0, "resets_at": "2026-11-10T17:00:00Z"},
                "seven_day": {"utilization": 5.0, "resets_at": "2026-11-11T16:59:00Z"},
                "spend": {
                    "used": {"amount_minor": used_minor, "currency": "USD", "exponent": 2},
                    "limit": {"amount_minor": 20000, "currency": "USD", "exponent": 2},
                    "enabled": enabled, "disabled_reason": None if enabled else "out_of_credits",
                    "cap": {"money": None, "credits": {"amount_minor": 20000, "exponent": 2}},
                },
                "extra_usage": {"is_enabled": enabled, "monthly_limit": 20000, "used_credits": float(used_minor),
                                "decimal_places": 2, "disabled_reason": None if enabled else "out_of_credits"},
            }

        with patch.object(self.pulse_module, "http_get_json") as mock_http:
            mock_http.return_value = (200, usage(True, 5000), {})
            res = self.pulse_module.collect_claude_quota(creds_file, cache_path=self.tmp_path / "c.json")
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["used_percent"], 5.0)
            self.assertEqual(len(res["windows"]), 3)
            self.assertEqual(res["windows"][0]["group"], "5-Hour Pool")
            self.assertEqual(res["windows"][1]["group"], "7-Day Quota")
            self.assertEqual(res["windows"][2]["group"], "API Allowance ($200)")
            self.assertEqual(res["windows"][2]["used_percent"], 25.0)

            # A disabled allowance (out of credits) cannot be spent, so it is not shown as available.
            mock_http.return_value = (200, usage(False, 0), {})
            res = self.pulse_module.collect_claude_quota(creds_file, cache_path=self.tmp_path / "c-disabled.json")
            self.assertEqual([w["group"] for w in res["windows"]], ["5-Hour Pool", "7-Day Quota"])

    def test_collect_claude_quota_never_refreshes_or_writes_the_login(self):
        creds_file = self.tmp_path / ".credentials.json"
        creds_file.write_text(json.dumps({
            "claudeAiOauth": {
                "accessToken": "old-stale-token",
                "refreshToken": "valid-refresh-token",
                "subscriptionType": "max",
                "expiresAt": 9999999999000,
            }
        }))
        before = creds_file.read_bytes()
        self.assertFalse(hasattr(self.pulse_module, "refresh_claude_oauth_token"))

        with patch.object(self.pulse_module, "http_get_json") as mock_http, \
             patch.object(self.pulse_module.urllib.request, "urlopen") as mock_urlopen:
            mock_http.return_value = (401, {"error": "Invalid bearer token"}, {})
            res = self.pulse_module.collect_claude_quota(creds_file, cache_path=self.tmp_path / "c2.json")
            self.assertEqual(res["state"], "SIGN_IN_REQUIRED")
            self.assertEqual(mock_http.call_count, 1)
            mock_urlopen.assert_not_called()
            # The rejection is cached, so the next sample does not retry the same token.
            self.pulse_module.collect_claude_quota(creds_file, cache_path=self.tmp_path / "c2.json")
            self.assertEqual(mock_http.call_count, 1)
        self.assertEqual(creds_file.read_bytes(), before)

    def test_collect_claude_quota_expired_login_makes_no_request(self):
        creds_file = self.tmp_path / ".credentials.json"
        creds_file.write_text(json.dumps({
            "claudeAiOauth": {
                "accessToken": "stale-token",
                "refreshToken": "refresh-token",
                "subscriptionType": "max",
                "expiresAt": 1000,
            }
        }))

        with patch.object(self.pulse_module, "http_get_json") as mock_http:
            res = self.pulse_module.collect_claude_quota(creds_file, cache_path=self.tmp_path / "c3.json")
            self.assertEqual(res["state"], "SIGN_IN_REQUIRED")
            mock_http.assert_not_called()

    def test_collect_claude_quota_throttle_backs_off_and_keeps_last_reading(self):
        creds_file = self.tmp_path / ".credentials.json"
        creds_file.write_text(json.dumps({"claudeAiOauth": {"accessToken": "t", "expiresAt": 9999999999000}}))
        cache_file = self.tmp_path / "c4.json"
        good = {"seven_day": {"utilization": 42.0, "resets_at": "2026-11-11T16:59:00Z"}}

        with patch.object(self.pulse_module, "http_get_json") as mock_http, \
             patch.object(self.pulse_module.time, "time") as clock:
            clock.return_value = 1_000_000.0
            mock_http.return_value = (200, good, {})
            self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)

            clock.return_value += 301
            mock_http.return_value = (429, {}, {"Retry-After": "1200"})
            res = self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            self.assertEqual(res["state"], "REFRESH_DELAYED")
            self.assertEqual(res["used_percent"], 42.0)

            clock.return_value += 900  # still inside Retry-After: no request
            self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            self.assertEqual(mock_http.call_count, 2)

            clock.return_value += 301  # past Retry-After; second failure backs off 600 s
            mock_http.return_value = (429, {}, {})
            self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            clock.return_value += 400
            self.pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
            self.assertEqual(mock_http.call_count, 3)

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

        with patch("subprocess.run") as mock_run:
            mock_run.side_effect = FileNotFoundError()
            recommendation = self.pulse_module.analyze_session_task(str(transcript_file), target_provider="codex")
            self.assertEqual(recommendation["model"], "gpt-6.1-sol")
            self.assertEqual(recommendation["effort"], "high")
            self.assertIn("summary", recommendation)

    def test_analyze_session_task_invokes_provider_cli(self):
        transcript_file = self.tmp_path / "test-transcript.jsonl"
        transcript_file.write_text(
            json.dumps({"type": "user", "message": "Fix login modal rendering issue"}) + "\n"
        )

        cli_json = json.dumps({
            "model": "gemini-2.5-pro",
            "effort": "medium",
            "summary": "Fix UI rendering glitch in modal"
        })

        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=cli_json, stderr="")
            res = self.pulse_module.analyze_session_task(str(transcript_file), target_provider="agy", home_dir=self.tmp_path)
            self.assertEqual(res["model"], "gemini-2.5-pro")
            self.assertEqual(res["effort"], "medium")
            self.assertEqual(res["summary"], "Fix UI rendering glitch in modal")
            self.assertTrue(mock_run.called)
            args, kwargs = mock_run.call_args
            cmd_str = args[0] if isinstance(args[0], str) else " ".join(args[0])
            self.assertIn("agy", cmd_str)

    def test_analyze_session_task_falls_back_when_cli_fails(self):
        transcript_file = self.tmp_path / "test-transcript.jsonl"
        transcript_file.write_text(
            json.dumps({"type": "user", "message": "Investigate simple typo in help text"}) + "\n"
        )

        with patch("subprocess.run") as mock_run:
            # Non-zero exit code
            mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="command failed")
            res = self.pulse_module.analyze_session_task(str(transcript_file), target_provider="codex", home_dir=self.tmp_path)
            self.assertEqual(res["model"], "gpt-6.1-sol")
            self.assertEqual(res["effort"], "medium")
            self.assertFalse(res["is_complex"])

    def test_get_installed_herdr_integrations_falls_back_to_hook_files(self):
        # Create hook files on tmp_path
        claude_hook = self.tmp_path / ".claude" / "hooks" / "herdr-agent-state.sh"
        claude_hook.parent.mkdir(parents=True, exist_ok=True)
        claude_hook.write_text("#!/bin/sh\n")

        agy_hook = self.tmp_path / ".gemini" / "config" / "hooks" / "herdr-agent-state.sh"
        agy_hook.parent.mkdir(parents=True, exist_ok=True)
        agy_hook.write_text("#!/bin/sh\n")

        with patch("subprocess.run", side_effect=FileNotFoundError):
            installed = self.pulse_module.get_installed_herdr_integrations(home_dir=self.tmp_path)
            self.assertEqual(installed, {"claude", "antigravity-cli"})
            self.assertNotIn("hermes", installed)

    def test_collect_hermes_quota_returns_unavailable_on_failure(self):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "UNAVAILABLE")

    def test_collect_hermes_quota_local_or_custom_endpoint_is_healthy(self):
        stderr_msg = "No account usage available for provider 'custom': no credential is configured for it, the provider has no usage endpoint, or the fetch failed.\n"
        mock_proc = MagicMock(returncode=1, stdout="", stderr=stderr_msg)
        with patch("subprocess.run", return_value=mock_proc):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "custom")
            self.assertEqual(res["used_percent"], 0.0)

    def test_collect_hermes_quota_parses_json_usage(self):
        stdout_json = json.dumps({
            "used_percent": 42.5,
            "plan": "pro",
            "resets_at": "2026-11-08T12:00:00Z",
            "windows": [{"group": "daily", "used_percent": 42.5}]
        })
        mock_proc = MagicMock(returncode=0, stdout=stdout_json, stderr="")
        with patch("subprocess.run", return_value=mock_proc):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "pro")
            self.assertEqual(res["used_percent"], 42.5)
        status_output = (
            "pi: not installed (/home/rufus/.pi/agent/extensions/herdr-agent-state.ts)\n"
            "omp: not installed (/home/rufus/.omp/agent/extensions/herdr-omp-agent-state.ts)\n"
            "claude: current (v11) (/home/rufus/.claude/hooks/herdr-agent-state.sh)\n"
            "codex: current (v10) (/home/rufus/.codex/herdr-agent-state.sh)\n"
            "copilot: not installed (/home/rufus/.copilot/hooks/herdr-agent-state.sh)\n"
            "hermes: not installed (/home/rufus/.hermes/plugins/herdr-agent-state/__init__.py)\n"
            "antigravity-cli: current (v4) (/home/rufus/.gemini/config/hooks/herdr-agent-state.sh)\n"
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=status_output)
            installed = self.pulse_module.get_installed_herdr_integrations(home_dir=self.tmp_path)
            self.assertEqual(installed, {"claude", "codex", "antigravity-cli"})
            self.assertNotIn("hermes", installed)
            self.assertNotIn("pi", installed)

    def test_collect_provider_telemetry_excludes_uninstalled_integrations(self):
        with patch.object(self.pulse_module, "get_installed_herdr_integrations", return_value={"claude", "antigravity-cli"}):
            with patch.object(self.pulse_module, "collect_claude_quota", return_value={"state": "HEALTHY", "used_percent": 10.0}):
                with patch.object(self.pulse_module, "collect_antigravity_quota", return_value={"state": "HEALTHY", "used_percent": 20.0}):
                    with patch.object(self.pulse_module, "collect_terminal_agents", return_value=[]):
                        telemetry = self.pulse_module.collect_provider_telemetry(home_dir=self.tmp_path)
                        provs = telemetry["providers"]
                        self.assertIn("claude_code", provs)
                        self.assertIn("antigravity", provs)
                        self.assertNotIn("hermes", provs)
                        self.assertNotIn("codex", provs)
                        self.assertEqual(telemetry.get("installed_integrations"), ["antigravity-cli", "claude"])



    def test_query_codex_app_server_times_out_and_kills_process(self):
        import subprocess, time
        # Start a process that sleeps and never produces JSON-RPC output
        dummy_proc = subprocess.Popen(["sleep", "10"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        with patch("subprocess.Popen", return_value=dummy_proc):
            t0 = time.time()
            with self.assertRaises((TimeoutError, Exception)):
                self.pulse_module.query_codex_app_server(codex_bin="mock-codex", timeout=0.5)
            elapsed = time.time() - t0
            self.assertLess(elapsed, 3.0, "query_codex_app_server must not block past timeout")
            self.assertIsNotNone(dummy_proc.poll(), "Process must be terminated on timeout")

    def test_collect_codex_quota_resolves_bin_from_home_and_passes_env(self):
        bin_dir = self.tmp_path / ".local" / "bin"
        bin_dir.mkdir(parents=True)
        codex_mock = bin_dir / "codex"
        codex_mock.write_text("#!/bin/sh\nexit 0\n")
        codex_mock.chmod(0o755)

        test_env = {"PATH": "/usr/bin:/bin"}
        with patch.object(self.pulse_module, "query_codex_app_server", return_value=({}, {})) as mock_query:
            self.pulse_module.collect_codex_quota(home_dir=self.tmp_path, env=test_env)
            self.assertTrue(mock_query.called)
            called_bin, called_env = mock_query.call_args.kwargs.get("codex_bin") or mock_query.call_args.args[0], mock_query.call_args.kwargs.get("env")
            self.assertEqual(called_bin, str(codex_mock))
            self.assertIn(str(bin_dir), called_env.get("PATH", ""))

    def test_collect_provider_telemetry_passes_home_and_env_to_codex(self):
        test_env = {"PATH": "/usr/bin"}
        with patch.object(self.pulse_module, "get_installed_herdr_integrations", return_value={"codex"}):
            with patch.object(self.pulse_module, "collect_codex_quota", return_value={"state": "HEALTHY", "used_percent": 5.0}) as mock_codex:
                with patch.object(self.pulse_module, "collect_terminal_agents", return_value=[]):
                    res = self.pulse_module.collect_provider_telemetry(home_dir=self.tmp_path, env=test_env)
                    self.assertTrue(mock_codex.called)
                    kwargs = mock_codex.call_args.kwargs
                    self.assertEqual(kwargs.get("home_dir"), self.tmp_path)
                    self.assertEqual(kwargs.get("env"), test_env)
                    self.assertIn("codex", res["providers"])

    def test_query_hermes_session_reads_sqlite_state_db(self):
        # 1. Non-existent DB returns None
        self.assertIsNone(self.pulse_module._query_hermes_session(self.tmp_path))

        # 2. Create state.db
        hermes_dir = self.tmp_path / ".hermes"
        hermes_dir.mkdir(parents=True, exist_ok=True)
        db_path = hermes_dir / "state.db"

        import sqlite3
        conn = sqlite3.connect(db_path)
        conn.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                title TEXT,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                started_at REAL NOT NULL
            )
        """)
        conn.execute(
            "INSERT INTO sessions (id, model, title, input_tokens, output_tokens, started_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("sess-1", "qwen3.8-flash-next", "First Task", 1000, 250, 100.0)
        )
        conn.execute(
            "INSERT INTO sessions (id, model, title, input_tokens, output_tokens, started_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("cron_abc_20261106", "qwen-coder-32b", "Second Task", 2000, 500, 200.0)
        )
        conn.commit()
        conn.close()

        # Without session_id -> latest session
        latest = self.pulse_module._query_hermes_session(self.tmp_path)
        self.assertIsNotNone(latest)
        self.assertEqual(latest["id"], "cron_abc_20261106")
        self.assertEqual(latest["model"], "qwen-coder-32b")
        self.assertEqual(latest["title"], "Second Task")
        self.assertEqual(latest["tokens"], 2500)

        # Exact session_id
        s1 = self.pulse_module._query_hermes_session(self.tmp_path, session_id="sess-1")
        self.assertIsNotNone(s1)
        self.assertEqual(s1["id"], "sess-1")
        self.assertEqual(s1["tokens"], 1250)

        # Partial session_id (LIKE)
        sp = self.pulse_module._query_hermes_session(self.tmp_path, session_id="abc_20261106")
        self.assertIsNotNone(sp)
        self.assertEqual(sp["id"], "cron_abc_20261106")

        # Unknown session_id
        self.assertIsNone(self.pulse_module._query_hermes_session(self.tmp_path, session_id="non-existent"))

    def test_collect_hermes_quota_includes_model_in_plan_and_handles_custom(self):
        hermes_dir = self.tmp_path / ".hermes"
        hermes_dir.mkdir(parents=True, exist_ok=True)
        conf_path = hermes_dir / "config.yaml"
        conf_path.write_text("model:\n  provider: custom\n  default: qwen3.8-flash-next\n")

        stderr_msg = "No account usage available for provider 'custom'\n"
        mock_proc = MagicMock(returncode=1, stdout="", stderr=stderr_msg)
        with patch("subprocess.run", return_value=mock_proc):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "custom (qwen3.8-flash-next)")
            self.assertEqual(res["used_percent"], 0.0)

        # When error contains 'login' or 'auth', custom endpoint must still be HEALTHY
        mock_proc_auth = MagicMock(returncode=1, stdout="", stderr="authentication error from proxy")
        with patch("subprocess.run", return_value=mock_proc_auth):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "custom (qwen3.8-flash-next)")

    def test_collect_hermes_quota_reports_sqlite_context_and_activity_usage_for_custom_provider(self):
        import sqlite3, time
        hermes_dir = self.tmp_path / ".hermes"
        hermes_dir.mkdir(parents=True, exist_ok=True)
        (hermes_dir / "config.yaml").write_text(
            "model:\n  provider: custom\n  default: qwen3.8-flash-next\n  base_url: http://10.77.2.191:8001/v1\n"
        )
        db_path = hermes_dir / "state.db"
        now = time.time()
        conn = sqlite3.connect(db_path)
        conn.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT,
                model TEXT,
                model_config TEXT,
                title TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                last_activity_at REAL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                api_call_count INTEGER DEFAULT 0
            )
        """)
        conn.execute(
            """INSERT INTO sessions
               (id, source, model, model_config, title, started_at, ended_at, last_activity_at, input_tokens, output_tokens, api_call_count)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "20261027_100216_7356ba43",
                "whatsapp",
                "qwen3.8-flash-next",
                json.dumps({"_usage_anchor": {"prompt_tokens": 127040, "completion_tokens": 226}}),
                "Gateway Session",
                now - 7200,
                None,
                now - 300,
                18821901,
                574471,
                1227,
            ),
        )
        conn.execute(
            """INSERT INTO sessions
               (id, source, model, model_config, title, started_at, ended_at, last_activity_at, input_tokens, output_tokens, api_call_count)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "20261027_114245_07081f",
                "cli",
                "qwen3.8-flash-next",
                json.dumps({"_usage_anchor": {"prompt_tokens": 51381, "completion_tokens": 87}}),
                "CLI Session",
                now - 86400,
                None,
                now - 3600,
                7062801,
                949979,
                803,
            ),
        )
        conn.commit()
        conn.close()

        stderr_msg = "No account usage available for provider 'custom': the provider has no usage endpoint.\n"
        mock_proc = MagicMock(returncode=1, stdout="", stderr=stderr_msg)
        with patch("subprocess.run", return_value=mock_proc):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "custom (qwen3.8-flash-next)")
            self.assertGreater(res["used_percent"], 0.0)
            self.assertAlmostEqual(res["used_percent"], 24.3, places=1)
            self.assertGreaterEqual(len(res["windows"]), 2)
            for w in res["windows"]:
                self.assertIn("group", w)
                self.assertIn("window_minutes", w)
                self.assertIn("used_percent", w)
                self.assertIsInstance(w["window_minutes"], int)

    def test_collect_hermes_quota_normalizes_usage_snapshot_document_windows(self):
        snapshot_json = json.dumps({
            "provider": "openai-codex",
            "source": "usage_api",
            "title": "Account limits",
            "plan": "Pro",
            "fetched_at": "2026-11-10T07:00:00+00:00",
            "windows": [
                {
                    "label": "Session",
                    "used_percent": 15.0,
                    "resets_at": "2026-11-10T12:00:00+00:00",
                    "detail": None,
                },
                {
                    "label": "Weekly",
                    "used_percent": 42.0,
                    "resets_at": "2026-11-16T06:00:00+00:00",
                    "detail": None,
                },
            ],
            "details": [],
            "unavailable_reason": None,
        })
        mock_proc = MagicMock(returncode=0, stdout=snapshot_json, stderr="")
        with patch("subprocess.run", return_value=mock_proc):
            res = self.pulse_module.collect_hermes_quota(home_dir=self.tmp_path)
            self.assertEqual(res["state"], "HEALTHY")
            self.assertEqual(res["plan"], "Pro")
            self.assertEqual(res["used_percent"], 42.0)
            self.assertEqual(res["resets_at"], "2026-11-10T12:00:00+00:00")
            self.assertEqual(len(res["windows"]), 2)
            self.assertEqual(res["windows"][0]["group"], "Session")
            self.assertEqual(res["windows"][0]["window_minutes"], 300)
            self.assertEqual(res["windows"][1]["group"], "Weekly")
            self.assertEqual(res["windows"][1]["window_minutes"], 10080)

    def test_collect_terminal_agents_hermes_session_and_fallback(self):
        hermes_dir = self.tmp_path / ".hermes"
        hermes_dir.mkdir(parents=True, exist_ok=True)
        db_path = hermes_dir / "state.db"

        import sqlite3
        conn = sqlite3.connect(db_path)
        conn.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                title TEXT,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                started_at REAL NOT NULL
            )
        """)
        conn.execute(
            "INSERT INTO sessions (id, model, title, input_tokens, output_tokens, started_at) VALUES (?, ?, ?, ?, ?, ?)",
            ("hermes-sess-42", "qwen3.8-flash-next", "Refactor Core", 5000, 1200, 100.0)
        )
        conn.commit()
        conn.close()

        # 1. Herdr agent matched in state.db
        herdr_agents_cache = self.tmp_path / ".local" / "state" / "msam-host-agent" / "agents.json"
        herdr_agents_cache.parent.mkdir(parents=True, exist_ok=True)
        agents_data = {
            "sessions": [
                {
                    "agents": [
                        {
                            "pane_id": "%1",
                            "agent": "hermes",
                            "name": "hermes-agent",
                            "agent_session": {"value": "hermes-sess-42"},
                            "agent_status": "active",
                            "cwd": "/home/user/project"
                        },
                        {
                            "pane_id": "%2",
                            "agent": "hermes",
                            "name": "terminal",
                            "agent_session": {"value": "unknown-sess"},
                            "terminal_title": "Fix Telemetry · qwen3.8-flash-next · /workspace",
                            "agent_status": "active",
                            "cwd": "/workspace"
                        }
                    ]
                }
            ]
        }
        herdr_agents_cache.write_text(json.dumps(agents_data))

        terminals = self.pulse_module.collect_terminal_agents(home_dir=self.tmp_path)
        self.assertEqual(len(terminals), 2)

        # Matched agent
        t1 = terminals[0]
        self.assertEqual(t1["provider"], "hermes")
        self.assertEqual(t1["model"], "qwen3.8-flash-next")
        self.assertEqual(t1["session_tokens"], 6200)
        self.assertEqual(t1["name"], "Refactor Core")
        self.assertEqual(t1["transcript_path"], "hermes:hermes-sess-42")

        # Fallback regex agent
        t2 = terminals[1]
        self.assertEqual(t2["provider"], "hermes")
        self.assertEqual(t2["model"], "qwen3.8-flash-next")
        self.assertEqual(t2["name"], "Fix Telemetry")

    def test_analyze_session_task_hermes_queries_db_and_invokes_cli(self):
        hermes_dir = self.tmp_path / ".hermes"
        hermes_dir.mkdir(parents=True, exist_ok=True)
        db_path = hermes_dir / "state.db"

        import sqlite3
        conn = sqlite3.connect(db_path)
        conn.execute("""
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT
            )
        """)
        conn.execute("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
                     ("sess-99", "user", "Fix crash and fatal error in pipeline"))
        conn.execute("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
                     ("sess-99", "assistant", "Looking into the fatal error traceback"))
        conn.commit()
        conn.close()

        # Live Hermes CLI invocation
        cli_response = '{"model": "qwen3.8-flash-next", "effort": "high", "summary": "Investigating crash"}'
        mock_proc = MagicMock(returncode=0, stdout=cli_response)
        with patch("subprocess.run", return_value=mock_proc) as mock_run:
            analysis = self.pulse_module.analyze_session_task(
                transcript_path="hermes:sess-99",
                target_provider="hermes",
                home_dir=self.tmp_path
            )
            self.assertTrue(mock_run.called)
            called_cmd = mock_run.call_args[0][0]
            self.assertEqual(called_cmd[0], "hermes")
            self.assertEqual(called_cmd[1:3], ["chat", "-q"])
            self.assertIn("--oneshot", called_cmd)
            self.assertIn("-Q", called_cmd)
            self.assertEqual(analysis["model"], "qwen3.8-flash-next")
            self.assertEqual(analysis["effort"], "high")
            self.assertTrue(analysis["is_complex"])

        # Fallback heuristic when CLI fails
        conf_path = hermes_dir / "config.yaml"
        conf_path.write_text("model:\n  provider: custom\n  default: my-custom-model\n")
        with patch("subprocess.run", side_effect=FileNotFoundError):
            analysis = self.pulse_module.analyze_session_task(
                transcript_path="hermes:sess-99",
                target_provider="hermes",
                home_dir=self.tmp_path
            )
            self.assertEqual(analysis["model"], "my-custom-model")
            self.assertEqual(analysis["effort"], "high")
            self.assertTrue(analysis["is_complex"])

    def test_sample_provider_pulse_resolves_claude_candidate_paths(self):
        claude_custom_dir = self.tmp_path / "custom_claude"
        claude_custom_dir.mkdir(parents=True)
        creds = claude_custom_dir / ".credentials.json"
        creds.write_text(json.dumps({
            "claudeAiOauth": {
                "accessToken": "custom-token",
                "subscriptionType": "max",
                "expiresAt": 9999999999000,
                "refreshTokenExpiresAt": 9999999999000
            }
        }))

        with patch.object(self.pulse_module, "get_installed_herdr_integrations", return_value={"claude"}), \
             patch.object(self.pulse_module, "collect_claude_quota", return_value={"state": "HEALTHY", "used_percent": 0.0}) as mock_collect, \
             patch.object(self.pulse_module, "collect_terminal_agents", return_value=[]):
            res = self.pulse_module.collect_provider_telemetry(
                home_dir=self.tmp_path,
                env={"CLAUDE_CONFIG_DIR": str(claude_custom_dir)}
            )
            self.assertEqual(mock_collect.call_args[0][0], creds)
            self.assertEqual(res["providers"]["claude_code"]["state"], "HEALTHY")

    def test_provider_pulse_file_has_shebang_and_main_runner(self):
        target_path = resources_dir / "msam-provider-pulse.py"
        first_line = target_path.read_text(encoding="utf-8").splitlines()[0]
        self.assertEqual(first_line, "#!/usr/bin/env python3")

        import subprocess
        proc = subprocess.run([sys.executable, str(target_path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0)
        data = json.loads(proc.stdout)
        self.assertIn("providers", data)
        self.assertIn("terminal_agents", data)
        self.assertIn("installed_integrations", data)


if __name__ == '__main__':
    unittest.main()
