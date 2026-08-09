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

# Soft but readable 256-color palette
CYAN=$'\033[38;5;81m'    # cyan: 元色より少し柔らかい
GREEN=$'\033[38;5;77m'   # green: パステルより見やすい
AMBER=$'\033[38;5;220m'  # amber: 黄色すぎず警告感あり
RED=$'\033[38;5;203m'    # red: 強すぎない赤
MUTED=$'\033[38;5;245m'  # empty bar / subtle text

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
    printf '%s' "$MUTED"
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
  printf '%s' "$MUTED"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf '%s' "$RESET"
}

state_value() {
  local expr="$1"
  jq -r "$expr // empty" "$STATE_FILE" 2>/dev/null
}

# 枠は 5h/7d 固定ではない。primary / secondary を先頭にしつつ、
# 将来増える枠も取りこぼさず TSV で取り出す。
state_windows() {
  local agent="$1"

  jq -r --arg agent "$agent" '
    (.agents[$agent].windows // {})
    | to_entries
    | sort_by([
        (if .key == "primary" then 0
         elif .key == "secondary" then 1
         else 2 end),
        .key
      ])
    | .[]
    | [(.value.label // .key), (.value.used_pct // ""), (.value.reset_at // "")]
    | @tsv
  ' "$STATE_FILE" 2>/dev/null
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
    no_windows)  label="No Quota Windows" ;;
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

  # ラベルは "5h" "7d" のほか "30m" のような 3 桁もありうる。
  printf "%-7.7s ${DIM}%-3.3s${RESET} [%s] %s%6s${RESET} ${DIM}%s${RESET}" \
    "$name" \
    "$window" \
    "$(progress_bar "$pct")" \
    "$color" \
    "$pct_label" \
    "$(fmt_reset "$expires")"
}

# エージェント 1 つ分を描画する。エラー時と、枠が 1 つも無い時は 1 行にまとめる。
agent_block() {
  local name="$1"
  local agent="$2"
  local status message windows first="$name"

  status="$(state_value ".agents.$agent.status")"
  message="$(state_value ".agents.$agent.message")"

  if [[ "${status:-ok}" != "ok" ]]; then
    printf '%s\033[K\n' "$(error_row "$name" "$status" "$message")"
    return
  fi

  windows="$(state_windows "$agent")"
  if [[ -z "$windows" ]]; then
    printf '%s\033[K\n' "$(error_row "$name" "no_windows" "")"
    return
  fi

  local label pct expires
  while IFS=$'\t' read -r label pct expires; do
    printf '%s\033[K\n' "$(row "$first" "$label" "$pct" "$expires")"
    first=""
  done <<<"$windows"
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

  [[ -n "$updated" ]] && updated_label="$(fmt_reset "$updated")"

  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET}  ${DIM}· updated %s${RESET}\033[K\n" "$updated_label"
  printf "${DIM} ─────────────────────────────────────────${RESET}\033[K\n"

  agent_block "Claude" "claude"
  agent_block "Codex" "codex"

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
