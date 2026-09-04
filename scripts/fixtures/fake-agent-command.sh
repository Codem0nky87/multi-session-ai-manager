#!/bin/sh
set -eu

data=${MSAM_UPDATER_TEST_DATA:?}
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$data/commands.log"

agent_key() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-'
}

case "$name" in
  codex)
    if [ "${1:-}" = "--version" ]; then
      printf 'codex-cli %s\n' "$(cat "$data/codex.version")"
    fi
    ;;
  claude)
    [ "${1:-}" = "--version" ] && printf '2.1.260 (Claude Code)\n'
    ;;
  agy)
    [ "${1:-}" = "--version" ] && printf '1.1.26\n'
    ;;
  brew|pnpm|bun)
    exit 1
    ;;
  npm)
    case " $* " in
      *" list -g --depth=0 @openai/codex "*) [ "${MSAM_FAKE_CODEX_OWNER:-npm}" = npm ] ;;
      *" prefix -g "*) printf '%s\n' "${data%/fake}" ;;
      *" install -g @openai/codex@latest "*)
        [ "$(cat "$data/update-fails")" = "0" ] || exit 1
        [ "${MSAM_FAKE_UPDATE_HANG:-no}" != yes ] || sleep 10
        printf '%s\n' "${MSAM_FAKE_CODEX_AFTER_VERSION:-0.153.2}" > "$data/codex.version"
        ;;
      *" view @openai/codex version "*) printf '0.153.2\n' ;;
      *) exit 1 ;;
    esac
    ;;
  curl)
    exit 1
    ;;
  uname)
    case "${1:-}" in
      -s) printf '%s\n' "${MSAM_FAKE_OS:-Linux}" ;;
      -m) printf 'arm64\n' ;;
      *) printf '%s\n' "${MSAM_FAKE_OS:-Linux}" ;;
    esac
    ;;
  codesign)
    case " $* " in
      *" --verify "*) [ "${MSAM_FAKE_SIGNING_VALID:-yes}" = yes ] ;;
      *" -dr "*)
        printf 'designated => identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"\n' \
          "${MSAM_FAKE_IDENTIFIER:-codex}" "${MSAM_FAKE_TEAM:-2DC432GLL2}" >&2
        ;;
      *" -dvvv "*)
        printf 'Identifier=%s\nTeamIdentifier=%s\n' \
          "${MSAM_FAKE_IDENTIFIER:-codex}" "${MSAM_FAKE_TEAM:-2DC432GLL2}" >&2
        ;;
      *) exit 1 ;;
    esac
    ;;
  spctl)
    [ "${MSAM_FAKE_SPCTL_VALID:-yes}" = yes ]
    ;;
  xattr)
    case " $* " in
      *" -p com.apple.quarantine "*)
        [ "$(cat "$data/quarantine")" = yes ]
        ;;
      *" -d com.apple.quarantine "*)
        printf 'no\n' > "$data/quarantine"
        ;;
      *) exit 1 ;;
    esac
    ;;
  realpath)
    count=$(cat "$data/realpath-count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$data/realpath-count"
    case "${MSAM_FAKE_REALPATH_MODE:-artifact}" in
      artifact) printf '%s\n' "$data/signed-artifact" ;;
      path-swap)
        if [ "$count" -gt 1 ]; then
          printf '%s\n' "$data/swapped-artifact"
        else
          printf '%s\n' "$data/signed-artifact"
        fi
        ;;
      directory) printf '%s\n' "$data/signed-directory" ;;
      parent) printf '%s\n' "$data/.." ;;
      glob) printf '%s\n' "$data/*" ;;
      symlink) printf '%s\n' "$data/signed-symlink" ;;
      unavailable) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  stat)
    printf '1:42\n'
    ;;
  herdr)
    action="${1:-} ${2:-}"
    case "$action" in
      "agent get")
        pane=${3:?}; key=$(agent_key "$pane")
        [ -f "$data/$key.status" ] || exit 1
        status=$(cat "$data/$key.status")
        [ "$status" != shell ] || exit 1
        kind=$(cat "$data/$key.kind")
        conversation=$(cat "$data/$key.conversation")
        printf '{"result":{"agent":{"status":"%s","kind":"%s","agent_session":{"value":"%s"}}}}\n' \
          "$status" "$kind" "$conversation"
        ;;
      "pane process-info")
        shift 2
        if [ "${1:-}" = "--pane" ]; then shift; fi
        pane=${1:?}; key=$(agent_key "$pane")
        printf '{"result":{"foreground_pid":%s}}\n' "$(cat "$data/$key.pid")"
        ;;
      "agent prompt")
        pane=${3:?}; key=$(agent_key "$pane")
        [ "${4:-}" = /exit ] || exit 1
        case "${MSAM_FAKE_EXIT_MODE:-shell}" in
          shell)
            printf 'shell\n' > "$data/$key.status"
            pid=$(cat "$data/$key.pid")
            printf '%s\n' "$((pid + 1000))" > "$data/$key.pid"
            ;;
          identity-change)
            printf 'idle\n' > "$data/$key.status"
            printf 'different-conversation\n' > "$data/$key.conversation"
            pid=$(cat "$data/$key.pid")
            printf '%s\n' "$((pid + 1000))" > "$data/$key.pid"
            ;;
          stale) : ;;
          *) exit 1 ;;
        esac
        ;;
      "agent start")
        name_arg=${3:?}
        shift 3
        kind='' pane='' conversation=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --kind) kind=$2; shift 2 ;;
            --pane) pane=$2; shift 2 ;;
            --timeout) shift 2 ;;
            --) shift; while [ "$#" -gt 0 ]; do conversation=$1; shift; done ;;
            *) shift ;;
          esac
        done
        key=$(agent_key "$pane")
        count_file="$data/$key.restore-count"
        count=0; [ ! -f "$count_file" ] || count=$(cat "$count_file")
        count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
        [ "$count" -gt "$(cat "$data/restore-failures")" ] || exit 1
        printf '%s\n' "$kind" > "$data/$key.kind"
        printf '%s\n' "$conversation" > "$data/$key.conversation"
        printf 'idle\n' > "$data/$key.status"
        pid=$(cat "$data/$key.pid")
        printf '%s\n' "$((pid + 1000))" > "$data/$key.pid"
        printf '{"result":{"name":"%s"}}\n' "$name_arg"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
