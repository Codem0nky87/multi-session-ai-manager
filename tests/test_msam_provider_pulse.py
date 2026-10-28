import json
from pathlib import Path
from unittest.mock import MagicMock, patch
import pytest

# Target module to test (will be created in Resources/msam-provider-pulse.py)
import sys
resources_dir = Path(__file__).resolve().parent.parent / "app" / "MultiSessionAIManager" / "Resources"
sys.path.insert(0, str(resources_dir))

import importlib.util

@pytest.fixture
def pulse_module():
    target_path = resources_dir / "msam-provider-pulse.py"
    spec = importlib.util.spec_from_file_location("msam_provider_pulse", target_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_collect_claude_quota_parses_usage_and_respects_cache(tmp_path, pulse_module):
    creds_file = tmp_path / ".credentials.json"
    cache_file = tmp_path / "claude_cache.json"
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

    with patch.object(pulse_module, "http_get_json") as mock_http:
        mock_http.return_value = (200, mock_usage_response, {})
        res1 = pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
        assert res1["state"] == "RATE_LIMITED"
        assert res1["used_percent"] == 100.0
        assert res1["plan"] == "max"
        assert res1["resets_at"] == "2026-10-28T17:00:00Z"
        assert mock_http.call_count == 1

        # Second call within cooldown must use cache without calling HTTP again
        res2 = pulse_module.collect_claude_quota(creds_file, cache_path=cache_file)
        assert res2["state"] == "RATE_LIMITED"
        assert res2["used_percent"] == 100.0
        assert mock_http.call_count == 1


def test_collect_codex_quota_parses_limits_and_reset_credits(tmp_path, pulse_module):
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

    with patch.object(pulse_module, "query_codex_app_server") as mock_query:
        mock_query.return_value = (limits_data, usage_data)
        res = pulse_module.collect_codex_quota()
        assert res["state"] == "HEALTHY"
        assert res["used_percent"] == 1.0
        assert res["plan"] == "pro"
        assert res["reset_credits"]["available_count"] == 2
        assert len(res["reset_credits"]["expires_at"]) == 2


def test_collect_antigravity_quota_parses_cli_output(pulse_module):
    mock_cli_output = """
    Gemini Models: 39% used, resets in 3d 21h (2026-11-01T07:29:52Z)
    Claude and GPT models: 0% used
    """
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(returncode=0, stdout=mock_cli_output)
        res = pulse_module.collect_antigravity_quota()
        assert res["state"] == "HEALTHY"
        assert res["used_percent"] == 39.0
        assert res["resets_at"] == "2026-11-01T07:29:52Z"


def test_collect_terminal_agents_matches_transcripts(tmp_path, pulse_module):
    # Set up mock codex session
    codex_session_dir = tmp_path / ".codex" / "sessions" / "2026" / "10"
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
        terminals = pulse_module.collect_terminal_agents(home_dir=tmp_path)
        assert len(terminals) == 1
        t = terminals[0]
        assert t["pane_id"] == "wD:p7"
        assert t["provider"] == "codex"
        assert t["model"] == "gpt-6.1-sol"
        assert t["session_tokens"] == 23082435
        assert Path(t["transcript_path"]).resolve() == transcript_file.resolve()
        assert not t["is_limit_reached"]


def test_analyze_session_task_selects_model_and_effort(tmp_path, pulse_module):
    transcript_file = tmp_path / "test-transcript.jsonl"
    transcript_file.write_text(
        json.dumps({"type": "user", "message": "Refactor architecture and build release binary with swift and python"}) + "\n" +
        json.dumps({"type": "assistant", "message": "Encountered compiler deadlock in build_app and requires full restructure"}) + "\n"
    )

    # For codex, complex task should pick gpt-6.1-sol with high effort
    recommendation = pulse_module.analyze_session_task(str(transcript_file), target_provider="codex")
    assert recommendation["model"] == "gpt-6.1-sol"
    assert recommendation["effort"] == "high"
    assert "summary" in recommendation
