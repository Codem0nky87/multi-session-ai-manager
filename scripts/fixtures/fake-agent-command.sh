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
      *" list -g --depth=0 @openai/codex "*) exit 0 ;;
      *" install -g @openai/codex@latest "*)
        [ "$(cat "$data/update-fails")" = "0" ] || exit 1
        printf '0.153.2\n' > "$data/codex.version"
        ;;
      *" view @openai/codex version "*) printf '0.153.2\n' ;;
      *) exit 1 ;;
    esac
    ;;
  curl)
    exit 1
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
        printf 'shell\n' > "$data/$key.status"
        pid=$(cat "$data/$key.pid")
        printf '%s\n' "$((pid + 1000))" > "$data/$key.pid"
        ;;
      "agent start")
        name_arg=${3:?}
        shift 3
        kind= pane= conversation=
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
