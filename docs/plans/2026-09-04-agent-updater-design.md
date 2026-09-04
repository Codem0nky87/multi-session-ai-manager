# Host-Owned AI Agent Updates

**Date:** 2026-09-04
**Status:** Approved

## Goal

Show the installed and latest versions of Claude Code, Codex, and Antigravity
under each saved host, and let the user request an installation-aware update.
The update must continue when the iPad disconnects, then roll every restorable
AI conversation on that host onto freshly started processes without terminating
ordinary shells, servers, tests, or other commands.

## Decisions

- Update coordination is owned by a per-user service on the host, not by the
  iPad lifecycle.
- The service manages only Claude Code, Codex, and Antigravity through a fixed
  compiled/installed registry.
- A request for any one of those tools creates a maintenance batch covering
  **all detected conversations for all three tools**. It is not limited to the
  conversations using the updated executable.
- The rollout is per conversation. It never restarts a whole Herdr server or
  session, because that would terminate unrelated pane processes that Herdr
  cannot reconstruct.
- Herdr's semantic agent states are authoritative. `idle` and `done` are safe
  to roll; `working` waits until it settles; `blocked`, `unknown`, and `error`
  require attention and are not terminated.
- A conversation is eligible only when Herdr has a current official integration
  and a native session reference that can be resumed.
- Restore is attempted at most three times per conversation. Exhaustion leaves
  the pane and batch in a visible needs-attention state rather than retrying
  forever.
- The service runs as the configured SSH user. It does not run as root, invoke
  `sudo` automatically, or store an administrator/Keychain password.
- Gatekeeper is never driven through automatic UI clicks and is never disabled
  globally.

## Options considered

### Per-user host service — selected

A small MSAM-owned helper persists requests and progress on the host. A macOS
LaunchAgent or Linux systemd user service runs it independently of the iPad.
This is the only option that reliably satisfies "act as soon as the working
conversation completes" while the iPad is suspended or disconnected.

### Herdr plugin

A plugin could receive agent events, but it would be tied to each individual
Herdr server lifecycle. Coordinating a single durable update across several
named sessions would require shared locking between plugin instances, and the
coordinator could disappear during the lifecycle it is managing.

### iPad coordinator

The app could poll Herdr and perform every step over SSH. This is simpler but
cannot continue reliably after iOS suspends the app, so it does not meet the
background requirement.

## Components

### Host updater service

The app installs a versioned `msam-agent-updater` helper into the SSH user's
home directory together with the platform service definition. Its durable
state contains:

- the helper protocol/version;
- the last version scan and any scan errors;
- immutable maintenance-batch requests;
- the captured Herdr session, pane, agent kind, and native conversation
  reference for each rollout target;
- per-target attempts and current phase;
- a bounded operation log and final result.

Requests use an allowlisted, versioned data format. Tool names, update
strategies, exit commands, and resume argument shapes are selected from the
helper's registry rather than supplied as executable shell text. Values learned
from the host are parsed and validated before use; they are never interpolated
unquoted into commands.

The service serializes maintenance batches with an exclusive lock. It performs
no automatic downgrade and does not silently change an installation from one
package manager to another.

### iPad host manager

The app reuses Host Setup's authenticated `HostConnection` to:

- probe/install/repair the helper and service definition;
- run bounded version and readiness probes;
- inventory every running named Herdr session and the three supported agent
  kinds;
- verify current integrations and native conversation references;
- submit an atomic maintenance request;
- read durable status and logs.

The app may disappear after the request is accepted. Returning to Settings
reads the host's current truth rather than relying on an in-memory task.

### Tool registry

Each fixed tool record contains:

- executable aliases and installed-version parser;
- installation-method probes;
- release channel and authoritative latest-version source;
- update operation for each supported installation method;
- macOS publisher/signing expectations where available;
- clean interactive exit command;
- Herdr kind and native resume argument shape.

The initial resume commands follow Herdr's documented native restore contract:

- Claude Code: `claude --resume <id>`
- Codex: `codex resume <id>`
- Antigravity: `agy --conversation <id>`

## Version discovery and update policy

Each scan reports installed version, latest version, configured release
channel, resolved executable path, installation method, last check time, and
any error. "Latest unknown" is distinct from "up to date" and does not offer
an Update button.

Latest-version lookup respects the active installation and channel. For
example, a Homebrew install is compared with the relevant cask rather than a
different native channel. The updater uses the detected installation owner:
Homebrew remains Homebrew, npm remains npm, and a native install uses its
official native updater. Mixed or ambiguous installations stop with repair
guidance instead of choosing a path heuristically.

An update runs and then re-probes the resolved executable. No conversation is
stopped unless the requested new executable has been verified successfully.
System-owned paths or an updater that requests elevation produce an
"Administrator action required" result with exact instructions; the service
does not supply credentials.

## Rolling conversation lifecycle

1. **Preflight.** Refresh tool/install information and enumerate all live
   Claude, Codex, and Antigravity conversations across all running Herdr
   sessions. Require a current integration and native session reference for
   each captured conversation.
2. **Confirm.** Show the tools to update, conversation count, any waiting
   states, and the fact that all three agent kinds will be rolled. Multiple
   tool selections are coalesced into one batch and one rollout.
3. **Install.** Update each requested executable through its existing owner and
   verify the installed version/path. Existing agent processes continue using
   their already-loaded binary.
4. **Select.** Re-read a captured target immediately before acting. Roll only
   `idle` or `done`. Wait for `working`. Surface `blocked`, `unknown`, `error`,
   missing, or changed identity without sending input.
5. **Exit.** Send only the tool registry's clean local exit command. Wait until
   the same pane has returned to an available shell; do not signal or close the
   pane's process tree speculatively.
6. **Resume.** Start the canonical agent in that same pane with the validated
   native conversation reference. Verify that Herdr detects the expected kind,
   session identity, and settled/working lifecycle after launch.
7. **Retry.** Retry a failed target no more than three times with bounded waits.
   Continue independent safe targets, but keep the overall batch in
   needs-attention until every captured target is restored or has a reported
   terminal failure.

If a target's identity changes before the service acts, the service does not
resurrect or overwrite it. It reports the change and requires a fresh user
decision. New conversations started after the executable was updated naturally
use the new version and are not added retroactively to the immutable batch.

## Host onboarding

Saving a new host proceeds into Host Setup rather than silently dismissing the
editor. The wizard performs, in order:

1. private route and SSH authentication test;
2. Herdr install/version verification;
3. native agent integration install/verification;
4. per-user updater helper and service install;
5. service start, request/response, persistence, and version-provider tests;
6. platform approval/readiness tests;
7. a final capability summary.

The host remains usable if setup is explicitly skipped. A persisted warning on
the host list and Host Settings then explains the precise degraded behavior:
foreground version inspection may still work, but background scans, durable
queued updates, and disconnected rolling restores do not.

Existing hosts begin in an "automation not checked" state and receive the same
Complete Setup/Repair flow. The app compares the installed helper protocol with
the bundled version so future builds can repair or upgrade it.

### macOS

The helper is installed for the SSH user and loaded as a LaunchAgent. Setup
tests that it is running in the correct user context and reports whether an
active login session or other host policy is required. It does not install a
privileged LaunchDaemon.

The pictured "downloaded from the Internet" dialog is a standard
Gatekeeper/quarantine first-open confirmation. Default policy is to pause with
"Approval required," explain how to approve the exact application on the Mac,
and offer **Test again**.

An explicit per-host option, **Allow verified vendor updates without first-open
confirmation**, may remove quarantine only from the exact newly installed
artifact after all of these checks succeed:

- strict code-signature verification;
- Gatekeeper/notarization assessment;
- expected vendor identity from the fixed tool registry;
- resolved path matches the artifact just updated.

Failure or missing identity always falls back to manual approval. The app does
not use Accessibility automation, `spctl --master-disable`, an "Anywhere"
policy, or a broad recursive `xattr` operation. Keychain/authentication prompts
are also manual; onboarding shows vendor-specific instructions and re-runs a
bounded readiness test afterward.

### Linux

The helper is installed as a systemd user service and enabled immediately.
Onboarding disconnects/re-probes or performs an equivalent persistence test.
If user lingering or local policy is required, it shows the exact host-side
administrative step and a Test Again action. It does not request or retain the
administrator password.

## Settings UI

Each saved host gains an **AI Agent Updates** section. It connects lazily and
shows:

- updater service health, helper version, last successful check, and setup or
  repair action;
- Claude Code, Codex, and Antigravity rows with installed/latest versions,
  channel, installation method, and check error;
- Update only for a confirmed newer compatible version;
- Refresh and, when applicable, Administrator Action Required or Approval
  Required;
- active batch progress, including restored, working, waiting for attention,
  retrying, and failed counts;
- a bounded per-conversation result log.

The host list also displays a warning badge when automation setup was skipped,
failed, or has not yet been verified.

## Error handling and safety

- All SSH operations have time and output bounds.
- One batch runs at a time; duplicate requests coalesce or return the existing
  batch.
- Durable phases make service/host restart recovery idempotent.
- A failed executable update leaves every conversation running because rollout
  has not begun.
- `blocked` is never interpreted as idle and is never auto-approved.
- A missing/invalid native reference blocks that conversation before exit.
- A pane identity mismatch stops that target rather than typing into an
  unrelated process.
- Logs redact credentials and retain only bounded diagnostic output.
- No updater path accepts an arbitrary command from the iPad or a remote
  version endpoint.

## Verification

Unit tests cover tool registries, version/install-method parsing, semantic
version ordering, request validation, status parsing, queue transitions, retry
limits, and onboarding/degraded summaries. Fake SSH tests cover upload,
install, verify, repair, and atomic request submission.

Host-helper tests use fake Herdr and agent executables to prove:

- all three kinds are included in every maintenance batch;
- idle/done targets roll immediately and working targets wait;
- blocked/unknown/error targets receive no input;
- native references are passed as arguments without shell injection;
- ordinary pane PIDs are unchanged;
- an update failure stops before any conversation exit;
- service restart resumes the durable phase exactly once;
- three failed restore attempts stop further retries.

SwiftUI/UI tests cover the new-host wizard, skip warning, existing-host repair,
version rows, confirmation summary, progress, and approval-required states.
Disposable macOS and Linux end-to-end tests cover disconnecting the iPad during
a batch and completing a working conversation afterward. A disposable Mac
also verifies manual Gatekeeper approval and the opt-in exact-artifact path
against signed/notarized and rejected fixtures.

## References

- [Herdr CLI reference and semantic agent states](https://github.com/herdrdev/herdr/blob/master/docs/next/website/src/content/docs/cli-reference.mdx)
- [Herdr native session restore](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.8.2/website/src/content/docs/session-state.mdx)
- [Claude Code setup and updater](https://docs.anthropic.com/en/docs/claude-code/getting-started)
- [Codex installation methods](https://github.com/openai/codex/blob/main/README.md)
- [Antigravity CLI installation](https://antigravity.google/docs/cli/install)
- [Apple Gatekeeper user guidance](https://support.apple.com/en-gb/102445)
- [Apple Gatekeeper platform security](https://support.apple.com/en-gb/guide/security/sec5599b66df/web)
