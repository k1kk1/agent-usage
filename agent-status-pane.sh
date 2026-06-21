#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${AGENT_STATUS_CONFIG_FILE:-$SCRIPT_DIR/agent-status.env}"
if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

DAEMON_SCRIPT="${AGENT_STATUS_DAEMON_SCRIPT:-$SCRIPT_DIR/agent-status-daemon.sh}"
STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
STATE_FILE="${AGENT_STATUS_STATE_FILE:-$STATE_DIR/state.json}"
LOCK_DIR="${AGENT_STATUS_LOCK_DIR:-$STATE_DIR/daemon.lock}"
REFRESH_SECONDS="${AGENT_STATUS_PANE_REFRESH_SECONDS:-3}"
DAEMON_LOG="${AGENT_STATUS_DAEMON_LOG:-$STATE_DIR/daemon.log}"
BAR_WIDTH="${AGENT_STATUS_BAR_WIDTH:-16}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

daemon_lock_is_live() {
  local pid
  [[ -d "$LOCK_DIR" ]] || return 1
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_daemon_if_needed() {
  mkdir -p "$STATE_DIR" || return
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  if daemon_lock_is_live; then
    return
  fi

  if [[ ! -x "$DAEMON_SCRIPT" ]]; then
    chmod +x "$DAEMON_SCRIPT" 2>/dev/null || true
  fi

  umask 077
  nohup "$DAEMON_SCRIPT" >>"$DAEMON_LOG" 2>&1 &
}

fmt_reset() {
  local value="$1"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '--:--'
    return
  fi

  if date -j -f "%Y-%m-%d %H:%M:%S JST" "$value" "+%m/%d %H:%M" >/dev/null 2>&1; then
    date -j -f "%Y-%m-%d %H:%M:%S JST" "$value" "+%m/%d %H:%M"
  elif date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" "+%m/%d %H:%M" >/dev/null 2>&1; then
    TZ=Asia/Tokyo date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" "+%m/%d %H:%M"
  else
    printf '%s' "$value" | sed 's/T/ /; s/Z$//' | cut -c 6-16
  fi
}

progress_bar() {
  local pct="$1"
  local filled empty

  if [[ -z "$pct" || "$pct" == "null" || ! "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%*s' "$BAR_WIDTH" '' | tr ' ' '░'
    return
  fi

  filled="$(printf 'scale=0; (%s * %s / 100) / 1\n' "$pct" "$BAR_WIDTH" | bc 2>/dev/null)"
  [[ "$filled" =~ ^[0-9]+$ ]] || filled=0
  (( filled < 0 )) && filled=0
  (( filled > BAR_WIDTH )) && filled="$BAR_WIDTH"
  empty=$((BAR_WIDTH - filled))

  printf '%*s' "$filled" '' | tr ' ' '█'
  printf '%*s' "$empty" '' | tr ' ' '░'
}

render_agent() {
  local key="$1"
  local name="$2"
  local status message primary_pct primary_reset secondary_pct secondary_reset

  status="$(jq -r --arg key "$key" '.agents[$key].status // "offline"' "$STATE_FILE" 2>/dev/null)"
  message="$(jq -r --arg key "$key" '.agents[$key].message // empty' "$STATE_FILE" 2>/dev/null)"

  printf '%-12s ' "$name"
  if [[ "$status" != "ok" && "$status" != "stale" ]]; then
    case "$status" in
      auth_error) printf 'Auth Error\n' ;;
      rate_limited) printf 'Rate Limited\n' ;;
      offline) printf 'Offline\n' ;;
      parse_error) printf 'Parse Error\n' ;;
      *) printf '%s\n' "$status" ;;
    esac
    if [[ -n "$message" ]]; then
      printf '  %s\n' "$message" | cut -c 1-46
    fi
    return
  fi

  primary_pct="$(jq -r --arg key "$key" '.agents[$key].windows.primary.used_pct // null' "$STATE_FILE")"
  primary_reset="$(jq -r --arg key "$key" '.agents[$key].windows.primary.reset_at // null' "$STATE_FILE")"
  if [[ "$primary_pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if [[ "$status" == "stale" ]]; then
      printf '%5.1f%% stale\n' "$primary_pct"
    else
      printf '%5.1f%%\n' "$primary_pct"
    fi
  else
    printf '  --.-%%\n'
  fi
  printf '  5h [%s] %s\n' "$(progress_bar "$primary_pct")" "$(fmt_reset "$primary_reset")"

  secondary_pct="$(jq -r --arg key "$key" '.agents[$key].windows.secondary.used_pct // empty' "$STATE_FILE")"
  secondary_reset="$(jq -r --arg key "$key" '.agents[$key].windows.secondary.reset_at // empty' "$STATE_FILE")"
  if [[ "$secondary_pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '  7d [%s] %s\n' "$(progress_bar "$secondary_pct")" "$(fmt_reset "$secondary_reset")"
  fi
}

render() {
  local updated_at
  tput civis 2>/dev/null || true
  tput cup 0 0 2>/dev/null || clear
  tput ed 2>/dev/null || true

  printf 'AI Agent Quotas\n'
  printf '================\n'

  if [[ ! -s "$STATE_FILE" ]]; then
    printf 'Waiting for daemon...\n'
    return
  fi

  updated_at="$(jq -r '.updated_at // empty' "$STATE_FILE" 2>/dev/null)"
  printf 'Updated %s\n\n' "$(fmt_reset "$updated_at")"

  render_agent "claude" "Claude"
  printf '\n'
  render_agent "codex" "Codex"
}

cleanup() {
  tput cnorm 2>/dev/null || true
}

stop_pane() {
  cleanup
  exit 0
}

main() {
  if ! command_exists jq || ! command_exists bc; then
    printf 'agent-status-pane requires jq and bc\n' >&2
    exit 1
  fi

  start_daemon_if_needed
  trap cleanup EXIT
  trap stop_pane INT TERM

  while :; do
    render
    sleep "$REFRESH_SECONDS"
  done
}

main "$@"
