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
SLEEP_PID=""
LAST_RENDERED_UPDATED_AT=""

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

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

ensure_daemon() {
  start_daemon_if_needed
}

fmt_reset() {
  local value="$1"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '--:--'
    return
  fi

  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ JST$ ]]; then
    printf '%s' "$value" | cut -c 6-16 | tr '-' '/'
  else
    printf '%s' "$value"
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

state_value() {
  local expr="$1"
  jq -r "$expr // empty" "$STATE_FILE" 2>/dev/null
}

row() {
  local name="$1"
  local window="$2"
  local pct="$3"
  local expires="$4"
  local pct_label="--.-%"

  if [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    pct_label="$(printf '%4.1f%%' "$pct")"
  fi

  printf "%-7.7s ${DIM}%-2.2s${RESET} [%s] %6s ${DIM}%s${RESET}" \
    "$name" \
    "$window" \
    "$(progress_bar "$pct")" \
    "$pct_label" \
    "$(fmt_reset "$expires")"
}

strip_ansi() {
  sed $'s/\033\\[[0-9;]*[[:alpha:]]//g'
}

vlen() {
  printf '%s' "$1" | strip_ansi | wc -m | tr -d ' '
}

pad_to() {
  local text="$1"
  local width="$2"
  local len pad

  len="$(vlen "$text")"
  pad=$((width - len))
  ((pad < 0)) && pad=0
  printf '%s%*s' "$text" "$pad" ''
}

label_path() {
  local path="$1"
  case "$path" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${path#"$HOME"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

shorten_path() {
  local path="$1"
  local width="$2"
  local len

  len="$(vlen "$path")"
  if ((len <= width)); then
    printf '%s' "$path"
  elif ((width <= 1)); then
    printf '…'
  else
    printf '…%s' "${path: -$((width - 1))}"
  fi
}

clear_remaining_lines() {
  local used="$1"
  local lines i

  lines="${LINES:-$(tput lines 2>/dev/null || echo 24)}"
  for ((i = used; i < lines; i++)); do
    printf '\033[K\n'
  done
}

render_starting() {
  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET} ${DIM}· starting daemon...${RESET}\033[K\n"
  printf "${DIM}state: %s${RESET}\033[K\n" "$STATE_FILE"
  clear_remaining_lines 2
}

render_left_lines() {
  local updated="$1"
  local cc5p="$2" cc5e="$3" cc7p="$4" cc7e="$5"
  local cx5p="$6" cx5e="$7" cxwp="$8" cxwe="$9"
  local updated_label="waiting"

  [[ -n "$updated" ]] && updated_label="$(fmt_reset "$updated")"

  printf '%s\n' "$(printf "${BOLD}${CYAN} Agent Status${RESET}  ${DIM}· updated %s${RESET}" "$updated_label")"
  printf '%s\n' "$(printf "${DIM} ─────────────────────────────────────────${RESET}")"
  printf '%s\n' "$(row "Claude" "5h" "$cc5p" "$cc5e")"
  printf '%s\n' "$(row ""       "7d" "$cc7p" "$cc7e")"
  printf '%s\n' "$(row "Codex"  "5h" "$cx5p" "$cx5e")"
  printf '%s\n' "$(row ""       "7d" "$cxwp" "$cxwe")"
}

render_ports_lines() {
  local left_width="$1"
  local ports cols avail p c w

  ports="$(jq -r '.ports[]? | [.port, .command, .cwd] | @tsv' "$STATE_FILE" 2>/dev/null)"
  [[ -z "$ports" ]] && return

  cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}"
  avail=$((cols - left_width - 23))
  ((avail < 8)) && avail=8

  printf '%s\n' "$(printf "${DIM}ports${RESET}")"

  while IFS=$'\t' read -r p c w; do
    [[ -z "$p" ]] && continue
    printf '%s\n' "$(
      printf "${GREEN}%-6.6s${RESET} ${DIM}%-15.15s${RESET} %s" \
        "$p" \
        "$c" \
        "$(shorten_path "$(label_path "$w")" "$avail")"
    )"
  done <<<"$ports"
}

calc_lines_width() {
  local line max=0 len

  while IFS= read -r line; do
    len="$(vlen "$line")"
    ((len > max)) && max="$len"
  done

  printf '%s' "$max"
}

render_columns() {
  local left_text="$1"
  local right_text="$2"
  local left_width="$3"
  local left_count right_count n i left_line right_line

  left_count="$(printf '%s\n' "$left_text" | wc -l | tr -d ' ')"
  right_count=0
  [[ -n "$right_text" ]] && right_count="$(printf '%s\n' "$right_text" | wc -l | tr -d ' ')"
  n="$left_count"
  ((right_count > n)) && n="$right_count"

  printf '\033[H'

  for ((i = 1; i <= n; i++)); do
    left_line="$(printf '%s\n' "$left_text" | sed -n "${i}p")"
    right_line=""
    [[ -n "$right_text" ]] && right_line="$(printf '%s\n' "$right_text" | sed -n "${i}p")"
    printf '%s%s\033[K\n' \
      "$(pad_to "$left_line" "$left_width")" \
      "$right_line"
  done

  clear_remaining_lines "$n"
}

render_dashboard() {
  local updated="$1"
  local cc5p cc5e cc7p cc7e cx5p cx5e cxwp cxwe
  local left_text right_text left_width

  cc5p="$(state_value '.agents.claude.windows.primary.used_pct')"
  cc5e="$(state_value '.agents.claude.windows.primary.reset_at')"
  cc7p="$(state_value '.agents.claude.windows.secondary.used_pct')"
  cc7e="$(state_value '.agents.claude.windows.secondary.reset_at')"
  cx5p="$(state_value '.agents.codex.windows.primary.used_pct')"
  cx5e="$(state_value '.agents.codex.windows.primary.reset_at')"
  cxwp="$(state_value '.agents.codex.windows.secondary.used_pct')"
  cxwe="$(state_value '.agents.codex.windows.secondary.reset_at')"

  left_text="$(render_left_lines \
    "$updated" \
    "$cc5p" "$cc5e" \
    "$cc7p" "$cc7e" \
    "$cx5p" "$cx5e" \
    "$cxwp" "$cxwe"
  )"

  left_width="$(calc_lines_width <<<"$left_text")"
  left_width=$((left_width + 3))

  right_text="$(render_ports_lines "$left_width")"

  render_columns "$left_text" "$right_text" "$left_width"
}

draw() {
  local updated

  tput civis 2>/dev/null || true
  ensure_daemon

  if [[ ! -f "$STATE_FILE" ]]; then
    render_starting
    return
  fi

  updated="$(state_value '.updated_at')"
  if [[ -n "$updated" && "$updated" == "$LAST_RENDERED_UPDATED_AT" ]]; then
    return
  fi

  LAST_RENDERED_UPDATED_AT="$updated"
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
  if ! command_exists jq || ! command_exists bc; then
    printf 'agent-status-pane requires jq and bc\n' >&2
    exit 1
  fi

  trap cleanup EXIT
  trap stop_pane INT TERM

  while :; do
    draw
    sleep_for_refresh
  done
}

main "$@"
