# Provider Pulse Toolbar Integration and Session Rollover Design

**Date:** 2026-10-28  
**Status:** Approved  
**Author:** AI Pair Programming Team

---

## 1. Overview & Objectives

This specification defines the architecture, data pipeline, user interface, and operational workflows for integrating **Provider Pulse** telemetry into MultiSessionAIManager and enabling automated **Session Rollover** when an AI agent reaches a usage or rate limit.

### Key Objectives:
1. **Host-Side Telemetry Collection:** Enhance the existing `msam-host-agent` service on each host to collect live subscription/credit quotas for installed AI providers (Claude Code, Codex, Antigravity, Hermes) and terminal agent session states from Herdr.
2. **Unified Metrics Transport:** Embed provider quotas and terminal activity into the established, low-latency SSH metrics stream without requiring extra ports, tunnels, or standalone background daemons.
3. **App Header & Toolbar Restructuring:**
   - Remove the theme palette icon from the top header strip (delegating terminal theme management strictly to Settings and Herdr sessions).
   - On Mac/iPad (regular width): Display individual hardware metrics alongside authentic provider brand icons with live `%` usage badges.
   - On iPhone (compact width): Consolidate hardware gauges into a single Hardware icon button and provider metrics into a single AI icon button.
4. **Interactive Provider Details:** Tapping any provider displays quota window breakdowns, reset countdown timers, available reset credits (e.g. Codex), and active terminal sessions running under that provider on that host.
5. **Automated Session Rollover:** When a terminal session encounters a rate or usage limit, the user can trigger "Continue session". A modal allows selecting an alternative provider (displaying live usage percentages) with a `--yolo` / `--dangerously-skip-permissions` toggle. Confirming creates an adjacent tab, delivers a token-optimized continuation command referencing the previous session's on-disk transcript, and closes the exhausted session.

---

## 2. Architecture & Data Flow

```
┌────────────────────────────────────────────────────────────────────────┐
│                          REMOTE HOST                                   │
│                                                                        │
│  msam-host-agent (User Service / Daemon)                               │
│    │                                                                   │
│    ├── msam-metrics.py (Hardware: CPU, Mem, GPU, Disk, Net)            │
│    └── msam-provider-pulse.py (AI Telemetry & Herdr Correlator)        │
│          ├── Claude Code: ~/.claude/.credentials.json -> Anthropic API │
│          ├── Codex: codex app-server --stdio (RateLimits & Usage)     │
│          ├── Antigravity: agy -p /usage                               │
│          ├── Hermes: hermes usage                                      │
│          └── Herdr Agent List & Transcripts (~/.codex, ~/.claude)      │
│    │                                                                   │
│    └── Writes atomic JSON -> ~/.local/state/msam-host-agent/metrics.json
└────────────────────────────────────────────────────────────────────────┘
                                    │
                         SSH Exec Channel (Streaming)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     MULTISESSIONAIMANAGER (iOS/macOS)                  │
│                                                                        │
│  HerdrHostSession -> Decodes MetricsPayload + ProviderPayload          │
│    │                                                                   │
│    ├── HostMetricsModel (Hardware Metrics)                             │
│    └── ProviderPulseModel (Providers & Active Agent Terminals)         │
│          │                                                             │
│          ├── Top Header Toolbar:                                       │
│          │     • iPad/Mac: [CPU][MEM][GPU][NET] | [Claude%][Codex%][Agy%]
│          │     • iPhone:   [Hardware Icon]      | [AI Pulse Icon]      │
│          │                                                             │
│          ├── Provider Details Popover / Sheet                          │
│          │     • Quota Windows, Reset Timers, Reset Credits            │
│          │     • Running Terminals (Tokens, Status, Limit Flag)        │
│          │                                                             │
│          └── Session Rollover Modal & Tab Handover Engine              │
│                • Creates adjacent tab via HostTabStore                 │
│                • Injects token-optimized command with transcript path  │
│                • Closes exhausted tab & Herdr pane                     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Host Collector Subsystem (`msam-provider-pulse.py`)

A new Python module `msam-provider-pulse.py` will be bundled into `app/MultiSessionAIManager/Resources/` and installed by `msam-host-agent-install.py`.

### 3.1 Integration-Aware Quota Collection
The collector queries only the integrations configured on the host:

1. **Claude Code (`claude_code`):**
   - Reads `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`).
   - Extracts `claudeAiOauth.accessToken` and checks `expiresAt`.
   - Hits `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`.
   - Implements a 5-minute cache cooldown (`FRESH_SECONDS = 300`) with exponential backoff on HTTP 429 (`Retry-After`).
   - Returns: `state` (`HEALTHY`, `RATE_LIMITED`, `SIGN_IN_REQUIRED`), `used_percent` (primary pool), `windows` (5-hour and 7-day pools), `resets_at`, and `plan`.

2. **Codex (`codex`):**
   - Connects to `codex app-server --stdio` as a JSON-RPC client.
   - Sends `initialize` followed by `account/rateLimits/read` and `account/usage/read`.
   - Returns: `state`, `used_percent`, `windows` (7-day pool), `resets_at`, cumulative tokens, and `reset_credits` (`available_count`, `expires_at`).

3. **Antigravity (`antigravity`):**
   - Executes `agy -p /usage` (timeout 15s).
   - Parses the model sub-pools (Gemini, Claude, GPT), extracting 5-hour and 7-day usage percentages and reset timestamps.

4. **Hermes (`hermes`):**
   - Executes `hermes usage` (timeout 10s).
   - Parses rate-limit windows and account health.

### 3.2 Terminal Agent Activity & Transcript Correlation
- Executes `herdr agent list` to discover all active agent panes.
- For each agent (`claude`, `codex`, `agy`, `hermes`):
  - Resolves `pane_id` (e.g. `wD:p7`), `tab_id`, `name`, `project` (working directory), and `state` (`working`, `idle`, `blocked`).
  - Matches the session ID to its transcript file:
    - **Codex:** `~/.codex/sessions/**/<session_uuid>.jsonl` -> reads model name and cumulative `token_count`.
    - **Claude Code:** `~/.claude/projects/**/<session_uuid>.jsonl` -> reads model name and assistant token usage.
  - Stores `transcript_path` directly in the payload so the rollover engine knows exactly where the prior context lives.
  - Flags `is_limit_reached` when the agent is `blocked` or the associated provider is `RATE_LIMITED`.

### 3.3 Snapshot Schema in `metrics.json`
`msam-host-agent.py` merges this dictionary into the existing payload:
```json
{
  "cpu": { ... },
  "memory": { ... },
  "gpu": { ... },
  "disk": { ... },
  "network": { ... },
  "providers": {
    "claude_code": {
      "state": "RATE_LIMITED",
      "used_percent": 100.0,
      "resets_at": "2026-10-28T17:00:00Z",
      "plan": "max",
      "windows": [
        { "group": "All models", "window_minutes": 300, "used_percent": 0.0, "resets_at": null },
        { "group": "All models", "window_minutes": 10080, "used_percent": 100.0, "resets_at": "2026-10-28T17:00:00Z" }
      ],
      "reset_credits": null
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
    },
    "antigravity": {
      "state": "HEALTHY",
      "used_percent": 39.0,
      "resets_at": "2026-11-01T07:29:52Z"
    },
    "hermes": {
      "state": "HEALTHY",
      "used_percent": 0.0
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
      "transcript_path": "/home/rufus/.claude/projects/-home-rufus-Projects-ai-stack/01a18130.jsonl",
      "is_limit_reached": true
    }
  ]
}
```

---

## 4. Swift Client Models & State Management

### 4.1 Data Structures in `HostMetricsModel.swift`
```swift
struct ProviderQuota: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let state: String // "HEALTHY", "RATE_LIMITED", "REFRESH_DELAYED", etc.
    let usedPercent: Double
    let resetsAt: Date?
    let plan: String?
    let windows: [UsageWindow]?
    let resetCredits: ResetCredits?
    
    var isRateLimited: Bool { state == "RATE_LIMITED" || usedPercent >= 100.0 }
}

struct TerminalAgentSession: Decodable, Identifiable {
    var id: String { paneID }
    let paneID: String
    let tabID: String
    let name: String
    let provider: String
    let project: String
    let state: String
    let model: String?
    let sessionTokens: Int?
    let transcriptPath: String?
    let isLimitReached: Bool
}
```

### 4.2 Observable `ProviderPulseModel`
- Maintained inside `HerdrHostSession` alongside `HostMetricsModel`.
- Updates reactively whenever a new JSON line arrives on the metrics SSH stream.
- Provides helper accessors:
  - `activeProviders: [ProviderQuota]`
  - `hasRateLimitedProvider: Bool`
  - `terminals(for provider: String) -> [TerminalAgentSession]`

---

## 5. UI & Header Strip Architecture

### 5.1 Clean-up of Theme Icon
- In `app/MultiSessionAIManager/UI/RootView.swift`:
  - Delete lines 214–247 (the `paintpalette` button).
  - Delete lines 266–284 (the `"Tab Theme"` section in the compact menu).
- Global theme selection remains in `MSAMSettingsView` -> `TerminalPreferencesSection`.
- Per-tab themes are controlled through Herdr sessions.

### 5.2 Regular Width Layout (iPad & Mac)
- Header layout:
  `[HostTabStrip] ... [HostMetricsBarView] [ProviderPulseBarView] [Selection/Action Buttons]`
- `ProviderPulseBarView`:
  - Renders an icon for each active provider with authentic vector styling:
    - **Claude Code:** Terracotta `#D97757` emblem + `100%`.
    - **Codex:** Dark `#202820` badge with terminal prompt + `1%`.
    - **Antigravity:** DeepMind Google emblem + `39%`.
    - **Hermes:** Winged helmet icon.
  - If a provider is rate-limited (`100%`), the pill highlights with an alert border and warning indicator.
  - Tapping any provider icon presents `ProviderDetailPopover(provider: quota, terminals: list)`.

### 5.3 Compact Width Layout (iPhone)
- Space is restricted on ~390pt phone displays:
  - Consolidate `HostMetricsBarView` into **1 Hardware Metrics Button**:
    - Icon: `gauge.with.needle` / `cpu.fill`.
    - Status dot: Green / Yellow / Red based on CPU/RAM/Disk pressure.
    - Tap: Presents `HardwareMetricsSheet` with tabbed views for CPU, Memory, GPU, Network, and Disk.
  - Consolidate `ProviderPulseBarView` into **1 AI Provider Button**:
    - Icon: `sparkles` / AI emblem.
    - Status badge: Red alert dot or highest usage percentage (e.g., `⚠️ 100%`).
    - Tap: Presents `ProviderPulseSheet` listing all active providers and their agent sessions.

---

## 6. Provider Details Popover & Sheet

When opened, the view presents:
1. **Header Account Summary:**
   - Provider name, icon, plan tier (e.g. `Pro`, `Max`).
   - State indicator (`HEALTHY`, `RATE_LIMITED`).
   - Rolling window bars (5-hour and 7-day usage).
   - Formatted countdown timer (`Resets in 3h 45m`).
   - Unredeemed reset credits (e.g. `2 reset credits available · Expires Oct 29`).
2. **Active Terminals Section:**
   - Lists every terminal session on that host using this provider.
   - Displays pane ID (`wD:p7`), name, project folder, model, and token count.
   - State badge: `working`, `idle`, or `blocked`.
   - If `is_limit_reached` is true:
     - Displays `⚠️ Rate limit reached in this session`.
     - Displays the **`Continue session`** action button.

---

## 7. Session Rollover Modal & Workflow

### 7.1 Modal Presentation
Tapping `Continue session` on a limited terminal opens `SessionRolloverSheet`:
- **Current Session Info:** Terminal title, project directory, and detected transcript path.
- **Replacement Provider Picker:**
  - Radio list of alternative providers on the host.
  - Displays each provider's live usage % (e.g. `Codex (1% used)`, `Antigravity (39% used)`).
  - Rate-limited providers are visually disabled.
- **Execution Options:**
  - Checkbox/Toggle: `Auto-approve commands (--yolo / --dangerously-skip-permissions)`.
  - Default: Enabled.

### 7.2 Execution Flow with Hidden Analysis Window
Upon user confirmation:
1. **Hidden Analysis Window Execution:**
   - Before opening the visible user tab, the host agent runs a hidden analyzer process (headless SSH exec or hidden Herdr temporary pane):
     - It inspects the prior session's transcript context, project directory, and task complexity.
     - It evaluates the optimal **model** and **effort level** for the target provider (e.g. for Codex: `gpt-6.1-sol` with `--effort high` for unfinished complex builds, vs medium for verification; for Claude: `claude-3-7-sonnet` with thinking level).
     - It outputs the recommended model, effort parameters, and task summary.
   - The hidden analysis session terminates and closes immediately.
2. **Open Adjacent Tab:**
   `HostTabStore.open(hostID: currentTab.hostID, sessionName: nil, insertAfter: currentTab.id)`
   Positions the new tab directly adjacent to the existing session and switches focus to it.
3. **Construct Continuation Command:**
   Constructs a token-optimized command incorporating the resolved model, effort level, permission flags, and transcript path:
   ```bash
   codex --model gpt-6.1-sol -c model_effort=high --yolo "Continue previous task from session at /home/rufus/.claude/projects/-home-rufus-Projects-ai-stack/01a18130.jsonl in /home/rufus/Projects/ai-stack. Read the transcript context as needed and complete the work."
   ```
4. **Dispatch Command:**
   Sends the command string into the newly opened terminal session PTY.
5. **Retire Old Tab:**
   - Issues `herdr pane close <old_pane>` on the host.
   - Removes the old tab from `HostTabStore`.

---

## 8. Verification & Testing Strategy

1. **Python Unit Tests:**
   - `test_provider_pulse_codex`: Mock `codex app-server` stdio JSON-RPC responses and verify rate limit parsing.
   - `test_provider_pulse_claude`: Mock Anthropic OAuth API responses, test 5-minute cache cooldown, and verify 429 backoff.
   - `test_provider_pulse_herdr`: Mock `herdr agent list` output and verify transcript file resolution.
2. **Swift Unit Tests:**
   - `testProviderPulseDecoding`: Decode mock JSON with multiple providers and terminal agents.
   - `testHostTabStoreInsertAfter`: Verify tab insertion preserves adjacent order.
   - `testContinuationCommandFormatting`: Verify correct flags (`--yolo` vs `--dangerously-skip-permissions`) and transcript path formatting.
3. **Live Device Verification:**
   - Verify on local host (`forge`) and remote host (`IronMentorMac`).
   - Confirm proper rendering on iPad (full bar) and iPhone (compact single icons).
   - Test end-to-end rollover from a mock rate-limited terminal.
