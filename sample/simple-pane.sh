#!/usr/bin/env bash
set -u

STATE_FILE="/tmp/agent-usage-simple-state.json"
DAEMON_SCRIPT="/Users/kikki/src/agent-usage/sample/simple-daemon.sh"

start_daemon() {
  pgrep -f "$DAEMON_SCRIPT" >/dev/null 2>&1 && return
  nohup "$DAEMON_SCRIPT" >/tmp/agent-usage-simple-daemon.log 2>&1 &
}

value() {
  local expr="$1"
  if [[ -s "$STATE_FILE" ]]; then
    jq -r "$expr // \"-\"" "$STATE_FILE" 2>/dev/null
  else
    printf '-'
  fi
}

draw() {
  clear
  printf 'AI Agent Quotas\n'
  printf '================\n'
  printf 'Updated: %s\n\n' "$(value '.updated_at')"

  printf 'Claude 5h:       %s%%\n' "$(value '.claude.five_hour')"
  printf 'Claude 7d:       %s%%\n' "$(value '.claude.seven_day')"
  printf 'Claude context:  %s%%\n' "$(value '.claude.context_remaining')"
  printf 'Claude cost:     $%s\n' "$(value '.claude.cost_usd')"
  printf '\n'
  printf 'Codex 5h:        %s%%\n' "$(value '.codex.five_hour')"
  printf 'Codex 7d:        %s%%\n' "$(value '.codex.seven_day')"
}

cleanup() {
  tput cnorm 2>/dev/null || true
}

stop_pane() {
  cleanup
  exit 0
}

start_daemon
trap cleanup EXIT
trap stop_pane INT TERM

while :; do
  draw
  sleep 3
done
