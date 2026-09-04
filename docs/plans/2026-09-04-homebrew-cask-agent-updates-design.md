# Homebrew Cask Agent Updates Design

## Problem

Claude Code and Codex can be installed as Homebrew casks. The current inventory
probe checks only `brew list --versions`, which treats named arguments as
formulae on current Homebrew versions. As a result, valid cask symlinks under
`/opt/homebrew/bin` are reported as having unknown ownership and the app shows
"Administrator Action Required."

The updater repeats the same formula-only ownership check, so changing only the
UI probe would allow an update button that the host-owned worker could not
execute.

## Approved approach

Model Homebrew formulae and Homebrew casks as distinct installation methods.
For every supported Homebrew package, the inventory probe will explicitly test
both `brew list --formula --versions` and `brew list --cask --versions`. A
single match is accepted only when the selected executable is the package
manager's expected launcher under the Homebrew prefix. Multiple package-manager
matches remain ambiguous and fail closed.

Latest-version lookup and update execution will remain owner-specific:

- Formula: `brew info --formula --json=v2` and
  `brew upgrade --formula --yes <package>`.
- Cask: `brew info --cask --json=v2` and
  `brew upgrade --cask --yes <package>`.

The UI will display both methods as recognizable Homebrew ownership, with a
specific "Homebrew cask" label for casks. No package is uninstalled or migrated,
and no generic ownership-repair command is added.

## Session safety

The existing host-owned rolling coordinator remains the only path that invokes
an update. It will continue to wait for working sessions, capture every eligible
conversation, exit the affected agent sessions, run the owner-matched update,
and restore all captured sessions with the existing three-attempt limit.

The cask fix changes only owner detection and the package-manager command. It
does not bypass session capture, restore, identity checks, or macOS Gatekeeper
handling.

## Error handling

- Formula plus cask, or Homebrew plus a Node package manager, is ambiguous.
- A package-manager match whose expected launcher does not equal `command -v`
  is ambiguous.
- Unknown, ambiguous, unreadable, or failed lookups remain non-updatable.
- Homebrew prompts are disabled only for the named update by using `--yes`; no
  global Homebrew configuration is changed.
- Update success still requires the selected executable path to remain stable
  and its version to increase.

## Verification

Add Swift command-contract tests and a shell integration fixture that reproduces
a Homebrew cask-owned Codex install. Demonstrate the new tests fail before the
implementation, then pass after the minimal change. Run ShellCheck, the complete
host updater harness, the relevant Swift suites, and the full unit/UI suite
before merging and producing a signed TestFlight archive.
