#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
UPDATER="$ROOT/app/MultiSessionAIManager/Resources/msam-agent-updater.sh"
TEST_ROOT=

cleanup() {
  if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "expected [$2] in [$1]" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) fail "did not expect [$2] in [$1]" ;; *) : ;; esac
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

assert_file_contains() {
  file=$1 expected=$2
  grep -F -- "$expected" "$file" >/dev/null \
    || fail "expected [$expected] in $file"
}

new_host() {
  cleanup
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/msam-agent-updater-test.XXXXXX")
  export HOME="$TEST_ROOT/home"
  export MSAM_AGENT_UPDATER_STATE_DIR="$TEST_ROOT/state"
  export MSAM_UPDATER_TEST_DATA="$TEST_ROOT/fake"
  mkdir -p "$HOME" "$MSAM_AGENT_UPDATER_STATE_DIR/incoming" "$TEST_ROOT/bin" "$MSAM_UPDATER_TEST_DATA"
  : > "$MSAM_UPDATER_TEST_DATA/commands.log"
  printf '0.153.1\n' > "$MSAM_UPDATER_TEST_DATA/codex.version"
  printf '0\n' > "$MSAM_UPDATER_TEST_DATA/restore-failures"
  printf '0\n' > "$MSAM_UPDATER_TEST_DATA/update-fails"
  printf 'no\n' > "$MSAM_UPDATER_TEST_DATA/quarantine"
  printf '0\n' > "$MSAM_UPDATER_TEST_DATA/realpath-count"
  export MSAM_FAKE_OS=Linux
  export MSAM_FAKE_CODEX_OWNER=npm
  export MSAM_FAKE_EXIT_MODE=shell
  export MSAM_FAKE_UPDATE_HANG=no
  export MSAM_FAKE_CODEX_AFTER_VERSION=0.153.2
  export MSAM_FAKE_SIGNING_VALID=yes
  export MSAM_FAKE_TEAM=2DC432GLL2
  export MSAM_FAKE_IDENTIFIER=codex
  export MSAM_FAKE_SPCTL_VALID=yes
  export MSAM_FAKE_REALPATH_MODE=artifact

  cp "$ROOT/scripts/fixtures/fake-agent-command.sh" "$TEST_ROOT/bin/fake-agent-command"
  chmod 700 "$TEST_ROOT/bin/fake-agent-command"
  cp "$ROOT/scripts/fixtures/fake-agent-command.sh" "$MSAM_UPDATER_TEST_DATA/signed-artifact"
  chmod 700 "$MSAM_UPDATER_TEST_DATA/signed-artifact"
  mkdir "$MSAM_UPDATER_TEST_DATA/signed-directory"
  ln -s signed-artifact "$MSAM_UPDATER_TEST_DATA/signed-symlink"
  for command in herdr claude codex agy brew npm pnpm bun curl uname codesign spctl xattr realpath stat; do
    ln -s fake-agent-command "$TEST_ROOT/bin/$command"
  done
  export MSAM_AGENT_UPDATER_CODESIGN="$TEST_ROOT/bin/codesign"
  export MSAM_AGENT_UPDATER_SPCTL="$TEST_ROOT/bin/spctl"
  export MSAM_AGENT_UPDATER_XATTR="$TEST_ROOT/bin/xattr"
  export MSAM_AGENT_UPDATER_REALPATH="$TEST_ROOT/bin/realpath"
  export MSAM_AGENT_UPDATER_STAT="$TEST_ROOT/bin/stat"
  export MSAM_AGENT_UPDATER_UNAME="$TEST_ROOT/bin/uname"
  export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
}

seed_agent() {
  pane=$1 status=$2 kind=$3 conversation=$4 pid=$5
  key=$(printf '%s' "$pane" | tr -cd 'A-Za-z0-9_.-')
  printf '%s\n' "$status" > "$MSAM_UPDATER_TEST_DATA/$key.status"
  printf '%s\n' "$kind" > "$MSAM_UPDATER_TEST_DATA/$key.kind"
  printf '%s\n' "$conversation" > "$MSAM_UPDATER_TEST_DATA/$key.conversation"
  printf '%s\n' "$pid" > "$MSAM_UPDATER_TEST_DATA/$key.pid"
}

write_request() {
  batch=$1
  update_tool=${2:-codex}
  policy=${3:-manualApproval}
  first_pid=${4:-101}
  request="$MSAM_AGENT_UPDATER_STATE_DIR/incoming/$batch.request"
  {
    printf 'MSAM_AGENT_UPDATE_REQUEST\t1\n'
    printf 'BATCH\t%s\n' "$batch"
    printf 'POLICY\t%s\n' "$policy"
    printf 'UPDATE\t%s\n' "$update_tool"
    printf 'TARGET\tdefault\t/tmp/herdr.sock\t%%1\t%s\tclaude\tclaude-1\n' "$first_pid"
    printf 'TARGET\tdefault\t/tmp/herdr.sock\t%%2\t102\tcodex\tcodex-2\n'
    printf 'TARGET\tdefault\t/tmp/herdr.sock\t%%3\t103\tantigravity\tagy-3\n'
    printf 'END\n'
  } > "$request"
}

submit_and_run() {
  batch=$1
  "$UPDATER" submit "$batch" >/dev/null
  "$UPDATER" run-once >/dev/null
}

[ -f "$UPDATER" ] || fail "bundled updater script is missing"
assert_eq "$("$UPDATER" protocol)" "1"

# Keep the operator runbook aligned with the installed helper and per-user
# service definitions. These are intentionally literal copy/paste contracts.
HOST_SETUP_DOC="$ROOT/docs/host-setup.md"
DEVELOPMENT_DOC="$ROOT/docs/development.md"
ARCHITECTURE_DOC="$ROOT/docs/architecture.md"
for document in "$HOST_SETUP_DOC" "$DEVELOPMENT_DOC" "$ARCHITECTURE_DOC"; do
  [ -f "$document" ] || fail "missing updater documentation: $document"
done
assert_file_contains "$HOST_SETUP_DOC" 'com.codem0nky87.msam-agent-updater'
assert_file_contains "$HOST_SETUP_DOC" 'msam-agent-updater.service'
# These are literal copy/paste contracts in documentation, not shell expansion.
# shellcheck disable=SC2088
assert_file_contains "$HOST_SETUP_DOC" '~/.local/libexec/msam-agent-updater status'
# shellcheck disable=SC2016
assert_file_contains "$DEVELOPMENT_DOC" 'launchctl print gui/$(id -u)/com.codem0nky87.msam-agent-updater'
assert_file_contains "$DEVELOPMENT_DOC" 'systemctl --user is-active msam-agent-updater.service'
# shellcheck disable=SC2088
assert_file_contains "$DEVELOPMENT_DOC" '~/.local/libexec/msam-agent-updater verify-service'
assert_file_contains "$ARCHITECTURE_DOC" 'Core/AgentUpdateManager.swift'
assert_file_contains "$ARCHITECTURE_DOC" 'Resources/msam-agent-updater.sh'

# Invalid tools are rejected before any vendor or Herdr command can run.
new_host
bad=10000000-0000-4000-8000-000000000001
write_request "$bad" arbitrary-tool
if "$UPDATER" submit "$bad" >/dev/null 2>&1; then
  fail "invalid tool was accepted"
fi
assert_eq "$(wc -c < "$MSAM_UPDATER_TEST_DATA/commands.log" | tr -d ' ')" "0"

# Homebrew casks are distinct, supported owners. The worker must use the cask
# command and still roll every eligible supported agent conversation.
new_host
export MSAM_FAKE_CODEX_OWNER=homebrew-cask
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-000000000012
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_contains "$log" "brew list --formula --versions codex"
assert_contains "$log" "brew list --cask --versions codex"
assert_contains "$log" "brew upgrade --cask --yes codex"
assert_not_contains "$log" "npm install"
assert_contains "$log" "agent prompt %1 /exit"
assert_contains "$log" "agent prompt %2 /exit"
assert_contains "$log" "agent prompt %3 /exit"
assert_contains "$log" "--kind claude"
assert_contains "$log" "--kind codex"
assert_contains "$log" "--kind agy"

# A failed executable update must leave every agent process untouched.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
printf '1\n' > "$MSAM_UPDATER_TEST_DATA/update-fails"
batch=10000000-0000-4000-8000-000000000002
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
assert_not_contains "$log" "codesign"
assert_not_contains "$log" "spctl"
assert_not_contains "$log" "xattr"
assert_contains "$("$UPDATER" status)" "failed_update"

# Even with standalone files present, an unrelated PATH winner cannot be run
# as the native updater.
new_host
export MSAM_FAKE_CODEX_OWNER=none
mkdir -p "$HOME/.local/bin" "$HOME/.codex/packages/standalone"
ln -s "$TEST_ROOT/bin/codex" "$HOME/.local/bin/codex"
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-000000000011
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "curl"
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# A hidden standalone install and a visible package-manager install are still
# ambiguous. PATH precedence must not silently choose which copy to update.
new_host
mkdir -p "$HOME/.local/bin" "$HOME/.codex/packages/standalone"
ln -s "$TEST_ROOT/bin/codex" "$HOME/.local/bin/codex"
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-000000000010
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "npm install"
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# A vendor channel that tries to move backwards is rejected before rolling any
# session, even when the installer itself exits successfully.
new_host
printf '0.153.2\n' > "$MSAM_UPDATER_TEST_DATA/codex.version"
export MSAM_FAKE_CODEX_AFTER_VERSION=0.153.1
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-00000000000f
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# Vendor and Herdr commands have host-side wall-clock limits, so an abandoned
# package manager cannot wedge the persistent service forever.
new_host
export MSAM_AGENT_UPDATER_COMMAND_TIMEOUT=1
export MSAM_FAKE_UPDATE_HANG=yes
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-00000000000e
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"
unset MSAM_AGENT_UPDATER_COMMAND_TIMEOUT

# Idle and done conversations roll now; working waits until a later pass.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 working agy agy-3 103
batch=10000000-0000-4000-8000-000000000003
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_contains "$log" "agent prompt %1 /exit"
assert_contains "$log" "agent prompt %2 /exit"
assert_not_contains "$log" "agent prompt %3 /exit"
assert_contains "$log" "agent start"
assert_contains "$log" "--kind claude"
assert_contains "$log" "--resume claude-1"
assert_contains "$log" "--kind codex"
assert_contains "$log" "resume codex-2"
printf 'done\n' > "$MSAM_UPDATER_TEST_DATA/3.status"
"$UPDATER" run-once >/dev/null
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_contains "$log" "agent prompt %3 /exit"
assert_contains "$log" "--kind agy"
assert_contains "$log" "--conversation agy-3"
assert_not_contains "$log" "codesign"
assert_not_contains "$log" "spctl"
assert_not_contains "$log" "xattr"

# Blocked, unknown, and error are attention states and never receive input.
new_host
seed_agent %1 blocked claude claude-1 101
seed_agent %2 unknown codex codex-2 102
seed_agent %3 error agy agy-3 103
batch=10000000-0000-4000-8000-000000000004
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
expected_counts=$(printf 'COUNTS\t3\t0\t0\t3\t0\t0')
assert_contains "$("$UPDATER" status)" "$expected_counts"

# Identity drift stops only that target and does not touch an unrelated pane.
new_host
seed_agent %1 idle claude changed-conversation 101
seed_agent %2 working codex codex-2 102
seed_agent %3 working agy agy-3 103
printf '777\n' > "$MSAM_UPDATER_TEST_DATA/ordinary.pid"
batch=10000000-0000-4000-8000-000000000005
write_request "$batch"
submit_and_run "$batch"
assert_not_contains "$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")" "agent prompt %1"
assert_eq "$(cat "$MSAM_UPDATER_TEST_DATA/ordinary.pid")" "777"
assert_contains "$("$UPDATER" status)" "identity_changed"

# A missing foreground PID is not enough identity to safely exit a pane.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 working codex codex-2 102
seed_agent %3 working agy agy-3 103
batch=10000000-0000-4000-8000-00000000000a
write_request "$batch" codex manualApproval -
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt %1"
assert_contains "$("$UPDATER" status)" "process_unavailable"

# If the pane identity changes while an exit is being processed, fail closed
# and never start over the new occupant.
new_host
export MSAM_FAKE_EXIT_MODE=identity-change
seed_agent %1 idle claude claude-1 101
seed_agent %2 working codex codex-2 102
seed_agent %3 working agy agy-3 103
batch=10000000-0000-4000-8000-00000000000b
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_contains "$log" "agent prompt %1 /exit"
assert_not_contains "$log" "agent start"
assert_contains "$("$UPDATER" status)" "identity_changed"

# A successful package-manager command that leaves the same executable version
# is not a completed update and must not disturb any conversation.
new_host
printf '0.153.2\n' > "$MSAM_UPDATER_TEST_DATA/codex.version"
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-00000000000c
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# An executable merely found on PATH is not assumed to be a vendor-managed
# native install. Unknown ownership requires administrator action.
new_host
export MSAM_FAKE_CODEX_OWNER=none
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-00000000000d
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "curl"
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# Failed restores are attempted exactly three times, then permanently stop.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 working codex codex-2 102
seed_agent %3 working agy agy-3 103
printf '99\n' > "$MSAM_UPDATER_TEST_DATA/restore-failures"
batch=10000000-0000-4000-8000-000000000006
write_request "$batch"
submit_and_run "$batch"
"$UPDATER" run-once >/dev/null
"$UPDATER" run-once >/dev/null
"$UPDATER" run-once >/dev/null
attempts=$(grep -c 'agent start .*--pane %1' "$MSAM_UPDATER_TEST_DATA/commands.log" || true)
assert_eq "$attempts" "3"
assert_contains "$("$UPDATER" status)" "restore_attempts_exhausted"

# Manual Gatekeeper policy never removes quarantine. It waits without touching
# a conversation until the user has approved the exact executable on the Mac.
new_host
export MSAM_FAKE_OS=Darwin
printf 'yes\n' > "$MSAM_UPDATER_TEST_DATA/quarantine"
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-000000000007
write_request "$batch" codex manualApproval
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "xattr -d"
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "approval_required"
printf 'no\n' > "$MSAM_UPDATER_TEST_DATA/quarantine"
"$UPDATER" run-once >/dev/null
assert_contains "$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")" "agent prompt %1 /exit"

# Verified-artifact policy clears only the exact resolved file, and only after
# strict signing, fixed publisher identity, and Gatekeeper assessment succeed.
new_host
export MSAM_FAKE_OS=Darwin
printf 'yes\n' > "$MSAM_UPDATER_TEST_DATA/quarantine"
seed_agent %1 idle claude claude-1 101
seed_agent %2 "done" codex codex-2 102
seed_agent %3 idle agy agy-3 103
batch=10000000-0000-4000-8000-000000000008
write_request "$batch" codex verifiedVendorArtifacts
submit_and_run "$batch"
artifact="$MSAM_UPDATER_TEST_DATA/signed-artifact"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_contains "$log" "codesign --verify --strict"
assert_contains "$log" "spctl --assess --type execute"
assert_contains "$log" "xattr -d com.apple.quarantine -- $artifact"
assert_contains "$log" "agent prompt %1 /exit"

# Any failed proof or unsafe/path-raced resolution falls back to approval and
# never exits a conversation or clears quarantine.
for failure in signature publisher notarization path-swap directory parent glob symlink unavailable; do
  new_host
  export MSAM_FAKE_OS=Darwin
  printf 'yes\n' > "$MSAM_UPDATER_TEST_DATA/quarantine"
  case "$failure" in
    signature) export MSAM_FAKE_SIGNING_VALID=no ;;
    publisher) export MSAM_FAKE_TEAM=WRONGTEAM ;;
    notarization) export MSAM_FAKE_SPCTL_VALID=no ;;
    path-swap|directory|parent|glob|symlink|unavailable)
      export MSAM_FAKE_REALPATH_MODE=$failure
      ;;
  esac
  seed_agent %1 idle claude claude-1 101
  seed_agent %2 "done" codex codex-2 102
  seed_agent %3 idle agy agy-3 103
  batch=10000000-0000-4000-8000-000000000009
  write_request "$batch" codex verifiedVendorArtifacts
  submit_and_run "$batch"
  log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
  assert_not_contains "$log" "xattr -d"
  assert_not_contains "$log" "agent prompt"
  assert_contains "$("$UPDATER" status)" "approval_required"
done

# The helper must never automate security UI or weaken Gatekeeper globally.
if grep -E 'spctl +(---master-disable|--master-disable|--global-disable)|Anywhere|xattr +(-r|-dR)|osascript|System Events|Accessibility control' "$UPDATER" >/dev/null; then
  fail "updater contains a forbidden Gatekeeper bypass"
fi

# Status output and logs remain bounded even if a hostile host left a huge log.
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' x > "$MSAM_AGENT_UPDATER_STATE_DIR/worker.log"
status=$("$UPDATER" status)
[ "${#status}" -le 65536 ] || fail "status output is unbounded"

printf 'PASS: msam-agent-updater\n'
