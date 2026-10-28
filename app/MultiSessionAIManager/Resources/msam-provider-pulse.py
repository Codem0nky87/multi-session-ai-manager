"""Host telemetry collector for Provider Pulse quotas, terminal activity, and session task analysis.

Runs inside msam-host-agent on Linux and macOS using Python 3 standard library.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UUID_REGEX = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', re.I)
CACHE_COOLDOWN_SECONDS = 300


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def http_get_json(url: str, headers: dict[str, str] | None = None, timeout: float = 10.0) -> tuple[int, dict, dict]:
    """Execute an HTTP GET request using urllib, returning (status_code, body_json, response_headers)."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read().decode('utf-8')
            return resp.status, json.loads(data), dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', errors='replace')
        try:
            body = json.loads(raw)
        except Exception:
            body = {"error": raw}
        return e.code, body, dict(e.headers)
    except Exception as e:
        return 0, {"error": str(e)}, {}


def collect_claude_quota(credentials_path: Path | str, cache_path: Path | str | None = None, now: datetime | None = None) -> dict:
    """Read Claude subscription usage via Anthropic OAuth endpoint with a 5-minute cache cooldown."""
    creds_p = Path(credentials_path).expanduser()
    cache_p = Path(cache_path).expanduser() if cache_path else creds_p.parent / ".claude_usage_cache.json"

    # Check cache
    if cache_p.exists():
        try:
            cached = json.loads(cache_p.read_text(encoding='utf-8'))
            cached_at = cached.get("_cached_at", 0)
            if time.time() - cached_at < CACHE_COOLDOWN_SECONDS:
                clean = dict(cached)
                clean.pop("_cached_at", None)
                return clean
        except Exception:
            pass

    if not creds_p.exists():
        return {
            "state": "SIGN_IN_REQUIRED",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": None,
            "windows": [],
            "reset_credits": None,
        }

    try:
        auth_data = json.loads(creds_p.read_text(encoding='utf-8'))
        claude_oauth = auth_data.get("claudeAiOauth") or {}
        token = claude_oauth.get("accessToken")
        plan = claude_oauth.get("subscriptionType", "pro")
        expires_at = claude_oauth.get("expiresAt")
        if expires_at and expires_at <= time.time() * 1000:
            return {
                "state": "SIGN_IN_REQUIRED",
                "used_percent": 0.0,
                "resets_at": None,
                "plan": plan,
                "windows": [],
                "reset_credits": None,
            }
        if not token:
            return {
                "state": "SIGN_IN_REQUIRED",
                "used_percent": 0.0,
                "resets_at": None,
                "plan": plan,
                "windows": [],
                "reset_credits": None,
            }
    except Exception:
        return {
            "state": "UNAVAILABLE",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": None,
            "windows": [],
            "reset_credits": None,
        }

    status_code, body, _ = http_get_json(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
        },
        timeout=10.0,
    )

    if status_code in (401, 403):
        return {
            "state": "SIGN_IN_REQUIRED",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": plan,
            "windows": [],
            "reset_credits": None,
        }
    if status_code == 429:
        return {
            "state": "REFRESH_DELAYED",
            "used_percent": 100.0,
            "resets_at": None,
            "plan": plan,
            "windows": [],
            "reset_credits": None,
        }
    if status_code != 200:
        return {
            "state": "UNAVAILABLE",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": plan,
            "windows": [],
            "reset_credits": None,
        }

    # Parse response
    five_hour = body.get("five_hour") or {}
    seven_day = body.get("seven_day") or {}
    h5_util = float(five_hour.get("utilization", 0.0))
    d7_util = float(seven_day.get("utilization", 0.0))
    primary_util = max(h5_util, d7_util)
    resets_at = seven_day.get("resets_at") or five_hour.get("resets_at")
    state = "RATE_LIMITED" if primary_util >= 100.0 else "HEALTHY"

    windows = [
        {"group": "5-Hour Pool", "window_minutes": 300, "used_percent": h5_util, "resets_at": five_hour.get("resets_at")},
        {"group": "7-Day Quota", "window_minutes": 10080, "used_percent": d7_util, "resets_at": seven_day.get("resets_at")},
    ]

    result = {
        "state": state,
        "used_percent": primary_util,
        "resets_at": resets_at,
        "plan": plan,
        "windows": windows,
        "reset_credits": None,
    }

    try:
        cache_data = dict(result)
        cache_data["_cached_at"] = time.time()
        cache_p.parent.mkdir(parents=True, exist_ok=True)
        cache_p.write_text(json.dumps(cache_data), encoding='utf-8')
    except Exception:
        pass

    return result


def query_codex_app_server(codex_bin: str = "codex", timeout: float = 15.0) -> tuple[dict, dict]:
    """Execute stdio JSON-RPC handshake with codex app-server to read rate limits and usage."""
    proc = subprocess.Popen(
        [codex_bin, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    def send(msg: dict):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def receive(req_id: int) -> dict:
        while True:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("Codex app-server closed stream")
            event = json.loads(line)
            if event.get("id") == req_id:
                if "error" in event:
                    raise RuntimeError(event["error"])
                return event.get("result", {})

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "msam", "version": "2.4.1"}}})
        receive(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read"})
        limits = receive(2)
        send({"id": 3, "method": "account/usage/read"})
        usage = receive(3)
        return limits, usage
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()


def collect_codex_quota(codex_bin: str = "codex") -> dict:
    """Read Codex rate limits and reset credits."""
    try:
        limits, usage = query_codex_app_server(codex_bin=codex_bin)
    except Exception:
        return {
            "state": "UNAVAILABLE",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": "pro",
            "windows": [],
            "reset_credits": None,
        }

    rate_limits = limits.get("rateLimits", [])
    if isinstance(rate_limits, dict):
        primary = rate_limits.get("primary") or {}
        resets_val = primary.get("resetsAt")
        if isinstance(resets_val, (int, float)):
            resets_iso = datetime.fromtimestamp(resets_val, timezone.utc).isoformat()
        else:
            resets_iso = resets_val
        plan_type = rate_limits.get("planType", "pro")
        rate_limits = [{
            "group": rate_limits.get("limitId", "codex"),
            "usedPercent": float(primary.get("usedPercent", 0.0)),
            "windowMinutes": primary.get("windowDurationMins", 10080),
            "resetsAt": resets_iso,
            "planType": plan_type,
        }]

    used_percent = 0.0
    resets_at = None
    windows = []
    plan = usage.get("plan", "pro")

    for rl in rate_limits:
        if isinstance(rl, dict):
            util = float(rl.get("usedPercent", 0.0))
            used_percent = max(used_percent, util)
            resets = rl.get("resetsAt")
            if isinstance(resets, (int, float)):
                resets = datetime.fromtimestamp(resets, timezone.utc).isoformat()
            if resets and not resets_at:
                resets_at = resets
            if rl.get("planType"):
                plan = rl["planType"]
            windows.append({
                "group": rl.get("group", "codex"),
                "window_minutes": rl.get("windowMinutes", 10080),
                "used_percent": util,
                "resets_at": resets,
            })

    state = "RATE_LIMITED" if used_percent >= 100.0 else "HEALTHY"
    reset_credits_raw = limits.get("rateLimitResetCredits") or usage.get("resetCredits") or {}
    reset_credits = None
    if reset_credits_raw:
        expires_at_list = []
        for c in reset_credits_raw.get("credits", []):
            exp = c.get("expiresAt")
            if isinstance(exp, (int, float)):
                expires_at_list.append(datetime.fromtimestamp(exp, timezone.utc).isoformat())
            elif isinstance(exp, str):
                expires_at_list.append(exp)
        if not expires_at_list and "expiresAt" in reset_credits_raw:
            raw_exp = reset_credits_raw.get("expiresAt")
            expires_at_list = [raw_exp] if isinstance(raw_exp, str) else list(raw_exp)
        reset_credits = {
            "available_count": int(reset_credits_raw.get("availableCount", 0)),
            "expires_at": expires_at_list,
        }

    return {
        "state": state,
        "used_percent": used_percent,
        "resets_at": resets_at,
        "plan": plan,
        "windows": windows,
        "reset_credits": reset_credits,
    }


def collect_antigravity_quota(agy_bin: str = "agy") -> dict:
    """Query Antigravity CLI quota using agy -p /usage."""
    try:
        res = subprocess.run([agy_bin, "-p", "/usage"], capture_output=True, text=True, timeout=12)
        if res.returncode != 0:
            return {"state": "UNAVAILABLE", "used_percent": 0.0, "resets_at": None, "windows": []}
        out = res.stdout
    except Exception:
        return {"state": "UNAVAILABLE", "used_percent": 0.0, "resets_at": None, "windows": []}

    used_percent = 0.0
    resets_at = None
    windows = []

    # Parse pool lines like "Gemini Models: 39% used, resets in 3d 21h (2026-11-01T07:29:52Z)"
    for line in out.splitlines():
        match = re.search(r'([^:]+):\s*([\d\.]+)%\s*used', line)
        if match:
            group = match.group(1).strip()
            util = float(match.group(2))
            used_percent = max(used_percent, util)
            time_match = re.search(r'\(([\d\-T:]+Z)\)', line)
            line_resets = time_match.group(1) if time_match else None
            if line_resets and not resets_at:
                resets_at = line_resets
            windows.append({
                "group": group,
                "window_minutes": 10080,
                "used_percent": util,
                "resets_at": line_resets,
            })

    state = "RATE_LIMITED" if used_percent >= 100.0 else "HEALTHY"
    return {
        "state": state,
        "used_percent": used_percent,
        "resets_at": resets_at,
        "plan": "standard",
        "windows": windows,
        "reset_credits": None,
    }


def collect_hermes_quota(hermes_bin: str = "hermes") -> dict:
    """Query Hermes usage."""
    try:
        res = subprocess.run([hermes_bin, "usage"], capture_output=True, text=True, timeout=8)
        out = res.stdout if res.returncode == 0 else ""
    except Exception:
        out = ""

    return {
        "state": "HEALTHY",
        "used_percent": 0.0,
        "resets_at": None,
        "plan": "custom",
        "windows": [],
        "reset_credits": None,
    }


def collect_terminal_agents(home_dir: Path | str | None = None, herdr_bin: str = "herdr") -> list[dict]:
    """Discover active Herdr agents and correlate their transcript paths and metrics."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    try:
        res = subprocess.run([herdr_bin, "agent", "list"], capture_output=True, text=True, timeout=5)
        if res.returncode != 0:
            return []
        agents = json.loads(res.stdout).get("result", {}).get("agents", [])
    except Exception:
        return []

    # Build transcript index for codex and claude
    index: dict[tuple[str, str], Path] = {}
    for provider, root in [('codex', home / '.codex/sessions'), ('claude', home / '.claude/projects'), ('claude_code', home / '.claude/projects')]:
        if root.exists():
            for p in root.rglob("*.jsonl"):
                match = UUID_REGEX.search(p.stem)
                if match:
                    index[(provider, match.group().lower())] = p

    terminals = []
    for a in agents:
        agent_type = (a.get("agent") or "").lower()
        if agent_type in ('claude', 'claude_code'):
            norm_provider = 'claude_code'
        elif agent_type in ('codex',):
            norm_provider = 'codex'
        elif agent_type in ('agy', 'antigravity'):
            norm_provider = 'antigravity'
        elif agent_type in ('hermes',):
            norm_provider = 'hermes'
        else:
            norm_provider = agent_type

        session_id = ((a.get("agent_session") or {}).get("value") or "").lower()
        transcript_path = ""
        model = None
        session_tokens = None

        matched_p = index.get((norm_provider, session_id)) or index.get((agent_type, session_id))
        if matched_p and matched_p.exists():
            transcript_path = str(matched_p.resolve())
            try:
                # Read last 256KB to quickly extract model and token count
                with matched_p.open('rb') as f:
                    f.seek(max(0, matched_p.stat().st_size - 256 * 1024))
                    for line in f.read().splitlines():
                        try:
                            ev = json.loads(line)
                            if norm_provider == 'codex':
                                if ev.get("type") == "turn_context" and "model" in ev.get("payload", {}):
                                    model = ev["payload"]["model"]
                                if ev.get("type") == "event_msg" and ev.get("payload", {}).get("type") == "token_count":
                                    info = ev["payload"].get("info", {})
                                    session_tokens = (info.get("total_token_usage") or {}).get("total_tokens")
                            elif norm_provider == 'claude_code':
                                msg = ev.get("message") or {}
                                if "model" in msg:
                                    model = msg["model"]
                                usage = msg.get("usage") or {}
                                if usage:
                                    session_tokens = sum(usage.values())
                        except Exception:
                            continue
            except Exception:
                pass

        status = a.get("agent_status", "idle")
        is_limit_reached = (status == "blocked")

        terminals.append({
            "pane_id": a.get("pane_id", ""),
            "tab_id": a.get("tab_id", ""),
            "name": a.get("name") or a.get("pane_id", ""),
            "provider": norm_provider,
            "project": Path(a.get("foreground_cwd") or a.get("cwd") or "").name,
            "state": status,
            "model": model,
            "session_tokens": session_tokens,
            "transcript_path": transcript_path,
            "is_limit_reached": is_limit_reached,
        })

    return terminals


def analyze_session_task(transcript_path: str, target_provider: str = "codex", home_dir: Path | str | None = None) -> dict:
    """Analyze a previous session transcript to determine task complexity and recommend optimal model and effort."""
    p = Path(transcript_path).expanduser() if transcript_path else None
    content = ""
    if p and p.exists():
        try:
            with p.open('r', encoding='utf-8', errors='replace') as f:
                lines = f.readlines()
                # Examine last 50 lines of interaction
                content = "\n".join(lines[-50:])
        except Exception:
            pass

    content_lower = content.lower()
    # Assess task complexity
    complex_indicators = [
        "error", "failed", "deadlock", "timeout", "refactor", "architectur",
        "exception", "traceback", "fatal", "restructure", "compile", "bug", "crash"
    ]
    complexity_score = sum(1 for word in complex_indicators if word in content_lower)
    is_complex = complexity_score >= 2 or len(content) > 5000

    target = target_provider.lower().replace("-", "_")

    if "codex" in target:
        model = "gpt-6.1-sol"
        effort = "high" if is_complex else "medium"
    elif "claude" in target:
        model = "claude-3-7-sonnet"
        effort = "high" if is_complex else "medium"
    elif "anti" in target or "agy" in target:
        model = "gemini-2.5-pro" if is_complex else "gemini-2.5-flash"
        effort = "high" if is_complex else "medium"
    else:
        model = "qwen3.8-flash-next"
        effort = "medium"

    summary = "High-complexity task requiring deep reasoning" if is_complex else "Standard task verification"

    return {
        "model": model,
        "effort": effort,
        "is_complex": is_complex,
        "summary": summary,
    }


def collect_provider_telemetry(home_dir: Path | str | None = None) -> dict:
    """Main entrypoint called by msam-host-agent to sample provider quotas and terminal sessions."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    claude_creds = home / ".claude" / ".credentials.json"

    claude = collect_claude_quota(claude_creds)
    codex = collect_codex_quota()
    antigravity = collect_antigravity_quota()
    hermes = collect_hermes_quota()
    terminals = collect_terminal_agents(home_dir=home)

    return {
        "providers": {
            "claude_code": claude,
            "codex": codex,
            "antigravity": antigravity,
            "hermes": hermes,
        },
        "terminal_agents": terminals,
    }
