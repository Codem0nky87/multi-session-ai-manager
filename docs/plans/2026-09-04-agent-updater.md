# Host-Owned AI Agent Updates Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Track Claude Code, Codex, and Antigravity versions per host and perform durable, host-owned rolling updates that restore every eligible AI conversation while leaving ordinary panes untouched.

**Architecture:** Add a fixed Swift tool registry and SSH-backed management model, plus a bundled POSIX host helper installed as a macOS LaunchAgent or Linux systemd user service. The iPad performs authenticated discovery and submits an immutable allowlisted request; the helper persists the batch, updates through the detected installation owner, and rolls captured Herdr agent panes when their semantic state becomes `idle` or `done`.

**Tech Stack:** Swift 6, SwiftUI/Observation, Swift Testing, Citadel SSH/SFTP, POSIX shell, launchd, systemd user services, Herdr 0.8.2+ CLI.

---

## Working rules

- Work in `/Users/rufus/Projects/multi-session-ai-manager/.worktrees/host-agent-updater` on `feature/host-agent-updater`.
- Regenerate the ignored Xcode project with `xcodegen generate` after adding source or resource files.
- Follow @test-driven-development for every production change.
- Keep every remote command fixed or built exclusively from validated enum/registry values and `POSIXShell.quote`.
- Do not add root services, automatic `sudo`, stored passwords, Accessibility automation, global Gatekeeper changes, or arbitrary remote command fields.
- Run @verification-before-completion before claiming the feature is finished.

### Task 1: Persist host automation choices and degraded state

**Files:**
- Modify: `app/MultiSessionAIManager/Core/Host.swift`
- Modify: `app/MultiSessionAIManager/Tests/HostStoreTests.swift`

**Step 1: Write the failing persistence and migration tests**

Add tests proving:

```swift
@Test func aLegacyHostDefaultsToUncheckedAutomation() throws {
    let host = try JSONDecoder().decode(Host.self, from: legacyHostJSON)
    #expect(host.agentUpdaterSetup == .unchecked)
    #expect(host.gatekeeperPolicy == .manualApproval)
}

@Test func automationChoicesRoundTripWithoutSecrets() throws {
    var host = configuredHost()
    host.agentUpdaterSetup = .skipped
    host.gatekeeperPolicy = .verifiedVendorArtifacts
    let data = try JSONEncoder().encode(host)
    let decoded = try JSONDecoder().decode(Host.self, from: data)
    #expect(decoded.agentUpdaterSetup == .skipped)
    #expect(decoded.gatekeeperPolicy == .verifiedVendorArtifacts)
}
```

Also update the encoded-key assertion to include only the two new non-secret keys.

**Step 2: Run the tests to verify they fail**

Run:

```bash
cd app/MultiSessionAIManager
xcodebuild -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .ddp \
  -only-testing:MultiSessionAIManagerTests/HostStoreTests test
```

Expected: FAIL because the properties and enums do not exist.

**Step 3: Implement backward-compatible persisted values**

Add:

```swift
enum HostAgentUpdaterSetup: String, Codable, Sendable {
    case unchecked
    case ready
    case skipped
    case failed

    var needsWarning: Bool { self != .ready }
}

enum HostGatekeeperPolicy: String, Codable, Sendable {
    case manualApproval
    case verifiedVendorArtifacts
}
```

Add both properties to `Host`, default them in the initializer, decode them with
`decodeIfPresent(...) ?? default`, and encode them. Do not put remote logs,
credentials, or mutable service health into `Host`; this state records only the
last onboarding choice.

**Step 4: Re-run the focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/Host.swift \
  app/MultiSessionAIManager/Tests/HostStoreTests.swift
git commit -m "feat: persist host updater setup choices"
```

### Task 2: Define the fixed tool/version registry

**Files:**
- Create: `app/MultiSessionAIManager/Core/AgentToolUpdate.swift`
- Create: `app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift`

**Step 1: Write failing registry, parser, and comparison tests**

Cover:

- registry order is Claude Code, Codex, Antigravity;
- only `claude`, `codex`, and `agy` executable names are present;
- Herdr kinds are `claude`, `codex`, and `agy`/the actual JSON kind Herdr emits;
- resume arguments are `--resume ID`, `resume ID`, and `--conversation ID`;
- `/exit` is the clean exit command for all three;
- installed-version parsing tolerates vendor prefixes/suffixes;
- numeric semantic ordering treats `2.1.10` as newer than `2.1.9`;
- prerelease comparison is deterministic;
- malformed and latest-unknown values never become update-available;
- install-method parsing distinguishes Homebrew, npm, pnpm, bun, native, and ambiguous.

Use a value model shaped like:

```swift
enum AgentToolID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case antigravity
}

enum AgentInstallMethod: String, Codable, Sendable {
    case homebrew, npm, pnpm, bun, native, unknown, ambiguous
}

struct AgentToolVersion: Equatable, Codable, Sendable {
    let tool: AgentToolID
    let installed: String?
    let latest: String?
    let channel: String?
    let method: AgentInstallMethod
    let executablePath: String?
    let error: String?
}
```

**Step 2: Run the focused tests and verify failure**

Run the test command from Task 1 with
`-only-testing:MultiSessionAIManagerTests/AgentToolUpdateTests`.

Expected: FAIL because the types are missing.

**Step 3: Implement the minimum registry and pure parsers**

`AgentToolDefinition` must contain only data selected by `AgentToolID`:

```swift
struct AgentToolDefinition: Equatable, Sendable {
    let id: AgentToolID
    let displayName: String
    let executable: String
    let herdrKinds: Set<String>
    let exitCommand: String
    let resumeArguments: @Sendable (String) -> [String]
}
```

Keep version parsing and comparison pure and independent of SSH. Normalize a
leading `v` and vendor text, but retain the original display string.

**Step 4: Re-run the focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentToolUpdate.swift \
  app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift
git commit -m "feat: add fixed AI tool update registry"
```

### Task 3: Build bounded version discovery

**Files:**
- Modify: `app/MultiSessionAIManager/Core/AgentToolUpdate.swift`
- Modify: `app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift`

**Step 1: Add failing probe-command and marker-parser tests**

Use stable line markers rather than parsing login-shell prose:

```text
MSAM_TOOL_BEGIN:claude
installed=2.1.260
latest=2.1.260
method=native
channel=latest
path=/Users/alice/.local/bin/claude
MSAM_TOOL_END:claude
```

Tests must prove:

- shell noise outside markers is ignored;
- a missing executable is represented as not installed;
- a failed latest lookup becomes `latest == nil` plus an error;
- a path containing spaces remains a value, not executable shell;
- every generated probe has a timeout/output limit at its SSH call site;
- the latest endpoints are fixed constants:
  - Claude native: `https://downloads.claude.ai/claude-code-releases/latest`
  - Codex native: `https://releases.openai.com/codex/channels/latest`
  - Antigravity: the platform manifest under Google's documented updater endpoint;
- Homebrew and Node-owned installs ask their owner for the comparable version,
  not a different native channel.

**Step 2: Run and observe the expected failures**

Run the AgentToolUpdate test target filter.

**Step 3: Implement `AgentToolVersionProbe`**

Add fixed command construction and:

```swift
enum AgentToolVersionProbe {
    static let timeout = Duration.seconds(45)
    static let outputLimit = 256 * 1024

    static func command(for tool: AgentToolID) -> String
    static func parse(_ output: String, tool: AgentToolID) throws -> AgentToolVersion
    static func fetch(_ tool: AgentToolID, using service: SSHService) async throws
        -> AgentToolVersion
}
```

The command must resolve the active executable first, detect its owner without
following unbounded user input, and fetch only the source for that owner/channel.
Use `curl` with connect/max-time bounds. Never run an update as part of a scan.

**Step 4: Run the tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentToolUpdate.swift \
  app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift
git commit -m "feat: probe installed and latest agent versions"
```

### Task 4: Define and validate the durable host-helper protocol

**Files:**
- Create: `app/MultiSessionAIManager/Core/AgentUpdateRequest.swift`
- Create: `app/MultiSessionAIManager/Tests/AgentUpdateRequestTests.swift`

**Step 1: Write failing protocol tests**

Model immutable requests and status snapshots:

```swift
struct AgentRollTarget: Equatable, Codable, Sendable {
    let herdrSession: String
    let socketPath: String
    let paneID: String
    let foregroundPID: Int32?
    let tool: AgentToolID
    let conversationID: String
}

struct AgentUpdateRequest: Equatable, Codable, Sendable {
    let protocolVersion: Int
    let batchID: UUID
    let requestedTools: Set<AgentToolID>
    let targets: [AgentRollTarget]
    let gatekeeperPolicy: HostGatekeeperPolicy
}
```

Tests must reject:

- unsupported protocol versions/tools;
- empty requested-tool sets;
- duplicate session/pane targets;
- relative socket paths;
- tabs/newlines/NULs in line-protocol fields;
- invalid pane identifiers and unbounded conversation references;
- targets not belonging to the fixed three-tool registry.

Prove serialization is deterministic, contains no command string, and includes
all three tool kinds when given a cross-tool inventory.

**Step 2: Run and verify failure**

Run with `-only-testing:MultiSessionAIManagerTests/AgentUpdateRequestTests`.

**Step 3: Implement validation and line-protocol serialization**

Use a tab-separated, versioned format that `/bin/sh` can read without `jq`:

```text
MSAM_AGENT_UPDATE_REQUEST\t1
BATCH\t<uuid>
POLICY\tmanualApproval
UPDATE\tclaude
TARGET\t<session>\t<socket>\t<pane>\t<pid-or-dash>\t<tool>\t<conversation>
END
```

The serializer validates before emitting. Parsing host status uses a separate
versioned marker protocol and returns unknown on extra future fields.

**Step 4: Re-run the focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentUpdateRequest.swift \
  app/MultiSessionAIManager/Tests/AgentUpdateRequestTests.swift
git commit -m "feat: define durable agent update requests"
```

### Task 5: Implement the host-side rolling worker test-first

**Files:**
- Create: `app/MultiSessionAIManager/Resources/msam-agent-updater.sh`
- Create: `scripts/test-msam-agent-updater.sh`
- Modify: `app/MultiSessionAIManager/project.yml`

**Step 1: Create the failing black-box shell harness**

The harness must use `mktemp -d`, override `HOME`,
`MSAM_AGENT_UPDATER_STATE_DIR`, and `PATH`, and install fake `herdr`, `claude`,
`codex`, `agy`, `brew`, `npm`, and `curl` executables. It must never touch the
developer's real Herdr sessions or tool installations.

Initial cases:

- `protocol` reports exactly the supported helper version;
- invalid request fields are rejected before a fake command runs;
- failed tool update leaves every agent untouched;
- idle/done agents receive `/exit` and the correct resume command;
- working agents remain queued until a later invocation reports done;
- blocked/unknown/error agents receive no input;
- every batch includes targets for all three kinds even when only Codex updates;
- unrelated pane PID fixtures remain unchanged;
- identity/session-reference changes stop the target;
- service restart from each durable phase is idempotent;
- restore failure is attempted three times and then stops;
- status/log output is bounded.

**Step 2: Run the shell harness and verify failure**

Run:

```bash
bash scripts/test-msam-agent-updater.sh
```

Expected: FAIL because the resource script does not exist.

**Step 3: Implement the minimum POSIX worker**

The helper supports only:

```text
msam-agent-updater.sh protocol
msam-agent-updater.sh verify-service
msam-agent-updater.sh status
msam-agent-updater.sh run-once
msam-agent-updater.sh service
```

Implementation requirements:

- `set -eu`, a private umask, fixed state subdirectories, atomic temp+rename
  writes, and a lock directory;
- no `eval`, no sourced request, and no execution of request field contents;
- method-specific update functions selected only by tool/method enums;
- re-probe installed path/version before recording update success;
- persist update completion before attempting any conversation exit;
- call Herdr through the captured socket path passed as an environment value;
- re-read status/session identity immediately before exit;
- send only `/exit` to an eligible target;
- wait for the original agent process to leave before `pane run`/`agent start`;
- quote validated conversation IDs as one argument;
- preserve old foreground PID/generation evidence so restart recovery can tell
  an already-resumed process from the original process;
- never call `session stop`, `server stop`, `pane close`, `kill`, `sudo`, or a
  generic request-supplied command;
- service loop uses short interruptible waits and re-enters `run-once` so a
  crash cannot skip durable phases.

For Antigravity native updates, follow the official platform manifest,
download to staging, verify its SHA-512 digest, and replace atomically. Do not
delete the current executable before a verified replacement exists.

**Step 4: Run the shell harness**

Expected: all cases print PASS and exit 0.

**Step 5: Add the helper as an explicitly copied app resource**

Update `project.yml` if necessary so the `.sh` is copied as data, then run:

```bash
cd app/MultiSessionAIManager
xcodegen generate
xcodebuild -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .ddp build
```

Expected: BUILD SUCCEEDED and the built `.app` contains
`msam-agent-updater.sh`.

**Step 6: Commit**

```bash
git add app/MultiSessionAIManager/Resources/msam-agent-updater.sh \
  app/MultiSessionAIManager/project.yml scripts/test-msam-agent-updater.sh
git commit -m "feat: add durable host agent update worker"
```

### Task 6: Install and verify the per-user service

**Files:**
- Create: `app/MultiSessionAIManager/Core/AgentUpdaterInstaller.swift`
- Create: `app/MultiSessionAIManager/Tests/AgentUpdaterInstallerTests.swift`

**Step 1: Write failing platform/install tests**

Test with `FakeSSHTransport` that:

- the helper is loaded from the bundle and uploaded over SFTP, not shell echo;
- install discovers `$HOME`, `uname -s`, UID, and platform before selecting a
  service definition;
- Darwin writes `~/Library/LaunchAgents/com.codem0nky87.msam-agent-updater.plist`;
- Linux writes `~/.config/systemd/user/msam-agent-updater.service`;
- unsupported OS returns instructions and performs no install;
- neither service contains root, sudo, shell-interpreted request text, or a
  password field;
- launchd bootstrap and systemd enable/start are bounded;
- verification requires helper protocol match, active service, writable state,
  and a successful request/response self-test;
- Linux reports linger-disabled separately;
- a repair replaces only MSAM-owned helper/service files and verifies again;
- partial/ambiguous SSH completion never claims ready without final verification.

**Step 2: Run the focused tests and verify failure**

Run with
`-only-testing:MultiSessionAIManagerTests/AgentUpdaterInstallerTests`.

**Step 3: Implement `AgentUpdaterInstaller`**

Use:

```swift
@MainActor @Observable
final class AgentUpdaterInstaller {
    enum State: Equatable { /* idle, probing, absent, approval, ready, failed */ }
    let connection: HostConnection
    func probe() async
    func installOrRepair(policy: HostGatekeeperPolicy) async
}
```

Keep platform/service templates in Swift value functions whose only variable is
the previously validated absolute home path/UID. Install paths are under the
SSH user's home. Verification output, not remote exit status alone, is the
authority.

**Step 4: Re-run the focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentUpdaterInstaller.swift \
  app/MultiSessionAIManager/Tests/AgentUpdaterInstallerTests.swift
git commit -m "feat: install per-user agent updater service"
```

### Task 7: Inventory every eligible Herdr conversation

**Files:**
- Create: `app/MultiSessionAIManager/Core/HerdrAgentInventory.swift`
- Create: `app/MultiSessionAIManager/Tests/HerdrAgentInventoryTests.swift`

**Step 1: Write failing JSON fixture tests**

Use captured/documented Herdr 0.8.2 response shapes for `session list --json`,
`agent list`, `agent get`, and `pane process-info`. Cover:

- default and multiple named sessions;
- all three supported kinds and unrelated agents;
- `idle`, `done`, `working`, `blocked`, `unknown`, and `error`;
- native `agent_session.value` extraction;
- missing/stale/duplicate native references;
- pane ID, socket path, and foreground PID extraction;
- shell noise before JSON;
- malformed JSON produces inventory-unavailable, never an empty-safe result;
- the final target list includes all three tools for a one-tool update;
- integration status must be current before a target is eligible.

**Step 2: Run and verify failure**

Run with `-only-testing:MultiSessionAIManagerTests/HerdrAgentInventoryTests`.

**Step 3: Implement pure parsing and bounded SSH inventory**

Add:

```swift
enum HerdrAgentLifecycle: String, Codable, Sendable {
    case idle, working, blocked, done, error, unknown
}

enum HerdrAgentInventory {
    static func parseSessions(_ output: String) throws -> [HerdrSessionEndpoint]
    static func parseAgents(_ output: String, session: HerdrSessionEndpoint) throws
        -> [HerdrAgentSnapshot]
    static func fetch(using service: SSHService) async throws -> [HerdrAgentSnapshot]
}
```

Fetch sessions first, then run fixed `agent list` commands scoped through the
validated socket path. Bound each call and total output. Never treat a failed
named-session query as "no agents".

**Step 4: Re-run focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/HerdrAgentInventory.swift \
  app/MultiSessionAIManager/Tests/HerdrAgentInventoryTests.swift
git commit -m "feat: inventory restorable Herdr conversations"
```

### Task 8: Add the host management model and atomic enqueue flow

**Files:**
- Create: `app/MultiSessionAIManager/Core/AgentUpdateManager.swift`
- Create: `app/MultiSessionAIManager/Tests/AgentUpdateManagerTests.swift`

**Step 1: Write failing model tests**

Test:

- refresh publishes three ordered rows and service health;
- overlapping refreshes are generation-fenced;
- latest lookup errors remain visible and do not offer Update;
- update availability uses semantic comparison;
- preflight refuses any captured conversation without current integration or
  native reference;
- requested Codex update contains every Claude/Codex/Antigravity target;
- multiple tool selections coalesce into one request;
- request writes to a temporary absolute host path over SFTP, then a fixed
  helper command atomically accepts it;
- an existing active batch is returned rather than duplicated;
- cancellation never publishes stale progress;
- `blocked`/`unknown` counts appear as attention, not completed;
- output/log messages are bounded and secrets are not persisted.

**Step 2: Run and verify failure**

Run with `-only-testing:MultiSessionAIManagerTests/AgentUpdateManagerTests`.

**Step 3: Implement the observable manager**

Use one shared `HostConnection` and explicit state:

```swift
@MainActor @Observable
final class AgentUpdateManager {
    enum State: Equatable { case idle, refreshing, ready, preparing, submitting, failed(String) }
    private(set) var tools: [AgentToolVersion] = []
    private(set) var serviceStatus: AgentUpdaterServiceStatus?
    private(set) var batch: AgentUpdateBatchStatus?

    func refresh() async
    func prepareUpdate(_ tools: Set<AgentToolID>) async throws -> AgentUpdatePreview
    func submit(_ preview: AgentUpdatePreview) async
}
```

Do not start a detached Swift monitoring loop. Settings refreshes durable host
truth on appearance/manual refresh; the host service owns progress after
submission.

**Step 4: Re-run focused tests**

Expected: PASS.

**Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/AgentUpdateManager.swift \
  app/MultiSessionAIManager/Tests/AgentUpdateManagerTests.swift
git commit -m "feat: coordinate host-owned agent update requests"
```

### Task 9: Add onboarding service setup, approvals, and skip impact

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Hosts/HostSetupHelpSheet.swift`
- Modify: `app/MultiSessionAIManager/UI/Hosts/HostEditView.swift`
- Modify: `app/MultiSessionAIManager/UI/Hosts/HostListView.swift`
- Create: `app/MultiSessionAIManager/Tests/HostAgentUpdaterPresentationTests.swift`
- Modify: `app/MultiSessionAIManager/UITests/HostFlowUITests.swift`

**Step 1: Write failing presentation-policy tests**

Extract pure presentation helpers and verify:

- ready has no degraded warning;
- unchecked, skipped, and failed each explain that background checks, durable
  queueing, and disconnected rolling restores are unavailable;
- manual Gatekeeper approval is the default;
- verified-artifact policy copy says exact artifact/signature/notarization and
  never promises arbitrary bypass;
- Linux linger, macOS login-domain, Keychain, administrator-action, and
  unsupported-platform messages are distinct;
- Skip requires confirmation and persists `.skipped`;
- successful verification persists `.ready`; failure persists `.failed`.

Add a UI test that saves a new host and observes Host Setup instead of returning
straight to the list, then uses the explicit skip flow and sees the warning.

**Step 2: Run focused unit/UI tests and verify failure**

Run the presentation test filter, then:

```bash
xcodebuild -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .ddp \
  -only-testing:MultiSessionAIManagerUITests/HostFlowUITests test
```

**Step 3: Add the fifth Host Setup card**

After Session Restore, show **5 · Background agent updates** with:

- service/helper status;
- Install or Repair;
- manual vs verified-vendor Gatekeeper toggle and risk explanation;
- platform-specific approval instructions;
- Test Again;
- Skip for Now with an impact confirmation.

Construct `AgentUpdaterInstaller` from the same `HostConnection` already shared
by Herdr/plugins/integrations. Ensure sheet teardown cancels and awaits its
operation before disconnecting.

**Step 4: Route newly saved hosts into onboarding**

Add an `onSaved(Host, Bool)` callback to `HostEditView`. In `HostListView`, use a
single sheet route or an edit-sheet `onDismiss` handoff so a newly added host
opens Host Setup after the editor is dismissed. Editing an existing host keeps
the current flow. Avoid leaving the original editor in a "new" state that could
save a duplicate host.

**Step 5: Add persistent host-list warning**

Render a warning icon/short label when `host.agentUpdaterSetup.needsWarning`.
Do not make skipped hosts unusable.

**Step 6: Run focused tests**

Expected: unit and HostFlow UI tests PASS.

**Step 7: Commit**

```bash
git add app/MultiSessionAIManager/UI/Hosts/HostSetupHelpSheet.swift \
  app/MultiSessionAIManager/UI/Hosts/HostEditView.swift \
  app/MultiSessionAIManager/UI/Hosts/HostListView.swift \
  app/MultiSessionAIManager/Tests/HostAgentUpdaterPresentationTests.swift \
  app/MultiSessionAIManager/UITests/HostFlowUITests.swift
git commit -m "feat: onboard the host agent updater service"
```

### Task 10: Add per-host Agent Updates settings UI

**Files:**
- Create: `app/MultiSessionAIManager/UI/Hosts/HostAgentUpdatesSheet.swift`
- Modify: `app/MultiSessionAIManager/UI/Hosts/HostEditView.swift`
- Create: `app/MultiSessionAIManager/Tests/AgentUpdatePresentationTests.swift`
- Modify: `app/MultiSessionAIManager/UITests/HostFlowUITests.swift`

**Step 1: Write failing presentation tests**

Cover row/button behavior for:

- installed/current;
- update available;
- latest unknown;
- not installed;
- ambiguous install;
- administrator action required;
- Gatekeeper approval required;
- service absent/outdated/failed;
- active progress counts (`restored`, `working`, `attention`, `retrying`,
  `failed`);
- confirmation copy explicitly states that all three agents' conversations will
  roll and ordinary panes will remain running.

**Step 2: Run and verify failure**

Run the AgentUpdatePresentation test filter.

**Step 3: Implement the sheet**

Add an **AI Agent Updates** card to each existing Host editor. Opening it creates
one `HostConnection`, `AgentUpdaterInstaller`, and `AgentUpdateManager`, connects
once, refreshes lazily, and disconnects on dismissal.

The sheet shows:

- service/helper health and last check;
- Claude Code, Codex, Antigravity rows with installed/latest, channel, method;
- Update only when a newer compatible version is confirmed;
- Refresh, Complete Setup, Repair Service, Approval Required, or Administrator
  Action Required as appropriate;
- one confirmation dialog based on `AgentUpdatePreview`;
- durable batch progress and bounded per-conversation result log.

Do not poll while the sheet is hidden. A modest task-based refresh while visible
may re-read status, but cancel it on disappear and do not rely on it to advance
the batch.

**Step 4: Add UI coverage**

Use app launch fixtures/fake manager injection where existing UI-test support
allows it. Assert accessibility identifiers for the section, three rows,
refresh, confirmation, and degraded warning.

**Step 5: Run unit and UI tests**

Expected: PASS.

**Step 6: Commit**

```bash
git add app/MultiSessionAIManager/UI/Hosts/HostAgentUpdatesSheet.swift \
  app/MultiSessionAIManager/UI/Hosts/HostEditView.swift \
  app/MultiSessionAIManager/Tests/AgentUpdatePresentationTests.swift \
  app/MultiSessionAIManager/UITests/HostFlowUITests.swift
git commit -m "feat: show per-host AI agent updates"
```

### Task 11: Add macOS verified-artifact enforcement

**Files:**
- Modify: `app/MultiSessionAIManager/Resources/msam-agent-updater.sh`
- Modify: `scripts/test-msam-agent-updater.sh`
- Modify: `app/MultiSessionAIManager/Core/AgentToolUpdate.swift`
- Modify: `app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift`

**Step 1: Add failing Gatekeeper policy fixtures**

Fake `uname`, `codesign`, `spctl`, and `xattr`. Prove:

- manual policy never runs `xattr`;
- verified policy requires strict code-signature success;
- Gatekeeper assessment/notarization must succeed;
- TeamIdentifier/vendor identity must exactly match the fixed registry;
- assessed path must be the resolved artifact installed in this update;
- only `com.apple.quarantine` on that one exact path is removed;
- a directory, parent path, glob, symlink swap, unsigned artifact, mismatched
  identity, or unavailable identity stops at approval-required;
- no script contains `spctl --master-disable`, `--global-disable`, `Anywhere`,
  recursive `xattr`, AppleScript/UI clicking, or Accessibility control;
- non-macOS never enters this branch.

**Step 2: Run and verify failure**

Run the shell harness and AgentToolUpdate tests.

**Step 3: Add fixed publisher identities only when verified from vendor artifacts**

Research the actual signed artifacts for the supported install paths. Add a
publisher identity to a tool definition only when the vendor provides a stable
identity and the downloaded artifact is code signed/notarized. An absent stable
identity means that tool remains manual-approval-only; do not invent or weaken
the check.

**Step 4: Implement exact-artifact handling**

Run `codesign --verify --strict`, inspect the TeamIdentifier/designated
requirement, then `spctl --assess --type execute`. Re-resolve the path and inode
before the final non-recursive `xattr -d com.apple.quarantine -- "$path"`.
Record approval-required instead of treating failure as update failure; existing
conversations must remain running until executable verification succeeds.

**Step 5: Run the focused tests**

Expected: PASS.

**Step 6: Commit**

```bash
git add app/MultiSessionAIManager/Resources/msam-agent-updater.sh \
  scripts/test-msam-agent-updater.sh \
  app/MultiSessionAIManager/Core/AgentToolUpdate.swift \
  app/MultiSessionAIManager/Tests/AgentToolUpdateTests.swift
git commit -m "feat: gate automatic macOS quarantine handling"
```

### Task 12: Document host setup and live diagnostics

**Files:**
- Modify: `docs/host-setup.md`
- Modify: `docs/development.md`
- Modify: `docs/architecture.md`

**Step 1: Add documentation checks to the shell harness**

Assert the operator commands documented below agree with helper subcommands and
service labels. This catches stale copy/paste instructions.

**Step 2: Document the user contract**

Include:

- what version/current/latest means and why latest may be unknown;
- every supported installation method and no silent migration;
- all-three-agent rolling scope;
- idle/done/working/blocked/unknown behavior;
- three-attempt limit;
- ordinary-process non-interference;
- onboarding skip impacts;
- macOS manual approval and verified-artifact opt-in;
- Linux linger/manual action;
- uninstall/repair locations and commands without deleting user agent state.

**Step 3: Add disposable-host diagnostics**

Document exact macOS and Linux checks for:

- service active and survives iPad disconnect;
- a working fake/real conversation finishes and then restores;
- native conversation identity is unchanged;
- ordinary pane PID remains unchanged;
- blocked conversation remains untouched;
- helper/service restart resumes the batch;
- Gatekeeper manual and verified paths.

Label all process-stopping checks destructive and require a disposable host.

**Step 4: Run documentation/script checks**

```bash
bash scripts/test-msam-agent-updater.sh
git diff --check
```

Expected: PASS.

**Step 5: Commit**

```bash
git add docs/host-setup.md docs/development.md docs/architecture.md \
  scripts/test-msam-agent-updater.sh
git commit -m "docs: explain host-owned agent update operations"
```

### Task 13: Full verification and review

**Files:**
- Modify only files required by verified fixes.

**Step 1: Regenerate the project and check repository hygiene**

```bash
cd app/MultiSessionAIManager
xcodegen generate
cd ../..
git diff --check
git status --short
```

Expected: no whitespace errors; only intentional tracked changes. Generated
`.xcodeproj` and `.ddp` remain ignored.

**Step 2: Run host-worker black-box tests**

```bash
bash scripts/test-msam-agent-updater.sh
```

Expected: PASS.

**Step 3: Run all unit and UI tests**

```bash
cd app/MultiSessionAIManager
xcodebuild -scheme MultiSessionAIManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .ddp test
```

Expected: `** TEST SUCCEEDED **`, all existing 607 unit tests plus new tests,
and all UI tests pass.

**Step 4: Run a release build**

```bash
xcodebuild -scheme MultiSessionAIManager \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .ddp-release \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

**Step 5: Perform focused code review**

Use @requesting-code-review. Review specifically for command injection,
unbounded remote work, service lifecycle races, accidental arbitrary-pane
termination, stale generation publication, credentials in state/logs, and
Gatekeeper weakening. Apply only evidence-backed fixes and re-run the affected
checks.

**Step 6: Run disposable-host manual diagnostics**

Use only authorized disposable macOS/Linux hosts. Do not run stop/update tests
against a workstation or production session. Record which cases were executed
and which remain manual release gates.

**Step 7: Commit verification fixes**

```bash
git add <only-files-changed-by-review>
git commit -m "fix: harden host agent update rollout"
```

Skip the commit if review required no changes.

**Step 8: Finish the branch**

Use @finishing-a-development-branch to present merge/PR/cleanup choices after
all automated checks and required manual gates are reported accurately.
