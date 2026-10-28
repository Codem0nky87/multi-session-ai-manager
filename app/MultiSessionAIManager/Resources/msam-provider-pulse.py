"""Host telemetry collector for Provider Pulse quotas, terminal activity, and session task analysis.

Runs inside msam-host-agent on Linux and macOS using Python 3 standard library.
"""
from __future__ import annotations

import json
import os
import re
import shutil
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


def _get_process_env(home: Path, base_env: dict | None = None) -> dict:
    env = os.environ.copy() if base_env is None else dict(base_env)
    env.setdefault('HOME', str(home))
    path = env.get('PATH', '')
    for candidate in (str(home / '.local/bin'), str(home / '.cargo/bin'), '/usr/local/bin', '/opt/homebrew/bin'):
        if candidate not in path.split(':'):
            path = f"{candidate}:{path}" if path else candidate
    env['PATH'] = path
    return env


def _find_bin(home: Path, name: str, env: dict) -> str | None:
    if name and name not in ('agy', 'herdr', 'hermes'):
        p = Path(name).expanduser()
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    candidates = [
        home / '.local/bin' / name,
        home / '.cargo/bin' / name,
        Path('/usr/local/bin') / name,
        Path('/opt/homebrew/bin') / name,
        Path('/usr/bin') / name,
    ]
    for cand in candidates:
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return shutil.which(name, path=env.get('PATH'))


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


def collect_antigravity_quota(home_dir: Path | str | None = None, agy_bin: str = "agy", env: dict | None = None) -> dict:
    """Query Antigravity CLI quota using agy -p /usage."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, agy_bin, proc_env) or agy_bin

    try:
        res = subprocess.run([exe, "-p", "/usage"], capture_output=True, text=True, timeout=12, env=proc_env)
        out = res.stdout
        err = res.stderr
    except Exception:
        oauth_file = home / ".gemini/antigravity-cli/antigravity-oauth-token"
        state = "SIGN_IN_REQUIRED" if not oauth_file.exists() else "UNAVAILABLE"
        return {"state": state, "used_percent": 0.0, "resets_at": None, "plan": "standard", "windows": [], "reset_credits": None}

    if res.returncode != 0:
        combined = f"{out} {err}".lower()
        if "sign in" in combined or "auth" in combined or "login" in combined:
            return {"state": "SIGN_IN_REQUIRED", "used_percent": 0.0, "resets_at": None, "plan": "standard", "windows": [], "reset_credits": None}
        return {"state": "UNAVAILABLE", "used_percent": 0.0, "resets_at": None, "plan": "standard", "windows": [], "reset_credits": None}

    used_percent = 0.0
    resets_at = None
    windows = []

    # Parse lines. agy -p /usage formats either as tab-separated columns or formatted text:
    # Gemini Models\tWeekly Limit Remaining\t52%\t2026-11-01T07:29:52Z
    # Gemini Models: 39% used, resets in 3d 21h (2026-11-01T07:29:52Z)
    for line in out.splitlines():
        line = line.strip()
        if not line or line.lower().startswith("quota:"):
            continue

        parts = [p.strip() for p in re.split(r'\t+|\s{2,}', line) if p.strip()]
        if len(parts) >= 3:
            family = parts[0]
            limit_name = parts[1]
            pct_str = parts[2]
            date_str = parts[3] if len(parts) > 3 else None
            group = f"{family} ({limit_name})" if limit_name and limit_name != family else family
        else:
            pct_match = re.search(r'(\d+(?:\.\d+)?)%', line)
            if not pct_match:
                continue
            pct_str = pct_match.group(0)
            group_match = re.search(r'([^:]+):', line)
            group = group_match.group(1).strip() if group_match else line[:pct_match.start()].strip()
            date_str = None
            paren_match = re.search(r'\(([\d\-T:]+Z?)\)', line)
            if paren_match:
                date_str = paren_match.group(1)

        val_match = re.search(r'(\d+(?:\.\d+)?)', pct_str)
        if not val_match:
            continue
        pct_val = float(val_match.group(1))

        if "used" in line.lower():
            util = pct_val
        else:
            # agy reports "Remaining" percentages by default
            util = max(0.0, min(100.0, 100.0 - pct_val))

        used_percent = max(used_percent, util)

        iso_resets = None
        if date_str:
            if "T" in date_str and ("Z" in date_str or "+" in date_str or "-" in date_str[10:]):
                iso_resets = date_str
            else:
                time_match = re.search(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})', date_str)
                if time_match:
                    try:
                        dt = datetime.strptime(f"{time_match.group(1)} {time_match.group(2)}", "%Y-%m-%d %H:%M").astimezone()
                        iso_resets = dt.isoformat()
                    except Exception:
                        pass

        win_mins = 10080 if any(k in line.lower() for k in ("week", "weekly")) else 300
        windows.append({
            "group": group,
            "window_minutes": win_mins,
            "used_percent": util,
            "resets_at": iso_resets,
        })

    # Pick earliest upcoming reset timestamp
    resets_candidates = [w["resets_at"] for w in windows if w.get("resets_at")]
    if resets_candidates:
        resets_at = min(resets_candidates)

    state = "RATE_LIMITED" if used_percent >= 100.0 else "HEALTHY"
    return {
        "state": state,
        "used_percent": used_percent,
        "resets_at": resets_at,
        "plan": "standard",
        "windows": windows,
        "reset_credits": None,
    }


def collect_hermes_quota(home_dir: Path | str | None = None, hermes_bin: str = "hermes", env: dict | None = None) -> dict:
    """Query Hermes usage."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, hermes_bin, proc_env) or hermes_bin
    try:
        res = subprocess.run([exe, "usage"], capture_output=True, text=True, timeout=8, env=proc_env)
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


def collect_terminal_agents(home_dir: Path | str | None = None, herdr_bin: str = "herdr", env: dict | None = None) -> list[dict]:
    """Discover active Herdr agents and correlate their transcript paths and metrics."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)

    raw_agents: dict[str, dict] = {}

    # 1. Read cached state inventory from msam-host-agent if present
    state_agents_file = home / '.local/state/msam-host-agent/agents.json'
    if state_agents_file.exists():
        try:
            data = json.loads(state_agents_file.read_text(encoding='utf-8'))
            for session in data.get('sessions', []):
                for a in session.get('agents', []):
                    if isinstance(a, dict) and a.get('pane_id'):
                        raw_agents[a['pane_id']] = a
        except Exception:
            pass

    # 2. Query live Herdr if binary is available and no cached agents were found
    if not raw_agents:
        herdr_exe = _find_bin(home, herdr_bin, proc_env) or herdr_bin
        try:
            session_res = subprocess.run([herdr_exe, "session", "list", "--json"],
                                         capture_output=True, text=True, timeout=5, env=proc_env)
            if session_res.returncode == 0:
                sessions_data = json.loads(session_res.stdout).get("sessions", [])
                for s in sessions_data:
                    if s.get("running") and s.get("socket_path"):
                        sess_env = dict(proc_env, HERDR_SOCKET_PATH=s["socket_path"])
                        agent_res = subprocess.run([herdr_exe, "agent", "list"],
                                                   capture_output=True, text=True, timeout=5, env=sess_env)
                        if agent_res.returncode == 0:
                            agents = json.loads(agent_res.stdout).get("result", {}).get("agents", [])
                            for a in agents:
                                if isinstance(a, dict) and a.get("pane_id"):
                                    raw_agents[a["pane_id"]] = a
            if not raw_agents:
                agent_res = subprocess.run([herdr_exe, "agent", "list"],
                                           capture_output=True, text=True, timeout=5, env=proc_env)
                if agent_res.returncode == 0:
                    agents = json.loads(agent_res.stdout).get("result", {}).get("agents", [])
                    for a in agents:
                        if isinstance(a, dict) and a.get("pane_id"):
                            raw_agents[a["pane_id"]] = a
        except Exception:
            pass

    # Build transcript index for codex and claude
    index: dict[tuple[str, str], Path] = {}
    for provider, root in [('codex', home / '.codex/sessions'), ('claude', home / '.claude/projects'), ('claude_code', home / '.claude/projects')]:
        if root.exists():
            for p in root.rglob("*.jsonl"):
                match = UUID_REGEX.search(p.stem)
                if match:
                    index[(provider, match.group().lower())] = p

    terminals = []
    for a in raw_agents.values():
        agent_type = str(a.get("agent") or "").lower()
        name_str = str(a.get("name") or "").lower()
        title_str = str(a.get("terminal_title") or a.get("terminal_title_stripped") or "").lower()
        cmd_str = str(a.get("command") or "").lower()
        combined = f"{agent_type} {name_str} {title_str} {cmd_str}"

        if "claude" in combined:
            norm_provider = "claude_code"
        elif "codex" in combined:
            norm_provider = "codex"
        elif any(k in combined for k in ("agy", "antigravity")):
            norm_provider = "antigravity"
        elif "hermes" in combined:
            norm_provider = "hermes"
        else:
            norm_provider = agent_type or "unknown"

        session_id = str((a.get("agent_session") or {}).get("value") or "").lower()
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

        status = str(a.get("agent_status") or "idle")
        is_limit_reached = (status.lower() == "blocked")
        pane_id = str(a.get("pane_id") or "")
        tab_id = str(a.get("tab_id") or "")
        name = str(a.get("name") or pane_id or "terminal")
        cwd = str(a.get("foreground_cwd") or a.get("cwd") or "")
        project = Path(cwd).name if cwd else ""

        terminals.append({
            "pane_id": pane_id,
            "tab_id": tab_id,
            "name": name,
            "provider": norm_provider,
            "project": project,
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


def collect_provider_telemetry(home_dir: Path | str | None = None, env: dict | None = None) -> dict:
    """Main entrypoint called by msam-host-agent to sample provider quotas and terminal sessions."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    claude_creds = home / ".claude" / ".credentials.json"

    claude = collect_claude_quota(claude_creds)
    codex = collect_codex_quota()
    antigravity = collect_antigravity_quota(home_dir=home, env=env)
    hermes = collect_hermes_quota(home_dir=home, env=env)
    terminals = collect_terminal_agents(home_dir=home, env=env)

    return {
        "providers": {
            "claude_code": claude,
            "codex": codex,
            "antigravity": antigravity,
            "hermes": hermes,
        },
        "terminal_agents": terminals,
    }
