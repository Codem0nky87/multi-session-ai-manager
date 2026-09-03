# Session Restore Design

## Goal

Recover the selected iPad tab after its SSH connection or remote Herdr client
dies, and make Host Setup able to prepare every supported AI agent installed on
the host for Herdr's native conversation restore.

## Scope decisions

- Automatic recovery applies only to the selected tab while the app is active.
- A loss gets three attempts: immediately, after two seconds, and after five
  seconds. After that, the existing manual Retry action remains available.
- Persisted tabs stay lazy. App launch does not connect every tab or start every
  named Herdr session.
- Host Setup detects every supported agent installed on the host and offers one
  explicit action to install or update the matching official Herdr
  integrations.
- Pane screen-history persistence remains disabled and is not changed by the
  app because terminal contents may contain secrets.

## Architecture

### PTY lifecycle signal

`SSHTransport.openPTY`, `SSHService.openPTY`, and `HostConnection.openHerdrPTY`
gain an `onClose` callback. Real and fake transports deliver it exactly once
when remote EOF, an error, or a local close ends the PTY.

`HerdrHostSession` captures its operation generation in the callback. A close
from an old or deliberately stopped channel cannot revive a newer or closed
session. An unexpected close on the active generation starts recovery.

### Selected-tab recovery

`HerdrHostSession` owns a cancellable recovery task and a small injectable
policy containing its delays. Root view lifecycle wiring tells each session
whether it is the selected foreground tab. Disabling automatic recovery
cancels pending retries without closing a healthy session.

Before each retry, the session checks the authenticated SSH connection. A
healthy connection is reused for a dead Herdr PTY; an unhealthy connection is
discarded and redialled. A successful `herdr` or `herdr --session <name>` attach
ends the cycle and reopens the file outbox watch. Three failed attempts end in
the existing `.failed` state. Manual Retry starts a fresh three-attempt budget.

The idle heartbeat continues to detect half-open SSH connections. It hands
recovery to the same coordinator rather than performing a separate one-shot
redial, so EOF and heartbeat failures share limits and race protection.

### Host restore readiness

A new `HerdrIntegrationManager` uses the Host Setup sheet's existing verified
SSH connection. It has a fixed registry copied from Herdr 0.8.2's official
integration target/command mapping. A bounded probe:

1. detects supported agent executables in the remote login PATH;
2. reads `herdr integration status`;
3. classifies detected targets as current, missing, outdated, or failed.

Host Setup shows a fourth card after Herdr is confirmed present. Current
integrations need no action. Missing and outdated integrations are listed, and
one user action installs each target sequentially with
`herdr integration install <target>`. The manager re-probes after every run and
reports partial results instead of treating one agent's failure as failure for
all agents.

Agent and target names are selected only from the fixed registry; no remote
output is interpolated into a shell command.

## Error handling

- Expected local PTY closure during stop is fenced out by generation and active
  state.
- Concurrent EOF, heartbeat, foreground, and Retry triggers coalesce into one
  recovery cycle.
- Cancellation caused by deselection/backgrounding is not shown as a failure.
- Host-key changes remain terminal until the existing explicit trust action.
- Integration probe failures leave terminal sessions usable and show a retryable
  Host Setup error.
- Individual integration failures identify the affected agent and retain
  successful installations.

## Verification

- Transport tests prove close callbacks fire exactly once for EOF and local
  close.
- Session tests prove a healthy-SSH PTY death recovers automatically, an SSH
  loss gets exactly three attempts, success stops retries, deselection cancels
  retries, and manual Retry resets the budget.
- Root-view/model tests prove only the selected foreground tab enables recovery.
- Integration-manager tests cover agent detection, status parsing, safe command
  generation, current/missing/outdated classification, and partial failures.
- Host Setup source/UI tests pin the fourth card and its action wiring.
- The existing hermetic unit suite is run in full. A real-host server-stop test
  remains environment-gated because stopping a user's Herdr server is
  destructive outside a disposable diagnostic host.
