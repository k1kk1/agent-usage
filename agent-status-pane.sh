#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_SCRIPT="${AGENT_STATUS_DAEMON_SCRIPT:-$SCRIPT_DIR/agent-status-daemon.sh}"
STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
STATE_FILE="${AGENT_STATUS_STATE_FILE:-$STATE_DIR/state.json}"
LOCK_DIR="${AGENT_STATUS_LOCK_DIR:-$STATE_DIR/daemon.lock}"
REFRESH_SECONDS="${AGENT_STATUS_PANE_REFRESH_SECONDS:-3}"
DAEMON_LOG="${AGENT_STATUS_DAEMON_LOG:-$STATE_DIR/daemon.log}"
BAR_WIDTH="${AGENT_STATUS_BAR_WIDTH:-16}"
SLEEP_PID=""
LAST_RENDERED_STATE_HASH=""
TEST_MODE=0

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
AMBER=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage:
  ./agent-status-pane.sh
  ./agent-status-pane.sh --test STATE_JSON

Options:
  --test STATE_JSON   Render the given state JSON once without starting daemon.
  --help              Show this help.
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --test|--file|--state-file)
        if [[ -z "${2:-}" ]]; then
          printf '%s requires a file path\n' "$1" >&2
          exit 2
        fi
        STATE_FILE="$2"
        TEST_MODE=1
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      -*)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        STATE_FILE="$1"
        TEST_MODE=1
        shift
        ;;
    esac
  done
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

ensure_daemon() {
  start_daemon_if_needed
}

fmt_reset() {
  local value="$1"

  if [[ -z "$value" || "$value" == "null" ]]; then
    printf -- '--:--'
    return
  fi

  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ JST$ ]]; then
    printf '%s' "$value" | cut -c 6-16 | tr '-' '/'
  else
    printf '%s' "$value"
  fi
}

ansi_for() {
  local pct="$1"
  local whole

  if [[ ! "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$RESET"
    return
  fi

  whole="${pct%%.*}"

  if ((whole >= 80)); then
    printf '%s' "$RED"
  elif ((whole >= 50)); then
    printf '%s' "$AMBER"
  else
    printf '%s' "$GREEN"
  fi
}

progress_filled() {
  local pct="$1"

  jq -nr \
    --arg pct "$pct" \
    --argjson width "$BAR_WIDTH" '
      ($pct | tonumber? // 0) as $p
      | (($p * $width / 100) | floor)
      | if . < 0 then 0 elif . > $width then $width else . end
    ' 2>/dev/null
}

progress_bar() {
  local pct="$1"
  local filled empty color

  if [[ -z "$pct" || "$pct" == "null" || ! "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$DIM"
    printf '%*s' "$BAR_WIDTH" '' | tr ' ' '░'
    printf '%s' "$RESET"
    return
  fi

  filled="$(progress_filled "$pct")"
  [[ "$filled" =~ ^[0-9]+$ ]] || filled=0

  (( filled < 0 )) && filled=0
  (( filled > BAR_WIDTH )) && filled="$BAR_WIDTH"

  empty=$((BAR_WIDTH - filled))
  color="$(ansi_for "$pct")"

  printf '%s' "$color"
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf '%s' "$DIM"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf '%s' "$RESET"
}

state_value() {
  local expr="$1"
  jq -r "$expr // empty" "$STATE_FILE" 2>/dev/null
}

state_hash() {
  local json

  json="$(jq -cS . "$STATE_FILE" 2>/dev/null)" || return 1

  if command_exists shasum; then
    printf '%s' "$json" | shasum | awk '{print $1}'
  elif command_exists sha256sum; then
    printf '%s' "$json" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$json" | cksum | awk '{print $1 ":" $2}'
  fi
}

error_row() {
  local name="$1"
  local status="$2"
  local message="$3"
  local label

  case "$status" in
    offline)     label="Offline" ;;
    parse_error) label="Parse Error" ;;
    error)       label="Error" ;;
    "")          label="Unknown" ;;
    *)           label="$status" ;;
  esac

  [[ -n "$message" && "$message" != "null" ]] && label="$label: $message"

  printf "%-7.7s ${RED}%s${RESET}" "$name" "$label"
}

row() {
  local name="$1"
  local window="$2"
  local pct="$3"
  local expires="$4"
  local color="$RESET"
  local pct_label="--.-%"

  if [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    color="$(ansi_for "$pct")"
    pct_label="$(printf '%4.1f%%' "$pct")"
  fi

  printf "%-7.7s ${DIM}%-2.2s${RESET} [%s] %s%6s${RESET} ${DIM}%s${RESET}" \
    "$name" \
    "$window" \
    "$(progress_bar "$pct")" \
    "$color" \
    "$pct_label" \
    "$(fmt_reset "$expires")"
}

clear_to_end() {
  printf '\033[J'
}

render_starting() {
  local log_tail=""

  if [[ -f "$DAEMON_LOG" ]]; then
    log_tail="$(tail -n 3 "$DAEMON_LOG" 2>/dev/null || true)"
  fi

  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET} ${DIM}· starting daemon...${RESET}\033[K\n"
  printf "${DIM}state: %s${RESET}\033[K\n" "$STATE_FILE"

  if [[ -n "$log_tail" ]]; then
    printf "\033[K\n"
    printf "${DIM}daemon log:${RESET}\033[K\n"
    while IFS= read -r line; do
      printf "${RED}%s${RESET}\033[K\n" "$line"
    done <<<"$log_tail"
  fi

  clear_to_end
}

render_dashboard() {
  local updated="$1"
  local updated_label="waiting"

  local cc_status cc_msg cc5p cc5e cc7p cc7e
  local cx_status cx_msg cx5p cx5e cxwp cxwe

  [[ -n "$updated" ]] && updated_label="$(fmt_reset "$updated")"

  cc_status="$(state_value '.agents.claude.status')"
  cc_msg="$(state_value '.agents.claude.message')"
  cc5p="$(state_value '.agents.claude.windows.primary.used_pct')"
  cc5e="$(state_value '.agents.claude.windows.primary.reset_at')"
  cc7p="$(state_value '.agents.claude.windows.secondary.used_pct')"
  cc7e="$(state_value '.agents.claude.windows.secondary.reset_at')"

  cx_status="$(state_value '.agents.codex.status')"
  cx_msg="$(state_value '.agents.codex.message')"
  cx5p="$(state_value '.agents.codex.windows.primary.used_pct')"
  cx5e="$(state_value '.agents.codex.windows.primary.reset_at')"
  cxwp="$(state_value '.agents.codex.windows.secondary.used_pct')"
  cxwe="$(state_value '.agents.codex.windows.secondary.reset_at')"

  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET}  ${DIM}· updated %s${RESET}\033[K\n" "$updated_label"
  printf "${DIM} ─────────────────────────────────────────${RESET}\033[K\n"

  if [[ "${cc_status:-ok}" != "ok" ]]; then
    printf '%s\033[K\n' "$(error_row "Claude" "$cc_status" "$cc_msg")"
    printf '\033[K\n'
  else
    printf '%s\033[K\n' "$(row "Claude" "5h" "$cc5p" "$cc5e")"
    printf '%s\033[K\n' "$(row ""       "7d" "$cc7p" "$cc7e")"
  fi

  if [[ "${cx_status:-ok}" != "ok" ]]; then
    printf '%s\033[K\n' "$(error_row "Codex" "$cx_status" "$cx_msg")"
    printf '\033[K\n'
  else
    printf '%s\033[K\n' "$(row "Codex"  "5h" "$cx5p" "$cx5e")"
    printf '%s\033[K\n' "$(row ""       "7d" "$cxwp" "$cxwe")"
  fi

  clear_to_end
}

draw() {
  local updated current_hash

  tput civis 2>/dev/null || true

  if ((TEST_MODE == 0)); then
    ensure_daemon
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    if ((TEST_MODE == 1)); then
      printf 'state file not found: %s\n' "$STATE_FILE" >&2
      return 1
    else
      render_starting
    fi
    return
  fi

  current_hash="$(state_hash)" || {
    printf '\033[H'
    printf "${BOLD}${CYAN} Agent Status${RESET} ${RED}· invalid state json${RESET}\033[K\n"
    printf "${DIM}state: %s${RESET}\033[K\n" "$STATE_FILE"
    clear_to_end
    return
  }

  if [[ -n "$current_hash" && "$current_hash" == "$LAST_RENDERED_STATE_HASH" ]]; then
    return
  fi

  LAST_RENDERED_STATE_HASH="$current_hash"

  updated="$(state_value '.updated_at')"
  render_dashboard "$updated"
}

cleanup() {
  if [[ -n "${SLEEP_PID:-}" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi

  tput cnorm 2>/dev/null || true
}

stop_pane() {
  cleanup
  exit 0
}

sleep_for_refresh() {
  sleep "$REFRESH_SECONDS" &
  SLEEP_PID="$!"
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
}

main() {
  parse_args "$@"

  if ! command_exists jq; then
    printf 'agent-status-pane requires jq\n' >&2
    exit 1
  fi

  trap cleanup EXIT
  trap stop_pane INT TERM

  if ((TEST_MODE == 1)); then
    draw
    exit $?
  fi

  while :; do
    draw
    sleep_for_refresh
  done
}

main "$@"
