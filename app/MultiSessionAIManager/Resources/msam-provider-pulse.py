#!/usr/bin/env python3
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
import threading
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


MAX_BACKOFF_SECONDS = 3600


def _read_usage_cache(cache_p: Path) -> dict:
    try:
        cached = json.loads(cache_p.read_text(encoding='utf-8'))
        return cached if isinstance(cached, dict) else {}
    except Exception:
        return {}


def _write_usage_cache(cache_p: Path, result: dict, cooldown: float, failures: int = 0,
                       last_good: dict | None = None) -> None:
    try:
        cache_data = dict(result, _cached_at=time.time(), _cooldown=cooldown, _failures=failures)
        if last_good is not None:
            cache_data["_last_good"] = last_good
        cache_p.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache_p.with_name(cache_p.name + ".tmp")
        temporary.write_text(json.dumps(cache_data), encoding='utf-8')
        os.replace(temporary, cache_p)
    except Exception:
        pass


def _retry_after_seconds(headers: dict) -> float:
    value = next((v for k, v in (headers or {}).items() if k.lower() == "retry-after"), None)
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        return 0.0


def _claude_pricing_tier(model: str | None) -> dict[str, float]:
    """Return per-million-token USD rates for a Claude model matching Claude Code's built-in catalog."""
    m = (model or "").lower()
    if "haiku-5-5" in m or "haiku-5.5" in m:
        return {"in": 0.1, "out": 0.5, "cw5": 0.125, "cw1h": 0.2, "cr": 0.01}
    if "haiku-4" in m:
        return {"in": 1.0, "out": 5.0, "cw5": 1.25, "cw1h": 2.0, "cr": 0.1}
    if "haiku" in m:
        return {"in": 0.8, "out": 4.0, "cw5": 1.0, "cw1h": 1.6, "cr": 0.08}
    if "sonnet-5-5" in m or "sonnet-5.5" in m:
        return {"in": 2.0, "out": 10.0, "cw5": 2.5, "cw1h": 4.0, "cr": 0.1}
    if "sonnet-5" in m:
        return {"in": 2.0, "out": 10.0, "cw5": 2.5, "cw1h": 4.0, "cr": 0.2}
    if "sonnet" in m:
        return {"in": 3.0, "out": 15.0, "cw5": 3.75, "cw1h": 6.0, "cr": 0.3}
    if "opus-5-5" in m or "opus-5.5" in m:
        return {"in": 4.0, "out": 20.0, "cw5": 5.0, "cw1h": 8.0, "cr": 0.2}
    if any(k in m for k in ("opus-4-5", "opus-4-6", "opus-4-7", "opus-4-8", "opus-5")):
        return {"in": 5.0, "out": 25.0, "cw5": 6.25, "cw1h": 10.0, "cr": 0.5}
    if "opus" in m:
        return {"in": 15.0, "out": 75.0, "cw5": 18.75, "cw1h": 30.0, "cr": 1.5}
    return {"in": 4.0, "out": 20.0, "cw5": 5.0, "cw1h": 8.0, "cr": 0.2}


def _extract_claude_transcript_metrics(path: Path) -> tuple[str | None, int | None, float | None]:
    """Extract (model, session_tokens, session_cost_usd) from a Claude Code .jsonl transcript."""
    if not path.is_file():
        return None, None, None
    model: str | None = None
    cost_state_usd: float | None = None
    cost_state_tokens: int | None = None
    turn_tokens_by_id: dict[str, int] = {}
    turn_cost_by_id: dict[str, float] = {}
    post_cost_state_tokens: dict[str, int] = {}
    post_cost_state_usd: dict[str, float] = {}

    try:
        size = path.stat().st_size
        with path.open("rb") as f:
            if size > 2 * 1024 * 1024:
                f.seek(size - 2 * 1024 * 1024)
            raw_lines = f.read().splitlines()
        for idx, line in enumerate(raw_lines):
            if not line or (b'"cost-state"' not in line and b'"usage"' not in line and b'"model"' not in line):
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("type") == "cost-state":
                try:
                    cost_state_usd = float(ev.get("totalCostUSD") or 0.0)
                except (TypeError, ValueError):
                    pass
                model_usage = ev.get("modelUsage")
                if isinstance(model_usage, dict) and model_usage:
                    tok_sum = 0
                    best_model = None
                    best_cost = -1.0
                    for m_name, m_stats in model_usage.items():
                        if not isinstance(m_stats, dict):
                            continue
                        t = (
                            int(m_stats.get("inputTokens") or 0)
                            + int(m_stats.get("outputTokens") or 0)
                            + int(m_stats.get("cacheReadInputTokens") or 0)
                            + int(m_stats.get("cacheCreationInputTokens") or 0)
                        )
                        tok_sum += t
                        c = float(m_stats.get("costUSD") or 0.0)
                        if c > best_cost:
                            best_cost = c
                            best_model = str(m_name)
                    if tok_sum > 0:
                        cost_state_tokens = tok_sum
                    if best_model and not model:
                        model = best_model
                post_cost_state_tokens.clear()
                post_cost_state_usd.clear()
                continue

            msg = ev.get("message")
            if isinstance(msg, dict):
                if msg.get("model"):
                    model = str(msg["model"])
                usage = msg.get("usage")
                if isinstance(usage, dict):
                    in_tok = int(usage.get("input_tokens") or 0)
                    out_tok = int(usage.get("output_tokens") or 0)
                    cr_tok = int(usage.get("cache_read_input_tokens") or 0)
                    cw_tok = int(usage.get("cache_creation_input_tokens") or 0)
                    cc = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
                    cw_1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
                    cw_5m = max(0, cw_tok - cw_1h)
                    tot = in_tok + out_tok + cr_tok + cw_tok
                    if tot > 0:
                        rates = _claude_pricing_tier(model)
                        c_usd = (
                            in_tok * rates["in"]
                            + out_tok * rates["out"]
                            + cr_tok * rates["cr"]
                            + cw_5m * rates["cw5"]
                            + cw_1h * rates["cw1h"]
                        ) / 1_000_000.0
                        msg_id = str(msg.get("id") or ev.get("requestId") or ev.get("uuid") or f"line_{idx}")
                        turn_tokens_by_id[msg_id] = tot
                        turn_cost_by_id[msg_id] = c_usd
                        if cost_state_usd is not None:
                            post_cost_state_tokens[msg_id] = tot
                            post_cost_state_usd[msg_id] = c_usd
    except Exception:
        pass

    if cost_state_usd is not None:
        total_usd = cost_state_usd + sum(post_cost_state_usd.values())
        if cost_state_tokens is not None:
            total_tokens = cost_state_tokens + sum(post_cost_state_tokens.values())
        else:
            total_tokens = sum(turn_tokens_by_id.values())
        return model, (total_tokens if total_tokens > 0 else None), round(total_usd, 4)

    if turn_tokens_by_id:
        return model, sum(turn_tokens_by_id.values()), round(sum(turn_cost_by_id.values()), 4)

    return model, None, None


def _extract_codex_transcript_metrics(path: Path) -> tuple[str | None, int | None, float | None]:
    """Extract (model, session_tokens, session_cost_usd) from a Codex .jsonl transcript."""
    if not path.is_file():
        return None, None, None
    model: str | None = None
    session_tokens: int | None = None
    session_cost_usd: float | None = None
    try:
        size = path.stat().st_size
        with path.open("rb") as f:
            f.seek(max(0, size - 256 * 1024))
            for line in f.read().splitlines():
                if not line or (b'"turn_context"' not in line and b'"token_count"' not in line):
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if not isinstance(ev, dict):
                    continue
                payload = ev.get("payload")
                if not isinstance(payload, dict):
                    continue
                if ev.get("type") == "turn_context" and payload.get("model"):
                    model = str(payload["model"])
                elif ev.get("type") == "event_msg" and payload.get("type") == "token_count":
                    info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
                    tot_usage = info.get("total_token_usage") if isinstance(info.get("total_token_usage"), dict) else {}
                    tot_tok = int(tot_usage.get("total_tokens") or 0)
                    if tot_tok > 0:
                        session_tokens = tot_tok
                        in_tok = int(tot_usage.get("input_tokens") or 0)
                        cached_in = int(tot_usage.get("cached_input_tokens") or 0)
                        out_tok = int(tot_usage.get("output_tokens") or 0)
                        uncached_in = max(0, in_tok - cached_in)
                        session_cost_usd = round((uncached_in * 2.5 + cached_in * 0.25 + out_tok * 10.0) / 1_000_000.0, 4)
    except Exception:
        pass
    return model, session_tokens, session_cost_usd


def _collect_claude_api_spend(claude_dir: Path) -> tuple[float, float, float]:
    """Aggregate (spend_5h_usd, spend_7d_usd, spend_30d_usd) across Claude Code transcripts."""
    roots = [claude_dir / "projects"]
    try:
        if claude_dir.resolve() == (Path.home() / ".claude").resolve():
            vault_projects = Path("/run/woodhouse-machine-vault/agents/claude/projects")
            if vault_projects.is_dir():
                roots.append(vault_projects)
    except Exception:
        pass

    existing_roots = [r for r in roots if r.is_dir()]
    if not existing_roots:
        return 0.0, 0.0, 0.0

    now_ts = time.time()
    spend_5h = 0.0
    spend_7d = 0.0
    spend_30d = 0.0
    seen_stems: set[str] = set()

    for root in existing_roots:
        try:
            for p in root.rglob("*.jsonl"):
                try:
                    st = p.stat()
                except Exception:
                    continue
                if st.st_mtime < now_ts - 30 * 86400:
                    continue
                if p.stem in seen_stems:
                    continue
                seen_stems.add(p.stem)
                _, _, cost = _extract_claude_transcript_metrics(p)
                if cost and cost > 0:
                    if st.st_mtime >= now_ts - 5 * 3600:
                        spend_5h += cost
                    if st.st_mtime >= now_ts - 7 * 86400:
                        spend_7d += cost
                    spend_30d += cost
        except Exception:
            continue

    return round(spend_5h, 2), round(spend_7d, 2), round(spend_30d, 2)


def collect_claude_quota(credentials_path: Path | str, cache_path: Path | str | None = None, now: datetime | None = None) -> dict:
    """Read Claude subscription usage via Anthropic OAuth endpoint with a 5-minute cache cooldown.

    Read-only: Claude Code refreshes its own token under its refresh lock. Refreshing here
    would rotate the refresh token behind running Claude sessions and sign them out.
    Failures are cached too, with exponential backoff and Retry-After for throttling.
    """
    creds_p = Path(credentials_path).expanduser()
    cache_p = Path(cache_path).expanduser() if cache_path else creds_p.parent / ".claude_usage_cache.json"

    cached = _read_usage_cache(cache_p)
    has_spend_schema = cached.get("state") not in ("HEALTHY", "RATE_LIMITED") or "spend_5h_usd" in cached
    if has_spend_schema and time.time() - cached.get("_cached_at", 0) < cached.get("_cooldown", CACHE_COOLDOWN_SECONDS):
        return {k: v for k, v in cached.items() if not k.startswith("_")}
    last_good = cached.get("_last_good")
    if cached.get("state") in ("HEALTHY", "RATE_LIMITED"):
        last_good = {k: v for k, v in cached.items() if not k.startswith("_")}

    def status(state: str, plan: str | None) -> dict:
        return {"state": state, "used_percent": 0.0, "resets_at": None, "plan": plan,
                "windows": [], "reset_credits": None}

    try:
        claude_oauth = json.loads(creds_p.read_text(encoding='utf-8')).get("claudeAiOauth") or {}
    except FileNotFoundError:
        return status("SIGN_IN_REQUIRED", None)
    except Exception:
        return status("UNAVAILABLE", None)
    token = claude_oauth.get("accessToken")
    plan = claude_oauth.get("subscriptionType", "pro")
    expires_at = claude_oauth.get("expiresAt")
    if not token or (expires_at and expires_at <= time.time() * 1000):
        # Claude Code renews it the next time it runs; never make a request with it.
        return status("SIGN_IN_REQUIRED", plan)

    status_code, body, headers = http_get_json(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
        },
        timeout=10.0,
    )

    if status_code in (401, 403):
        result = status("SIGN_IN_REQUIRED", plan)
        _write_usage_cache(cache_p, result, CACHE_COOLDOWN_SECONDS, last_good=last_good)
        return result
    if status_code == 429 or status_code == 0 or status_code >= 500:
        failures = int(cached.get("_failures", 0)) + 1
        cooldown = max(min(MAX_BACKOFF_SECONDS, CACHE_COOLDOWN_SECONDS * 2 ** min(failures - 1, 4)),
                       _retry_after_seconds(headers))
        # Throttled usage reporting does not mean the subscription limit is exhausted.
        result = dict(last_good, state="REFRESH_DELAYED") if last_good else status("REFRESH_DELAYED", plan)
        _write_usage_cache(cache_p, result, cooldown, failures, last_good)
        return result
    if status_code != 200 or not isinstance(body, dict):
        result = status("UNAVAILABLE", plan)
        _write_usage_cache(cache_p, result, CACHE_COOLDOWN_SECONDS, last_good=last_good)
        return result

    # Parse response
    five_hour = body.get("five_hour") or {}
    seven_day = body.get("seven_day") or {}
    h5_util = float(five_hour.get("utilization", 0.0))
    d7_util = float(seven_day.get("utilization", 0.0))
    primary_util = max(h5_util, d7_util)
    resets_at = seven_day.get("resets_at") or five_hour.get("resets_at")
    state = "RATE_LIMITED" if primary_util >= 100.0 else "HEALTHY"

    spend_5h, spend_7d, spend_30d = _collect_claude_api_spend(creds_p.parent)

    windows = [
        {"group": "5-Hour Pool", "window_minutes": 300, "used_percent": h5_util, "resets_at": five_hour.get("resets_at")},
        {"group": "7-Day Quota", "window_minutes": 10080, "used_percent": d7_util, "resets_at": seven_day.get("resets_at")},
    ]

    # Extra usage beyond the subscription (e.g. a $200 monthly cap).
    def section(source, key) -> dict:
        value = source.get(key) if isinstance(source, dict) else None
        return value if isinstance(value, dict) else {}
    spend, extra_usage = section(body, "spend"), section(body, "extra_usage")
    limit, used = section(spend, "limit"), section(spend, "used")
    try:
        enabled = spend.get("enabled", extra_usage.get("is_enabled"))
        limit_minor = float(limit.get("amount_minor") or extra_usage.get("monthly_limit") or 0)
        used_minor = float(used.get("amount_minor", extra_usage.get("used_credits")) or 0)
        exponent = int(limit.get("exponent", extra_usage.get("decimal_places", 2)))
        if limit_minor > 0:
            limit_dollars = limit_minor / (10 ** exponent)
            used_dollars = used_minor / (10 ** exponent)
            if enabled:
                allowance_label = f"API Allowance (${used_dollars:,.2f} / ${limit_dollars:,.0f})"
            else:
                allowance_label = f"API Allowance (${used_dollars:,.2f} / ${limit_dollars:,.0f} · Out of credits)"
            windows.append({
                "group": allowance_label,
                "window_minutes": 43200,
                "used_percent": round(used_minor / limit_minor * 100.0, 1),
                "resets_at": None,
                "value_text": f"${used_dollars:,.2f}",
            })
    except (TypeError, ValueError, OverflowError):
        pass

    result = {
        "state": state,
        "used_percent": primary_util,
        "resets_at": resets_at,
        "plan": plan,
        "windows": windows,
        "reset_credits": None,
        "spend_5h_usd": spend_5h,
        "spend_7d_usd": spend_7d,
        "spend_30d_usd": spend_30d,
    }

    _write_usage_cache(cache_p, result, CACHE_COOLDOWN_SECONDS)
    return result


def query_codex_app_server(codex_bin: str = "codex", env: dict | None = None, timeout: float = 15.0) -> tuple[dict, dict]:
    """Execute stdio JSON-RPC handshake with codex app-server to read rate limits and usage."""
    proc = subprocess.Popen(
        [codex_bin, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )

    result_holder: dict[str, tuple[dict, dict]] = {}
    error_holder: dict[str, Exception] = {}

    def run_rpc():
        def send(msg: dict):
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.write(json.dumps(msg) + "\n")
                proc.stdin.flush()

        def receive(req_id: int) -> dict:
            while True:
                if not proc.stdout or proc.stdout.closed:
                    raise RuntimeError("Codex app-server closed stream")
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
            result_holder["data"] = (limits, usage)
        except Exception as exc:
            error_holder["error"] = exc

    worker = threading.Thread(target=run_rpc, daemon=True)
    worker.start()
    worker.join(timeout=timeout)

    try:
        if worker.is_alive():
            proc.kill()
            worker.join(timeout=2.0)
            raise TimeoutError(f"Codex app-server query timed out after {timeout}s")
        if "error" in error_holder:
            raise error_holder["error"]
        if "data" not in result_holder:
            raise RuntimeError("Codex app-server query failed to return data")
        return result_holder["data"]
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()


def collect_codex_quota(home_dir: Path | str | None = None, codex_bin: str = "codex", env: dict | None = None) -> dict:
    """Read Codex rate limits and reset credits."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, codex_bin, proc_env) or codex_bin
    try:
        limits, usage = query_codex_app_server(codex_bin=exe, env=proc_env, timeout=15.0)
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


def _fallback_antigravity_from_cli_usage(home: Path) -> dict | None:
    """Read cached Antigravity quota from ~/.hermes/provider-pulse/cli-usage/usage.json if available."""
    usage_file = home / ".hermes/provider-pulse/cli-usage/usage.json"
    if not usage_file.exists():
        return None
    try:
        data = json.loads(usage_file.read_text(encoding="utf-8"))
        ag = data.get("antigravity")
        if not isinstance(ag, dict):
            return None
        raw_windows = ag.get("windows")
        if not isinstance(raw_windows, list) or not raw_windows:
            return None
        windows = []
        used_percent = 0.0
        for w in raw_windows:
            if not isinstance(w, dict):
                continue
            util = round(max(0.0, min(100.0, float(w.get("used_percent") or 0.0))), 1)
            used_percent = max(used_percent, util)
            win_mins = int(w.get("window_minutes") or 300)
            windows.append({
                "group": str(w.get("group") or w.get("label") or "Quota"),
                "window_minutes": win_mins,
                "used_percent": util,
                "resets_at": w.get("resets_at"),
            })
        if not windows:
            return None
        resets_candidates = [w["resets_at"] for w in windows if w.get("resets_at")]
        resets_at = min(resets_candidates) if resets_candidates else None
        state = "RATE_LIMITED" if used_percent >= 100.0 else str(ag.get("state") or "HEALTHY")
        return {
            "state": state,
            "used_percent": used_percent,
            "resets_at": resets_at,
            "plan": str(ag.get("plan") or "standard"),
            "windows": windows,
            "reset_credits": None,
        }
    except Exception:
        return None


def collect_antigravity_quota(home_dir: Path | str | None = None, agy_bin: str = "agy", env: dict | None = None) -> dict:
    """Query Antigravity CLI quota using agy -p /usage."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, agy_bin, proc_env) or agy_bin

    try:
        res = subprocess.run(
            [exe, "-p", "/usage"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=4,
            env=proc_env,
        )
        out = res.stdout
        err = res.stderr
    except Exception:
        cached = _fallback_antigravity_from_cli_usage(home)
        if cached is not None:
            return cached
        oauth_file = home / ".gemini/antigravity-cli/antigravity-oauth-token"
        state = "SIGN_IN_REQUIRED" if not oauth_file.exists() else "UNAVAILABLE"
        return {"state": state, "used_percent": 0.0, "resets_at": None, "plan": "standard", "windows": [], "reset_credits": None}

    if res.returncode != 0:
        cached = _fallback_antigravity_from_cli_usage(home)
        if cached is not None:
            return cached
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


HERDR_HOOK_FALLBACKS = {
    "claude": ".claude/hooks/herdr-agent-state.sh",
    "codex": ".codex/herdr-agent-state.sh",
    "antigravity-cli": ".gemini/config/hooks/herdr-agent-state.sh",
    "hermes": ".hermes/plugins/herdr-agent-state/__init__.py",
    "copilot": ".copilot/hooks/herdr-agent-state.sh",
    "pi": ".pi/agent/extensions/herdr-agent-state.ts",
    "omp": ".omp/agent/extensions/herdr-omp-agent-state.ts",
}


def get_installed_herdr_integrations(home_dir: Path | str | None = None, herdr_bin: str = "herdr", env: dict | None = None) -> set[str]:
    """Query Herdr for installed agent integrations.

    Runs `herdr integration status` and returns targets whose status is not 'not installed'.
    If the herdr CLI is unavailable, checks known integration hook paths.
    """
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, herdr_bin, proc_env) or herdr_bin

    installed = set()
    try:
        res = subprocess.run([exe, "integration", "status"], capture_output=True, text=True, timeout=6, env=proc_env)
        if res.returncode == 0:
            for raw_line in res.stdout.splitlines():
                line = raw_line.strip()
                if ":" in line:
                    target, rest = line.split(":", 1)
                    target = target.strip().lower()
                    rest = rest.strip().lower()
                    if not rest.startswith("not installed"):
                        installed.add(target)
            return installed
    except Exception:
        pass

    # Fallback to inspecting hook files directly
    for target, rel_path in HERDR_HOOK_FALLBACKS.items():
        hook_path = home / rel_path
        if hook_path.is_file() and hook_path.stat().st_size > 0:
            installed.add(target)

    return installed


def _read_hermes_config(home: Path) -> dict:
    conf_path = home / '.hermes/config.yaml'
    if not conf_path.is_file():
        return {}
    try:
        conf_text = conf_path.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        return {}
    try:
        import yaml
        loaded = yaml.safe_load(conf_text)
        if isinstance(loaded, dict):
            return loaded
    except Exception:
        pass
    res = {}
    model_sec = {}
    in_model = False
    for line in conf_text.splitlines():
        trimmed = line.strip()
        if not trimmed or trimmed.startswith('#'):
            continue
        if line.startswith('model:'):
            in_model = True
            continue
        elif not line.startswith(' ') and not line.startswith('\t') and in_model:
            in_model = False
        if in_model and ':' in trimmed:
            k, v = trimmed.split(':', 1)
            model_sec[k.strip()] = v.strip().strip("'\"")
    res['model'] = model_sec
    return res


def _query_hermes_session(home: Path, session_id: str | None = None) -> dict | None:
    """Query Hermes session details from ~/.hermes/state.db."""
    db_path = home / '.hermes' / 'state.db'
    if not db_path.is_file():
        return None
    try:
        import sqlite3
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            cur = conn.cursor()
            row = None
            if session_id:
                cur.execute(
                    "SELECT id, model, title, input_tokens, output_tokens FROM sessions WHERE id = ? LIMIT 1",
                    (session_id,)
                )
                row = cur.fetchone()
                if not row:
                    cur.execute(
                        "SELECT id, model, title, input_tokens, output_tokens FROM sessions WHERE id LIKE ? ORDER BY started_at DESC LIMIT 1",
                        (f"%{session_id}%",)
                    )
                    row = cur.fetchone()
            else:
                cur.execute(
                    "SELECT id, model, title, input_tokens, output_tokens FROM sessions ORDER BY started_at DESC LIMIT 1"
                )
                row = cur.fetchone()

            if not row:
                return None

            s_id, model, title, in_tok, out_tok = row
            tokens = (in_tok or 0) + (out_tok or 0)
            return {
                "id": s_id,
                "model": model,
                "title": title,
                "tokens": tokens,
            }
        finally:
            conn.close()
    except Exception:
        return None


def _fmt_hermes_tokens(n: int) -> str:
    """Format a token count compactly (e.g. 524288 -> '512K', 51468 -> '51.5K', 19775690 -> '19.8M')."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 65536 and (n & (n - 1)) == 0:
        return f"{n // 1024}K"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


def _read_hermes_dotenv(home: Path) -> dict[str, str]:
    env_path = home / ".hermes" / ".env"
    if not env_path.is_file():
        return {}
    result: dict[str, str] = {}
    try:
        for raw_line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            result[k.strip()] = v.strip().strip("'\"")
    except Exception:
        pass
    return result


def _resolve_hermes_context_length(home: Path, model_conf: dict, proc_env: dict | None = None) -> int:
    """Resolve the context window size (in tokens) for Hermes's configured model."""
    try:
        cfg_ctx = int(model_conf.get("context_length") or 0)
        if cfg_ctx > 0:
            return cfg_ctx
    except (TypeError, ValueError):
        pass

    default_model = str(model_conf.get("default", "") or model_conf.get("model", "")).strip()
    base_url = str(model_conf.get("base_url", "") or "").strip().rstrip("/")

    # Check ~/.hermes/context_length_cache.yaml if present
    cache_yaml = home / ".hermes" / "context_length_cache.yaml"
    if cache_yaml.is_file():
        try:
            import yaml
            doc = yaml.safe_load(cache_yaml.read_text(encoding="utf-8", errors="ignore"))
            if isinstance(doc, dict):
                ctx_map = doc.get("context_lengths") or {}
                if isinstance(ctx_map, dict):
                    for key in (f"{default_model}@{base_url}", f"{default_model}@{base_url}/", default_model):
                        val = ctx_map.get(key)
                        if isinstance(val, int) and val > 0:
                            return val
        except Exception:
            pass

    # Check 5-minute local cache or probe {base_url}/models
    probe_cache_path = home / ".hermes" / ".msam_model_ctx_cache.json"
    cache_key = f"{default_model}@{base_url}"
    if probe_cache_path.is_file():
        try:
            cached_doc = json.loads(probe_cache_path.read_text(encoding="utf-8"))
            entry = (cached_doc.get("entries") or {}).get(cache_key)
            if isinstance(entry, dict) and time.time() - float(entry.get("at", 0)) < 300:
                ctx_val = int(entry.get("context_length") or 0)
                if ctx_val > 0:
                    return ctx_val
        except Exception:
            pass

    if base_url and (base_url.startswith("http://") or base_url.startswith("https://")):
        dotenv_vars = _read_hermes_dotenv(home)
        key_env = str(model_conf.get("key_env", "") or "").strip()
        api_key = ""
        if key_env:
            api_key = str((proc_env or {}).get(key_env) or dotenv_vars.get(key_env) or "")
        headers = {"Accept": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        status_code, body, _ = http_get_json(f"{base_url}/models", headers=headers, timeout=2.5)
        if status_code == 200 and isinstance(body, dict):
            models_list = body.get("data") if isinstance(body.get("data"), list) else []
            matched = None
            for item in models_list:
                if isinstance(item, dict) and item.get("id") == default_model:
                    matched = item
                    break
            if matched is None and len(models_list) == 1 and isinstance(models_list[0], dict):
                matched = models_list[0]
            if isinstance(matched, dict):
                meta = matched.get("meta") if isinstance(matched.get("meta"), dict) else {}
                for candidate in (
                    meta.get("n_ctx"),
                    matched.get("context_length"),
                    matched.get("max_model_len"),
                    matched.get("context_window"),
                ):
                    try:
                        c_val = int(candidate or 0)
                        if c_val > 0:
                            try:
                                probe_cache_path.write_text(
                                    json.dumps({"entries": {cache_key: {"context_length": c_val, "at": time.time()}}}),
                                    encoding="utf-8",
                                )
                            except Exception:
                                pass
                            return c_val
                    except (TypeError, ValueError):
                        continue

    if "qwen3" in default_model.lower():
        return 524288
    return 262144


def _extract_hermes_session_context_tokens(cur, session_id: str, model_config_str: str | None, in_tok: int, out_tok: int, api_calls: int) -> int:
    """Determine current context window occupancy for a Hermes session."""
    if model_config_str:
        try:
            cfg = json.loads(model_config_str)
            if isinstance(cfg, dict):
                anchor = cfg.get("_usage_anchor")
                if isinstance(anchor, dict):
                    pt = int(anchor.get("prompt_tokens") or 0)
                    ct = int(anchor.get("completion_tokens") or 0)
                    if pt + ct > 0:
                        return pt + ct
        except Exception:
            pass
    try:
        cur.execute(
            "SELECT COALESCE(SUM(token_count), 0), COALESCE(SUM(LENGTH(COALESCE(content,'')) + LENGTH(COALESCE(tool_calls,'')) + LENGTH(COALESCE(reasoning,''))), 0) FROM messages WHERE session_id = ? AND active = 1",
            (session_id,),
        )
        m_row = cur.fetchone()
        if m_row:
            tok_sum, char_sum = int(m_row[0] or 0), int(m_row[1] or 0)
            if tok_sum > 0:
                return tok_sum
            if char_sum > 0:
                return max(1, char_sum // 4)
    except Exception:
        pass
    total_io = max(0, int(in_tok or 0) + int(out_tok or 0))
    if total_io > 0:
        calls = max(1, int(api_calls or 1))
        return max(1, total_io // calls) if calls > 1 else total_io
    return 0


def _collect_hermes_db_usage(home: Path, config: dict, proc_env: dict | None = None) -> tuple[float, list[dict]]:
    """Compute Hermes context window utilization and 5h/7d token activity from ~/.hermes/state.db."""
    db_path = home / ".hermes" / "state.db"
    if not db_path.is_file():
        return 0.0, []

    model_conf = config.get("model", {}) if isinstance(config, dict) else {}
    context_length = max(1, _resolve_hermes_context_length(home, model_conf, proc_env))
    ctx_limit_label = _fmt_hermes_tokens(context_length)

    try:
        import sqlite3
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            cur = conn.cursor()
            cols = {r[1] for r in cur.execute("PRAGMA table_info(sessions)").fetchall()}
            if "id" not in cols:
                return 0.0, []

            now = time.time()
            has_source = "source" in cols
            has_model_config = "model_config" in cols
            has_ended_at = "ended_at" in cols
            has_last_activity = "last_activity_at" in cols
            has_api_calls = "api_call_count" in cols
            has_reasoning = "reasoning_tokens" in cols

            select_exprs = [
                "id",
                "source" if has_source else "'cli'",
                "model_config" if has_model_config else "NULL",
                "COALESCE(input_tokens, 0)",
                "COALESCE(output_tokens, 0)",
                "COALESCE(api_call_count, 0)" if has_api_calls else "1",
                "COALESCE(last_activity_at, started_at, 0)" if has_last_activity else "COALESCE(started_at, 0)",
                "ended_at" if has_ended_at else "NULL",
            ]
            where_active = "WHERE ended_at IS NULL" if has_ended_at else ""
            order_expr = "COALESCE(last_activity_at, started_at, 0) DESC" if has_last_activity else "started_at DESC"

            cur.execute(
                f"SELECT {', '.join(select_exprs)} FROM sessions {where_active} ORDER BY {order_expr} LIMIT 20"
            )
            candidate_rows = cur.fetchall()
            if not candidate_rows:
                cur.execute(
                    f"SELECT {', '.join(select_exprs)} FROM sessions ORDER BY {order_expr} LIMIT 5"
                )
                candidate_rows = cur.fetchall()

            windows: list[dict] = []
            context_pcts: list[float] = []
            seen_surfaces: set[str] = set()

            for row in candidate_rows:
                s_id, source, m_cfg, in_tok, out_tok, api_calls, last_ts, _ = row
                src = str(source or "cli").strip().lower()
                if src == "cron" and len(candidate_rows) > 1 and seen_surfaces:
                    continue
                surface_key = "cli" if src == "cli" else ("gateway" if src in ("whatsapp", "telegram", "discord", "slack", "gateway") else src)
                if surface_key in seen_surfaces:
                    continue
                ctx_tokens = _extract_hermes_session_context_tokens(cur, str(s_id), m_cfg, int(in_tok or 0), int(out_tok or 0), int(api_calls or 0))
                if ctx_tokens <= 0:
                    continue
                seen_surfaces.add(surface_key)
                pct = min(99.0, max(1.0, round((ctx_tokens / context_length) * 100.0, 1)))
                context_pcts.append(pct)
                surface_title = "CLI Context" if surface_key == "cli" else ("Gateway Context" if surface_key == "gateway" else "Context Window")
                win_mins = 60 if surface_key == "gateway" else 180
                windows.append({
                    "group": f"{surface_title} ({_fmt_hermes_tokens(ctx_tokens)} / {ctx_limit_label})",
                    "window_minutes": win_mins,
                    "used_percent": pct,
                    "resets_at": None,
                })
                if len(windows) >= 2:
                    break

            ts_col = "COALESCE(last_activity_at, ended_at, started_at)" if (has_last_activity and has_ended_at) else ("COALESCE(last_activity_at, started_at)" if has_last_activity else "started_at")
            tok_col = "COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0) + COALESCE(reasoning_tokens, 0)" if has_reasoning else "COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)"

            cur.execute(
                f"SELECT COUNT(*), COALESCE(SUM({tok_col}), 0) FROM sessions WHERE {ts_col} >= ?",
                (now - 5 * 3600,),
            )
            sess_5h, tok_5h = cur.fetchone() or (0, 0)
            sess_5h, tok_5h = int(sess_5h or 0), int(tok_5h or 0)

            cur.execute(
                f"SELECT COUNT(*), COALESCE(SUM({tok_col}), 0) FROM sessions WHERE {ts_col} >= ?",
                (now - 7 * 86400,),
            )
            sess_7d, tok_7d = cur.fetchone() or (0, 0)
            sess_7d, tok_7d = int(sess_7d or 0), int(tok_7d or 0)

            primary_pct = max(context_pcts) if context_pcts else 0.0
            if primary_pct == 0.0 and tok_7d > 0:
                primary_pct = min(99.0, max(1.0, round((min(tok_5h or tok_7d, context_length) / context_length) * 100.0, 1)))

            if tok_5h > 0:
                pct_5h = min(99.0, max(1.0, round((tok_5h / tok_7d) * 100.0, 1))) if tok_7d > 0 else primary_pct
                windows.append({
                    "group": f"5-Hour Activity ({_fmt_hermes_tokens(tok_5h)} tok · {sess_5h} sess)",
                    "window_minutes": 300,
                    "used_percent": pct_5h,
                    "resets_at": None,
                })
            if tok_7d > 0:
                windows.append({
                    "group": f"7-Day Activity ({_fmt_hermes_tokens(tok_7d)} tok · {sess_7d} sess)",
                    "window_minutes": 10080,
                    "used_percent": primary_pct,
                    "resets_at": None,
                })

            return primary_pct, windows
        finally:
            conn.close()
    except Exception:
        return 0.0, []


def _normalize_hermes_windows(raw_windows: list) -> list[dict]:
    """Normalize `hermes usage --json` window objects into MSAM UsageWindow schema."""
    normalized: list[dict] = []
    if not isinstance(raw_windows, list):
        return normalized
    for idx, w in enumerate(raw_windows):
        if not isinstance(w, dict):
            continue
        label = str(w.get("group") or w.get("label") or f"Window {idx + 1}").strip()
        detail = str(w.get("detail") or "").strip()
        group = f"{label} ({detail})" if detail and detail not in label else label
        raw_mins = w.get("window_minutes")
        if isinstance(raw_mins, (int, float)) and int(raw_mins) > 0:
            win_mins = int(raw_mins)
        else:
            lower_label = label.lower()
            if "week" in lower_label:
                win_mins = 10080
            elif any(k in lower_label for k in ("month", "sub")):
                win_mins = 43200
            else:
                win_mins = 300
        try:
            used_pct = float(w.get("used_percent") or 0.0)
        except (TypeError, ValueError):
            used_pct = 0.0
        normalized.append({
            "group": group,
            "window_minutes": win_mins,
            "used_percent": used_pct,
            "resets_at": w.get("resets_at"),
        })
    return normalized


def collect_hermes_quota(home_dir: Path | str | None = None, hermes_bin: str = "hermes", env: dict | None = None) -> dict:
    """Query Hermes usage from CLI account limits and ~/.hermes/state.db session telemetry."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    proc_env = _get_process_env(home, env)
    exe = _find_bin(home, hermes_bin, proc_env) or hermes_bin

    config = _read_hermes_config(home)
    model_conf = config.get("model", {}) if isinstance(config, dict) else {}
    configured_provider = str(model_conf.get("provider", "")).strip().lower()
    default_model = str(model_conf.get("default", "") or model_conf.get("model", "")).strip()
    base_plan = configured_provider or "custom"
    plan_name = f"{base_plan} ({default_model})" if default_model else base_plan

    try:
        res = subprocess.run([exe, "usage", "--json"], capture_output=True, text=True, timeout=8, env=proc_env)
        if res.returncode == 0:
            try:
                data = json.loads(res.stdout)
                windows = _normalize_hermes_windows(data.get("windows", []))
                raw_used = data.get("used_percent")
                if raw_used is not None:
                    used = float(raw_used)
                else:
                    used = max((w["used_percent"] for w in windows), default=0.0)
                resets_at = data.get("resets_at")
                if not resets_at:
                    resets_candidates = [w["resets_at"] for w in windows if w.get("resets_at")]
                    if resets_candidates:
                        resets_at = min(resets_candidates)
                if used == 0.0 and not windows:
                    db_used, db_windows = _collect_hermes_db_usage(home, config, proc_env)
                    used = db_used
                    windows = db_windows
                state = "RATE_LIMITED" if used >= 100.0 else "HEALTHY"
                return {
                    "state": state,
                    "used_percent": used,
                    "resets_at": resets_at,
                    "plan": data.get("plan") or plan_name,
                    "windows": windows,
                    "reset_credits": data.get("reset_credits"),
                }
            except Exception:
                pass
            db_used, db_windows = _collect_hermes_db_usage(home, config, proc_env)
            return {
                "state": "HEALTHY",
                "used_percent": db_used,
                "resets_at": None,
                "plan": plan_name,
                "windows": db_windows,
                "reset_credits": None,
            }

        combined = f"{res.stdout} {res.stderr}".lower()

        # If Hermes is configured with a local/custom provider (like vLLM, Ollama, private server)
        # or reports that the provider has no usage endpoint, derive context & activity usage from state.db.
        if (
            "has no usage endpoint" in combined
            or configured_provider in ("custom", "local", "ollama", "vllm", "llama", "spark")
            or "provider 'custom'" in combined
            or "provider 'local'" in combined
        ):
            db_used, db_windows = _collect_hermes_db_usage(home, config, proc_env)
            return {
                "state": "HEALTHY",
                "used_percent": db_used,
                "resets_at": None,
                "plan": plan_name,
                "windows": db_windows,
                "reset_credits": None,
            }

        if "login" in combined or "auth" in combined or ("credential" in combined and "no credential is configured for it" not in combined):
            return {
                "state": "SIGN_IN_REQUIRED",
                "used_percent": 0.0,
                "resets_at": None,
                "plan": plan_name,
                "windows": [],
                "reset_credits": None,
            }

        return {
            "state": "UNAVAILABLE",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": plan_name,
            "windows": [],
            "reset_credits": None,
        }
    except Exception:
        if configured_provider in ("custom", "local", "ollama", "vllm", "spark"):
            db_used, db_windows = _collect_hermes_db_usage(home, config, proc_env)
            return {
                "state": "HEALTHY",
                "used_percent": db_used,
                "resets_at": None,
                "plan": plan_name,
                "windows": db_windows,
                "reset_credits": None,
            }
        return {
            "state": "UNAVAILABLE",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": plan_name,
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

    # Build transcript index for codex and claude (including Woodhouse vault roots if accessible)
    index: dict[tuple[str, str], Path] = {}
    search_roots: list[tuple[str, Path]] = [
        ('codex', home / '.codex/sessions'),
        ('claude', home / '.claude/projects'),
        ('claude_code', home / '.claude/projects'),
    ]
    try:
        if home.resolve() == Path.home().resolve():
            vault_claude = Path('/run/woodhouse-machine-vault/agents/claude/projects')
            vault_codex = Path('/run/woodhouse-machine-vault/agents/codex/sessions')
            if vault_claude.is_dir():
                search_roots.extend([('claude', vault_claude), ('claude_code', vault_claude)])
            if vault_codex.is_dir():
                search_roots.append(('codex', vault_codex))
    except Exception:
        pass

    for provider, root in search_roots:
        if root.exists():
            try:
                for p in root.rglob("*.jsonl"):
                    index[(provider, p.stem.lower())] = p
                    match = UUID_REGEX.search(p.stem)
                    if match:
                        index[(provider, match.group().lower())] = p
            except Exception:
                pass

    terminals = []
    for a in raw_agents.values():
        agent_type = str(a.get("agent") or (a.get("agent_session") or {}).get("agent") or "").lower()
        name_str = str(a.get("name") or "").lower()
        title_str = str(a.get("terminal_title") or a.get("terminal_title_stripped") or "").lower()
        cmd_str = str(a.get("command") or "").lower()
        combined = f"{agent_type} {name_str} {title_str} {cmd_str}"

        if "claude" in agent_type:
            norm_provider = "claude_code"
        elif "codex" in agent_type:
            norm_provider = "codex"
        elif any(k in agent_type for k in ("agy", "antigravity")):
            norm_provider = "antigravity"
        elif "hermes" in agent_type:
            norm_provider = "hermes"
        elif "claude" in combined:
            norm_provider = "claude_code"
        elif "codex" in combined:
            norm_provider = "codex"
        elif any(k in combined for k in ("agy", "antigravity")):
            norm_provider = "antigravity"
        elif "hermes" in combined:
            norm_provider = "hermes"
        else:
            norm_provider = agent_type or "unknown"

        status = str(a.get("agent_status") or "idle")
        is_limit_reached = (status.lower() == "blocked")
        pane_id = str(a.get("pane_id") or "")
        tab_id = str(a.get("tab_id") or "")
        name = str(a.get("name") or pane_id or "terminal")

        session_id = str((a.get("agent_session") or {}).get("value") or "").lower()
        transcript_path = ""
        model = None
        session_tokens = None
        session_cost_usd = None

        if norm_provider == 'hermes':
            s = _query_hermes_session(home, session_id if session_id else None)
            if s:
                model = s.get("model") or model
                session_tokens = s.get("tokens") if s.get("tokens") is not None else session_tokens
                if s.get("title"):
                    name = s["title"]
                transcript_path = f"hermes:{s['id']}"
            else:
                raw_title = str(a.get("terminal_title") or a.get("terminal_title_stripped") or "").strip()
                if raw_title and "·" in raw_title:
                    match = re.match(r"^(.*?)\s*·\s*([a-zA-Z0-9_\-\.]+)(?:\s*·\s*(.*))?$", raw_title)
                    if match:
                        fallback_title = match.group(1).strip()
                        fallback_model = match.group(2).strip()
                        if fallback_title:
                            name = fallback_title
                        if fallback_model:
                            model = fallback_model
                if session_id:
                    transcript_path = f"hermes:{session_id}"
        else:
            matched_p = index.get((norm_provider, session_id)) or index.get((agent_type, session_id))
            if matched_p and matched_p.exists():
                transcript_path = str(matched_p.resolve())
                if norm_provider == 'codex':
                    model, session_tokens, session_cost_usd = _extract_codex_transcript_metrics(matched_p)
                elif norm_provider == 'claude_code':
                    model, session_tokens, session_cost_usd = _extract_claude_transcript_metrics(matched_p)

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
            "session_cost_usd": round(session_cost_usd, 2) if session_cost_usd is not None else None,
            "transcript_path": transcript_path,
            "is_limit_reached": is_limit_reached,
        })

    return terminals


def analyze_session_task(transcript_path: str, target_provider: str = "codex", home_dir: Path | str | None = None, env: dict | None = None) -> dict:
    """Analyze a previous session transcript to determine task complexity and recommend optimal model and effort."""
    home = Path(home_dir).expanduser() if home_dir else Path.home()
    content = ""
    if transcript_path and transcript_path.startswith("hermes:"):
        session_id = transcript_path.split(":", 1)[1]
        db_path = home / ".hermes" / "state.db"
        if db_path.is_file():
            try:
                import sqlite3
                conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
                try:
                    cur = conn.cursor()
                    cur.execute(
                        "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT 20",
                        (session_id,)
                    )
                    rows = cur.fetchall()
                    if not rows:
                        cur.execute(
                            "SELECT role, content FROM messages WHERE session_id LIKE ? ORDER BY id DESC LIMIT 20",
                            (f"%{session_id}%",)
                        )
                        rows = cur.fetchall()
                    rows.reverse()
                    msgs = []
                    for role, text in rows:
                        if text:
                            msgs.append(f"{role}: {text}")
                    content = "\n".join(msgs)
                finally:
                    conn.close()
            except Exception:
                pass
    else:
        p = Path(transcript_path).expanduser() if transcript_path else None
        if p and p.exists():
            try:
                with p.open('r', encoding='utf-8', errors='replace') as f:
                    lines = f.readlines()
                    # Examine last 50 lines of interaction
                    content = "\n".join(lines[-50:])
            except Exception:
                pass

    content_lower = content.lower()
    # Assess task complexity heuristic fallback
    complex_indicators = [
        "error", "failed", "deadlock", "timeout", "refactor", "architectur",
        "exception", "traceback", "fatal", "restructure", "compile", "bug", "crash"
    ]
    complexity_score = sum(1 for word in complex_indicators if word in content_lower)
    is_complex = complexity_score >= 2 or len(content) > 5000

    target = target_provider.lower().replace("-", "_")

    # Try live background analysis using the selected provider CLI
    proc_env = dict(env or os.environ)
    local_bin = str(home / ".local" / "bin")
    if local_bin not in proc_env.get("PATH", ""):
        proc_env["PATH"] = f"{local_bin}:{proc_env.get('PATH', '')}"

    sample = content[-2000:] if len(content) > 2000 else content
    eval_prompt = (
        "You are an AI task analyzer. Inspect this session snippet and recommend the optimal "
        "model and reasoning effort level ('low', 'medium', or 'high') to resume this task.\n\n"
        f"Context:\n```\n{sample}\n```\n\n"
        "Respond ONLY with a valid JSON object matching: "
        '{"model": "<model_name>", "effort": "<low|medium|high>", "summary": "<brief reason>"}'
    )

    cmd = None
    if "codex" in target:
        cmd = ["codex", "exec", "-c", "shell_environment_policy.inherit=all", eval_prompt]
    elif "claude" in target:
        cmd = ["claude", "-p", "--dangerously-skip-permissions", eval_prompt]
    elif "anti" in target or "agy" in target:
        cmd = ["agy", "-p", "--dangerously-skip-permissions", eval_prompt]
    elif "hermes" in target:
        cmd = ["hermes", "chat", "-q", eval_prompt, "--oneshot", "-Q"]

    if cmd:
        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=20,
                env=proc_env
            )
            if res.returncode == 0 and res.stdout.strip():
                match = re.search(r"\{[\s\S]*\}", res.stdout)
                if match:
                    parsed = json.loads(match.group(0))
                    model_val = parsed.get("model")
                    effort_val = parsed.get("effort")
                    summary_val = parsed.get("summary")
                    if model_val and effort_val:
                        return {
                            "model": str(model_val).strip(),
                            "effort": str(effort_val).strip().lower(),
                            "is_complex": is_complex,
                            "summary": str(summary_val or "Model recommendation by provider").strip(),
                        }
        except Exception:
            pass

    # Heuristic fallback if provider CLI was not reachable, timed out, or returned invalid JSON
    if "codex" in target:
        model = "gpt-6.1-sol"
        effort = "high" if is_complex else "medium"
    elif "claude" in target:
        model = "claude-3-7-sonnet"
        effort = "high" if is_complex else "medium"
    elif "anti" in target or "agy" in target:
        model = "gemini-2.5-pro" if is_complex else "gemini-2.5-flash"
        effort = "high" if is_complex else "medium"
    elif "hermes" in target:
        config = _read_hermes_config(home)
        model_conf = config.get("model", {}) if isinstance(config, dict) else {}
        model = str(model_conf.get("default", "") or model_conf.get("model", "")).strip() or "qwen3.8-flash-next"
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
    installed = get_installed_herdr_integrations(home_dir=home, env=env)

    providers = {}

    if "claude" in installed:
        candidate_paths = []
        if env and "CLAUDE_CONFIG_DIR" in env:
            candidate_paths.append(Path(env["CLAUDE_CONFIG_DIR"]) / ".credentials.json")
        elif "CLAUDE_CONFIG_DIR" in os.environ:
            candidate_paths.append(Path(os.environ["CLAUDE_CONFIG_DIR"]) / ".credentials.json")
        # Woodhouse's credential vault is deliberately not read: only its own workers may.
        candidate_paths.append(home / ".claude" / ".credentials.json")

        existing_creds = [p for p in candidate_paths if p.is_file()]
        existing_creds.sort(key=lambda p: p.stat().st_mtime, reverse=True)

        claude_res = None
        for p in existing_creds:
            res = collect_claude_quota(p)
            if res.get("state") == "HEALTHY":
                claude_res = res
                break
            if claude_res is None:
                claude_res = res
        providers["claude_code"] = claude_res or {
            "state": "SIGN_IN_REQUIRED",
            "used_percent": 0.0,
            "resets_at": None,
            "plan": "pro",
            "windows": [],
            "reset_credits": None,
        }

    if "codex" in installed:
        providers["codex"] = collect_codex_quota(home_dir=home, env=env)

    if "antigravity-cli" in installed:
        providers["antigravity"] = collect_antigravity_quota(home_dir=home, env=env)

    if "hermes" in installed:
        providers["hermes"] = collect_hermes_quota(home_dir=home, env=env)

    terminals = collect_terminal_agents(home_dir=home, env=env)

    return {
        "installed_integrations": sorted(list(installed)),
        "providers": providers,
        "terminal_agents": terminals,
    }


def main():
    telemetry = collect_provider_telemetry()
    print(json.dumps(telemetry, indent=2))


if __name__ == '__main__':
    main()
