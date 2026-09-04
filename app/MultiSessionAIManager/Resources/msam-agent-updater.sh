#!/bin/sh
set -eu
umask 077

PROTOCOL_VERSION=1
MAX_RESTORE_ATTEMPTS=3
MAX_REQUEST_BYTES=1048576
MAX_LOG_BYTES=131072
STATE_DIR=${MSAM_AGENT_UPDATER_STATE_DIR:-"$HOME/.local/state/msam-agent-updater"}
INCOMING_DIR="$STATE_DIR/incoming"
QUEUE_DIR="$STATE_DIR/queue"
BATCHES_DIR="$STATE_DIR/batches"
CURRENT_FILE="$STATE_DIR/current"
LOG_FILE="$STATE_DIR/worker.log"
LOCK_DIR="$STATE_DIR/lock"
TAB=$(printf '\t')
CODESIGN_COMMAND=${MSAM_AGENT_UPDATER_CODESIGN:-/usr/bin/codesign}
SPCTL_COMMAND=${MSAM_AGENT_UPDATER_SPCTL:-/usr/sbin/spctl}
XATTR_COMMAND=${MSAM_AGENT_UPDATER_XATTR:-/usr/bin/xattr}
REALPATH_COMMAND=${MSAM_AGENT_UPDATER_REALPATH:-/usr/bin/realpath}
STAT_COMMAND=${MSAM_AGENT_UPDATER_STAT:-/usr/bin/stat}
UNAME_COMMAND=${MSAM_AGENT_UPDATER_UNAME:-/usr/bin/uname}

ensure_state() {
  mkdir -p "$INCOMING_DIR" "$QUEUE_DIR" "$BATCHES_DIR"
  [ -w "$STATE_DIR" ] || return 1
}

trim_log() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" | tr -d ' ')
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    tail -c 65536 "$LOG_FILE" > "$LOG_FILE.tmp"
    mv -f "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

log_message() {
  ensure_state
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG_FILE"
  trim_log
}

release_lock() {
  if [ -d "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || :)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || :
  fi
}

acquire_lock() {
  ensure_state
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap release_lock EXIT HUP INT TERM
    return 0
  fi
  lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || :)
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    return 1
  fi
  rm -f "$LOCK_DIR/pid" 2>/dev/null || :
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap release_lock EXIT HUP INT TERM
}

valid_batch_id() {
  value=$1
  [ "${#value}" -eq 36 ] || return 1
  case "$value" in
    ????????-????-????-????-????????????) : ;;
    *) return 1 ;;
  esac
  case "$value" in *[!0-9A-Fa-f-]*) return 1 ;; esac
}

validate_request() {
  request=$1 expected_batch=$2
  [ -f "$request" ] && [ ! -L "$request" ] || return 1
  size=$(wc -c < "$request" | tr -d ' ')
  [ "$size" -gt 0 ] && [ "$size" -le "$MAX_REQUEST_BYTES" ] || return 1
  if od -An -tx1 "$request" | grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
    return 1
  fi
  LC_ALL=C awk -F '\t' -v batch="$expected_batch" '
    function safe(value, max) {
      return length(value) > 0 && length(value) <= max && value !~ /[[:cntrl:]]/
    }
    NR == 1 {
      if (NF != 2 || $1 != "MSAM_AGENT_UPDATE_REQUEST" || $2 != "1") exit 10
      next
    }
    NR == 2 {
      if (NF != 2 || $1 != "BATCH" || $2 != batch) exit 11
      next
    }
    NR == 3 {
      if (NF != 2 || $1 != "POLICY" || ($2 != "manualApproval" && $2 != "verifiedVendorArtifacts")) exit 12
      next
    }
    $1 == "UPDATE" {
      if (seen_target || seen_end || NF != 2 || ($2 != "claude" && $2 != "codex" && $2 != "antigravity") || updates[$2]++) exit 13
      update_count++
      next
    }
    $1 == "TARGET" {
      seen_target = 1
      if (seen_end || NF != 7) exit 14
      if (!safe($2, 128) || !safe($3, 1024) || substr($3, 1, 1) != "/") exit 15
      if (!safe($4, 128) || $4 !~ /^%?[A-Za-z0-9][A-Za-z0-9._:%@+-]*$/) exit 16
      if ($5 != "-" && ($5 !~ /^[0-9]+$/ || $5 + 0 <= 0)) exit 17
      if ($6 != "claude" && $6 != "codex" && $6 != "antigravity") exit 18
      if (!safe($7, 2048)) exit 19
      key = $3 SUBSEP $4
      if (targets[key]++) exit 20
      next
    }
    $1 == "END" {
      if (NF != 1 || seen_end) exit 21
      seen_end = 1
      end_line = NR
      next
    }
    { exit 22 }
    END {
      if (update_count < 1 || !seen_end || end_line != NR) exit 23
    }
  ' "$request"
}

submit_request() {
  batch=${1:-}
  valid_batch_id "$batch" || return 2
  acquire_lock || return 75
  request="$INCOMING_DIR/$batch.request"
  validate_request "$request" "$batch" || {
    log_message "rejected request $batch"
    return 2
  }
  if [ -d "$BATCHES_DIR/$batch" ] || { [ -f "$CURRENT_FILE" ] && [ "$(cat "$CURRENT_FILE")" = "$batch" ]; }; then
    printf 'MSAM_AGENT_UPDATE_ACCEPTED\t1\t%s\texisting\n' "$batch"
    return 0
  fi
  mv "$request" "$QUEUE_DIR/$batch.request"
  printf 'MSAM_AGENT_UPDATE_ACCEPTED\t1\t%s\tqueued\n' "$batch"
  log_message "queued request $batch"
}

extract_version() {
  printf '%s\n' "$1" | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?' | head -n 1 | sed 's/^v//' || :
}

tool_values() {
  case "$1" in
    claude) printf '%s\t%s\t%s\n' claude claude-code @anthropic-ai/claude-code ;;
    codex) printf '%s\t%s\t%s\n' codex codex @openai/codex ;;
    antigravity) printf '%s\t%s\t%s\n' agy - - ;;
    *) return 1 ;;
  esac
}

publisher_values() {
  case "$1" in
    claude) printf '%s\t%s\n' Q6L2SF6YDW com.anthropic.claude-code ;;
    codex) printf '%s\t%s\n' 2DC432GLL2 codex ;;
    antigravity) printf '%s\t%s\n' EQHXZ8M8AV cli ;;
    *) return 1 ;;
  esac
}

artifact_has_quarantine() {
  "$XATTR_COMMAND" -p com.apple.quarantine -- "$1" >/dev/null 2>&1
}

artifact_inode() {
  "$STAT_COMMAND" -f '%d:%i' -- "$1" 2>/dev/null
}

gatekeeper_ready() {
  tool=$1 executable=$2 policy=$3
  [ "$("$UNAME_COMMAND" -s 2>/dev/null || :)" = Darwin ] || return 0

  artifact=$("$REALPATH_COMMAND" -- "$executable" 2>/dev/null || :)
  case "$artifact" in /*) : ;; *) return 2 ;; esac
  [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 2
  artifact_has_quarantine "$artifact" || return 0

  # Manual mode deliberately leaves macOS in control. The service retries only
  # after the user has approved this executable and quarantine is absent.
  [ "$policy" = verifiedVendorArtifacts ] || return 2

  values=$(publisher_values "$tool") || return 2
  old_ifs=$IFS; IFS=$TAB; set -- $values; IFS=$old_ifs
  expected_team=$1 expected_identifier=$2
  inode_before=$(artifact_inode "$artifact")
  [ -n "$inode_before" ] || return 2

  "$CODESIGN_COMMAND" --verify --strict --verbose=2 -- "$artifact" >/dev/null 2>&1 || return 2
  signature=$("$CODESIGN_COMMAND" -dvvv -- "$artifact" 2>&1 || :)
  team=$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
  identifier=$(printf '%s\n' "$signature" | sed -n 's/^Identifier=//p' | head -n 1)
  [ "$team" = "$expected_team" ] && [ "$identifier" = "$expected_identifier" ] || return 2
  requirement=$("$CODESIGN_COMMAND" -dr - -- "$artifact" 2>&1 || :)
  case "$requirement" in *"$expected_team"*"$expected_identifier"*|*"$expected_identifier"*"$expected_team"*) : ;; *) return 2 ;; esac
  "$SPCTL_COMMAND" --assess --type execute --verbose=4 -- "$artifact" >/dev/null 2>&1 || return 2

  # Re-resolve and re-stat immediately before the only mutation. A symlink swap,
  # directory, parent path, or inode change falls back to manual approval.
  artifact_again=$("$REALPATH_COMMAND" -- "$executable" 2>/dev/null || :)
  [ "$artifact_again" = "$artifact" ] || return 2
  [ -f "$artifact_again" ] && [ ! -L "$artifact_again" ] || return 2
  inode_after=$(artifact_inode "$artifact_again")
  [ "$inode_after" = "$inode_before" ] || return 2
  "$XATTR_COMMAND" -d com.apple.quarantine -- "$artifact_again" >/dev/null 2>&1 || return 2
  artifact_has_quarantine "$artifact_again" && return 2
  return 0
}

install_antigravity_native() {
  executable=$1 policy=$2
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m 2>/dev/null)
  case "$arch" in aarch64) arch=arm64 ;; amd64) arch=x86_64 ;; esac
  case "$os:$arch" in
    darwin:arm64|darwin:x86_64|linux:arm64|linux:x86_64) : ;;
    *) return 1 ;;
  esac
  manifest="$STATE_DIR/antigravity-manifest.$$.json"
  staged="$STATE_DIR/antigravity.$$.new"
  curl --connect-timeout 8 --max-time 30 -fsSL \
    "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/${os}_${arch}.json" \
    -o "$manifest" || return 1
  url=$(sed -nE 's/.*"(download_url|url)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$manifest" | head -n 1)
  expected=$(sed -nE 's/.*"sha512"[[:space:]]*:[[:space:]]*"([0-9A-Fa-f]+)".*/\1/p' "$manifest" | head -n 1)
  rm -f "$manifest"
  case "$url" in https://*) : ;; *) return 1 ;; esac
  [ "${#expected}" -eq 128 ] || return 1
  curl --connect-timeout 8 --max-time 120 -fsSL "$url" -o "$staged" || return 1
  if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 512 "$staged" | awk '{print $1}')
  elif command -v sha512sum >/dev/null 2>&1; then
    actual=$(sha512sum "$staged" | awk '{print $1}')
  else
    rm -f "$staged"
    return 1
  fi
  [ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ] || {
    rm -f "$staged"
    return 1
  }
  chmod 700 "$staged"
  # Gatekeeper handling is policy-gated separately. Manual approval is never
  # replaced by UI scripting or a global security change.
  case "$policy" in manualApproval|verifiedVendorArtifacts) : ;; *) rm -f "$staged"; return 1 ;; esac
  mv -f "$staged" "$executable"
}

install_native() {
  tool=$1 executable=$2 policy=$3
  case "$tool" in
    claude) "$executable" update ;;
    codex)
      installer="$STATE_DIR/codex-install.$$.sh"
      curl --connect-timeout 8 --max-time 30 -fsSL https://chatgpt.com/codex/install.sh -o "$installer" || return 1
      /bin/sh "$installer"
      result=$?
      rm -f "$installer"
      return "$result"
      ;;
    antigravity) install_antigravity_native "$executable" "$policy" ;;
    *) return 1 ;;
  esac
}

update_tool() {
  tool=$1 policy=$2
  values=$(tool_values "$tool") || return 1
  old_ifs=$IFS; IFS=$TAB; set -- $values; IFS=$old_ifs
  executable_name=$1 brew_package=$2 node_package=$3
  executable=$(command -v "$executable_name" 2>/dev/null || :)
  [ -n "$executable" ] || return 1
  before=$(extract_version "$("$executable" --version 2>/dev/null | head -n 1)")
  [ -n "$before" ] || return 1

  owners=0
  method=native
  if [ "$brew_package" != - ] && command -v brew >/dev/null 2>&1 && brew list --versions "$brew_package" >/dev/null 2>&1; then
    owners=$((owners + 1)); method=homebrew
  fi
  if [ "$node_package" != - ] && command -v npm >/dev/null 2>&1 && npm list -g --depth=0 "$node_package" >/dev/null 2>&1; then
    owners=$((owners + 1)); method=npm
  fi
  if [ "$node_package" != - ] && command -v pnpm >/dev/null 2>&1 && pnpm list -g --depth=0 "$node_package" >/dev/null 2>&1; then
    owners=$((owners + 1)); method=pnpm
  fi
  if [ "$node_package" != - ] && command -v bun >/dev/null 2>&1 && bun pm ls -g 2>/dev/null | grep -F "$node_package" >/dev/null 2>&1; then
    owners=$((owners + 1)); method=bun
  fi
  [ "$owners" -le 1 ] || return 1

  case "$method" in
    homebrew) brew upgrade "$brew_package" || return 1 ;;
    npm) npm install -g "$node_package@latest" || return 1 ;;
    pnpm) pnpm add -g "$node_package@latest" || return 1 ;;
    bun) bun add -g "$node_package@latest" || return 1 ;;
    native) install_native "$tool" "$executable" "$policy" || return 1 ;;
    *) return 1 ;;
  esac
  executable_after=$(command -v "$executable_name" 2>/dev/null || :)
  [ -n "$executable_after" ] || return 1
  after=$(extract_version "$("$executable_after" --version 2>/dev/null | head -n 1)")
  [ -n "$after" ] || return 1
  log_message "updated $tool using $method from $before to $after"
  gatekeeper_ready "$tool" "$executable_after" "$policy"
}

activate_next_batch() {
  if [ -f "$CURRENT_FILE" ]; then
    cat "$CURRENT_FILE"
    return 0
  fi
  for request in "$QUEUE_DIR"/*.request; do
    [ -f "$request" ] || return 1
    batch=${request##*/}; batch=${batch%.request}
    mkdir "$BATCHES_DIR/$batch"
    mv "$request" "$BATCHES_DIR/$batch/request"
    printf '%s\n' updating > "$BATCHES_DIR/$batch/phase"
    printf '%s\n' "$batch" > "$CURRENT_FILE.tmp"
    mv -f "$CURRENT_FILE.tmp" "$CURRENT_FILE"
    cat "$CURRENT_FILE"
    return 0
  done
  return 1
}

request_policy() {
  awk -F '\t' '$1 == "POLICY" { print $2; exit }' "$1"
}

initialize_targets() {
  batch_dir=$1
  [ -f "$batch_dir/target-count" ] && return 0
  count=0
  while IFS= read -r line; do
    case "$line" in
      "TARGET${TAB}"*)
        count=$((count + 1))
        printf '%s\n' "$line" > "$batch_dir/target.$count"
        printf '%s\n' pending > "$batch_dir/target.$count.phase"
        printf '0\n' > "$batch_dir/target.$count.attempts"
        printf '0\n' > "$batch_dir/target.$count.exit-attempts"
        printf '%s\n' queued > "$batch_dir/target.$count.message"
        ;;
    esac
  done < "$batch_dir/request"
  printf '%s\n' "$count" > "$batch_dir/target-count.tmp"
  mv -f "$batch_dir/target-count.tmp" "$batch_dir/target-count"
}

write_value() {
  file=$1 value=$2
  printf '%s\n' "$value" > "$file.tmp"
  mv -f "$file.tmp" "$file"
}

json_value() {
  key=$1
  printf '%s\n' "$2" | tr -d '\n' | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n 1
}

agent_snapshot() {
  socket=$1 pane=$2
  HERDR_SOCKET_PATH="$socket" herdr agent get "$pane" 2>/dev/null || return 1
}

agent_state() {
  value=$(json_value agent_status "$1")
  [ -n "$value" ] || value=$(json_value status "$1")
  [ -n "$value" ] || value=$(json_value state "$1")
  printf '%s' "$value"
}

agent_kind() {
  value=$(printf '%s\n' "$1" | tr -d '\n' | sed -nE 's/.*"agent_session"[[:space:]]*:[[:space:]]*\{[^}]*"agent"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1)
  [ -n "$value" ] || value=$(json_value kind "$1")
  [ -n "$value" ] || value=$(json_value agent "$1")
  printf '%s' "$value"
}

agent_conversation() {
  printf '%s\n' "$1" | tr -d '\n' | sed -nE 's/.*"agent_session"[[:space:]]*:[[:space:]]*\{[^}]*"value"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1
}

foreground_pid() {
  socket=$1 pane=$2
  info=$(HERDR_SOCKET_PATH="$socket" herdr pane process-info --pane "$pane" 2>/dev/null || :)
  value=$(printf '%s\n' "$info" | tr -d '\n' | sed -nE 's/.*"foreground_pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)
  [ -n "$value" ] || value=$(printf '%s\n' "$info" | tr -d '\n' | sed -nE 's/.*"foreground_processes"[^]]*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)
  [ -n "$value" ] || value=$(printf '%s\n' "$info" | tr -d '\n' | sed -nE 's/.*"foreground_pgid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)
  [ -n "$value" ] || value=$(printf '%s\n' "$info" | tr -d '\n' | sed -nE 's/.*"shell_pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)
  printf '%s' "$value"
}

kind_matches() {
  expected=$1 actual=$2
  case "$expected:$actual" in
    claude:claude|codex:codex|antigravity:agy|antigravity:antigravity-cli) return 0 ;;
    *) return 1 ;;
  esac
}

mark_target() {
  batch_dir=$1 index=$2 phase=$3 message=$4
  write_value "$batch_dir/target.$index.phase" "$phase"
  write_value "$batch_dir/target.$index.message" "$message"
}

snapshot_is_expected() {
  snapshot=$1 tool=$2 conversation=$3
  kind_matches "$tool" "$(agent_kind "$snapshot")" && [ "$(agent_conversation "$snapshot")" = "$conversation" ]
}

start_agent() {
  socket=$1 pane=$2 tool=$3 conversation=$4 name=$5
  case "$tool" in
    claude)
      HERDR_SOCKET_PATH="$socket" herdr agent start "$name" --kind claude --pane "$pane" --timeout 300000 -- --resume "$conversation"
      ;;
    codex)
      HERDR_SOCKET_PATH="$socket" herdr agent start "$name" --kind codex --pane "$pane" --timeout 300000 -- resume "$conversation"
      ;;
    antigravity)
      HERDR_SOCKET_PATH="$socket" herdr agent start "$name" --kind agy --pane "$pane" --timeout 300000 -- --conversation "$conversation"
      ;;
    *) return 1 ;;
  esac
}

process_target() {
  batch=$1 batch_dir=$2 index=$3
  old_ifs=$IFS; IFS=$TAB; read -r tag session socket pane original_pid tool conversation < "$batch_dir/target.$index"; IFS=$old_ifs
  phase=$(cat "$batch_dir/target.$index.phase")
  attempts=$(cat "$batch_dir/target.$index.attempts")

  if [ "$phase" != pending ]; then
    snapshot=$(agent_snapshot "$socket" "$pane" 2>/dev/null || :)
    current_pid=$(foreground_pid "$socket" "$pane")
    if [ -n "$snapshot" ] && snapshot_is_expected "$snapshot" "$tool" "$conversation" \
       && { [ "$original_pid" = - ] || [ -z "$current_pid" ] || [ "$current_pid" != "$original_pid" ]; }; then
      mark_target "$batch_dir" "$index" restored restored
      return 0
    fi
  fi

  case "$phase" in
    restored|failed) return 0 ;;
    pending)
      snapshot=$(agent_snapshot "$socket" "$pane" 2>/dev/null || :)
      if [ -z "$snapshot" ]; then
        mark_target "$batch_dir" "$index" pending attention_unknown
        return 0
      fi
      state=$(agent_state "$snapshot")
      case "$state" in
        working) mark_target "$batch_dir" "$index" pending working; return 0 ;;
        blocked|unknown|error) mark_target "$batch_dir" "$index" pending "attention_$state"; return 0 ;;
        idle|done) : ;;
        *) mark_target "$batch_dir" "$index" pending attention_unknown; return 0 ;;
      esac
      if ! snapshot_is_expected "$snapshot" "$tool" "$conversation"; then
        mark_target "$batch_dir" "$index" failed identity_changed
        return 0
      fi
      current_pid=$(foreground_pid "$socket" "$pane")
      if [ "$original_pid" != - ] && { [ -z "$current_pid" ] || [ "$current_pid" != "$original_pid" ]; }; then
        mark_target "$batch_dir" "$index" failed process_changed
        return 0
      fi
      mark_target "$batch_dir" "$index" exiting exit_requested
      phase=exiting
      ;;
  esac

  if [ "$phase" = exiting ]; then
    snapshot=$(agent_snapshot "$socket" "$pane" 2>/dev/null || :)
    current_pid=$(foreground_pid "$socket" "$pane")
    if [ -n "$snapshot" ] && snapshot_is_expected "$snapshot" "$tool" "$conversation" \
       && { [ "$original_pid" = - ] || [ "$current_pid" = "$original_pid" ]; }; then
      exit_attempts=$(cat "$batch_dir/target.$index.exit-attempts")
      if [ "$exit_attempts" -ge 3 ]; then
        mark_target "$batch_dir" "$index" failed exit_attempts_exhausted
        return 0
      fi
      exit_attempts=$((exit_attempts + 1))
      write_value "$batch_dir/target.$index.exit-attempts" "$exit_attempts"
      HERDR_SOCKET_PATH="$socket" herdr agent prompt "$pane" /exit >/dev/null 2>&1 || return 0
      current_pid=$(foreground_pid "$socket" "$pane")
    fi
    if [ "$original_pid" != - ] && [ -n "$current_pid" ] && [ "$current_pid" = "$original_pid" ]; then
      mark_target "$batch_dir" "$index" exiting waiting_for_exit
      return 0
    fi
    mark_target "$batch_dir" "$index" exited ready_to_restore
    phase=exited
  fi

  if [ "$phase" = exited ]; then
    attempts=$(cat "$batch_dir/target.$index.attempts")
    if [ "$attempts" -ge "$MAX_RESTORE_ATTEMPTS" ]; then
      mark_target "$batch_dir" "$index" failed restore_attempts_exhausted
      return 0
    fi
    attempts=$((attempts + 1))
    write_value "$batch_dir/target.$index.attempts" "$attempts"
    short_batch=$(printf '%s' "$batch" | cut -c 1-8 | tr '[:upper:]' '[:lower:]')
    if start_agent "$socket" "$pane" "$tool" "$conversation" "msam_${short_batch}_$index" >/dev/null 2>&1; then
      snapshot=$(agent_snapshot "$socket" "$pane" 2>/dev/null || :)
      if [ -n "$snapshot" ] && snapshot_is_expected "$snapshot" "$tool" "$conversation"; then
        mark_target "$batch_dir" "$index" restored restored
        return 0
      fi
    fi
    if [ "$attempts" -ge "$MAX_RESTORE_ATTEMPTS" ]; then
      mark_target "$batch_dir" "$index" failed restore_attempts_exhausted
    else
      mark_target "$batch_dir" "$index" exited "retry_$attempts"
    fi
  fi
}

finish_if_settled() {
  batch_dir=$1
  count=$(cat "$batch_dir/target-count")
  index=1 pending=0 failures=0
  while [ "$index" -le "$count" ]; do
    phase=$(cat "$batch_dir/target.$index.phase")
    case "$phase" in
      restored) : ;;
      failed) failures=$((failures + 1)) ;;
      *) pending=$((pending + 1)) ;;
    esac
    index=$((index + 1))
  done
  [ "$pending" -eq 0 ] || return 0
  if [ "$failures" -eq 0 ]; then
    write_value "$batch_dir/phase" complete
  else
    write_value "$batch_dir/phase" completed_with_failures
  fi
  rm -f "$CURRENT_FILE"
}

run_once() {
  acquire_lock || return 75
  batch=$(activate_next_batch 2>/dev/null || :)
  [ -n "$batch" ] || return 0
  batch_dir="$BATCHES_DIR/$batch"
  phase=$(cat "$batch_dir/phase")
  if [ "$phase" = approval_required ]; then
    policy=$(request_policy "$batch_dir/request")
    approval_tool=$(cat "$batch_dir/approval-tool" 2>/dev/null || :)
    values=$(tool_values "$approval_tool" 2>/dev/null || :)
    old_ifs=$IFS; IFS=$TAB; set -- $values; IFS=$old_ifs
    executable_name=${1:-}
    executable=$(command -v "$executable_name" 2>/dev/null || :)
    if [ -z "$executable" ] || ! gatekeeper_ready "$approval_tool" "$executable" "$policy"; then
      return 0
    fi
    if ! grep -Fx "$approval_tool" "$batch_dir/updated-tools" >/dev/null 2>&1; then
      printf '%s\n' "$approval_tool" >> "$batch_dir/updated-tools"
    fi
    rm -f "$batch_dir/approval-tool"
    write_value "$batch_dir/phase" updating
    phase=updating
  fi
  if [ "$phase" = updating ]; then
    policy=$(request_policy "$batch_dir/request")
    touch "$batch_dir/updated-tools"
    update_failed=0
    while IFS= read -r tool; do
      if grep -Fx "$tool" "$batch_dir/updated-tools" >/dev/null 2>&1; then
        continue
      fi
      if update_tool "$tool" "$policy"; then
        printf '%s\n' "$tool" >> "$batch_dir/updated-tools"
      else
        result=$?
        if [ "$result" -eq 2 ]; then
          write_value "$batch_dir/approval-tool" "$tool"
          write_value "$batch_dir/phase" approval_required
          initialize_targets "$batch_dir"
          log_message "approval required for $tool in $batch"
          return 0
        fi
        update_failed=1
        log_message "update failed for $tool in $batch"
        break
      fi
    done <<EOF
$(awk -F '\t' '$1 == "UPDATE" { print $2 }' "$batch_dir/request")
EOF
    if [ "$update_failed" -ne 0 ]; then
      write_value "$batch_dir/phase" failed_update
      rm -f "$CURRENT_FILE"
      return 0
    fi
    # Durable boundary: no conversation is asked to exit before this phase is
    # safely on disk.
    write_value "$batch_dir/phase" rolling
    phase=rolling
  fi
  if [ "$phase" = rolling ]; then
    initialize_targets "$batch_dir"
    count=$(cat "$batch_dir/target-count")
    index=1
    while [ "$index" -le "$count" ]; do
      process_target "$batch" "$batch_dir" "$index"
      index=$((index + 1))
    done
    finish_if_settled "$batch_dir"
  fi
}

status_output() {
  ensure_state
  printf 'MSAM_AGENT_UPDATE_STATUS\t1\n'
  if [ ! -f "$CURRENT_FILE" ]; then
    latest=
    for candidate in "$BATCHES_DIR"/*; do [ -d "$candidate" ] && latest=$candidate; done
    if [ -z "$latest" ]; then
      printf 'BATCH\t-\tidle\nCOUNTS\t0\t0\t0\t0\t0\t0\nEND\n'
      return 0
    fi
    batch=${latest##*/}
  else
    batch=$(cat "$CURRENT_FILE")
  fi
  batch_dir="$BATCHES_DIR/$batch"
  phase=$(cat "$batch_dir/phase" 2>/dev/null || printf unknown)
  printf 'BATCH\t%s\t%s\n' "$batch" "$phase"
  count=$(cat "$batch_dir/target-count" 2>/dev/null || printf 0)
  restored=0 working=0 attention=0 retrying=0 failed=0 index=1
  while [ "$index" -le "$count" ]; do
    target_phase=$(cat "$batch_dir/target.$index.phase")
    attempts=$(cat "$batch_dir/target.$index.attempts")
    message=$(cat "$batch_dir/target.$index.message")
    case "$target_phase" in
      restored) restored=$((restored + 1)) ;;
      failed) failed=$((failed + 1)) ;;
      exited|exiting) retrying=$((retrying + 1)) ;;
      pending)
        case "$message" in working) working=$((working + 1)) ;; *) attention=$((attention + 1)) ;; esac
        ;;
    esac
    printf 'TARGET\t%s\t%s\t%s\t%s\n' "$index" "$target_phase" "$attempts" "$message"
    index=$((index + 1))
  done
  printf 'COUNTS\t%s\t%s\t%s\t%s\t%s\t%s\n' "$count" "$restored" "$working" "$attention" "$retrying" "$failed"
  printf 'END\n'
}

verify_service() {
  ensure_state || return 1
  test_file="$STATE_DIR/self-test.$$"
  printf '%s\n' ok > "$test_file"
  [ "$(cat "$test_file")" = ok ] || return 1
  rm -f "$test_file"
  printf 'MSAM_AGENT_UPDATER_VERIFY\t1\tready\n'
}

service_loop() {
  while :; do
    run_once || :
    sleep 2
  done
}

case "${1:-}" in
  protocol) printf '%s\n' "$PROTOCOL_VERSION" ;;
  verify-service) verify_service ;;
  submit) submit_request "${2:-}" ;;
  status) status_output ;;
  run-once) run_once ;;
  service) service_loop ;;
  *) printf 'usage: %s {protocol|verify-service|submit BATCH|status|run-once|service}\n' "$0" >&2; exit 2 ;;
esac
