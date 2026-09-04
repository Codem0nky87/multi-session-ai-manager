#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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

  cp "$ROOT/scripts/fixtures/fake-agent-command.sh" "$TEST_ROOT/bin/fake-agent-command"
  chmod 700 "$TEST_ROOT/bin/fake-agent-command"
  for command in herdr claude codex agy brew npm pnpm bun curl; do
    ln -s fake-agent-command "$TEST_ROOT/bin/$command"
  done
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
  request="$MSAM_AGENT_UPDATER_STATE_DIR/incoming/$batch.request"
  {
    printf 'MSAM_AGENT_UPDATE_REQUEST\t1\n'
    printf 'BATCH\t%s\n' "$batch"
    printf 'POLICY\tmanualApproval\n'
    printf 'UPDATE\t%s\n' "$update_tool"
    printf 'TARGET\tdefault\t/tmp/herdr.sock\t%%1\t101\tclaude\tclaude-1\n'
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

# Invalid tools are rejected before any vendor or Herdr command can run.
new_host
bad=10000000-0000-4000-8000-000000000001
write_request "$bad" arbitrary-tool
if "$UPDATER" submit "$bad" >/dev/null 2>&1; then
  fail "invalid tool was accepted"
fi
assert_eq "$(wc -c < "$MSAM_UPDATER_TEST_DATA/commands.log" | tr -d ' ')" "0"

# A failed executable update must leave every agent process untouched.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 done codex codex-2 102
seed_agent %3 idle agy agy-3 103
printf '1\n' > "$MSAM_UPDATER_TEST_DATA/update-fails"
batch=10000000-0000-4000-8000-000000000002
write_request "$batch"
submit_and_run "$batch"
log=$(cat "$MSAM_UPDATER_TEST_DATA/commands.log")
assert_not_contains "$log" "agent prompt"
assert_contains "$("$UPDATER" status)" "failed_update"

# Idle and done conversations roll now; working waits until a later pass.
new_host
seed_agent %1 idle claude claude-1 101
seed_agent %2 done codex codex-2 102
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

# Status output and logs remain bounded even if a hostile host left a huge log.
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' x > "$MSAM_AGENT_UPDATER_STATE_DIR/worker.log"
status=$("$UPDATER" status)
[ "${#status}" -le 65536 ] || fail "status output is unbounded"

printf 'PASS: msam-agent-updater\n'
