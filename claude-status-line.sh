#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
CLAUDE_STATUS_FILE="${CLAUDE_STATUS_FILE:-$STATE_DIR/claude-status.json}"
BAR_WIDTH="${CLAUDE_STATUS_BAR_WIDTH:-8}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

input_json="$(cat)"
tmp_file="$(mktemp "$STATE_DIR/claude-status.XXXXXX")" || exit 0
printf '%s\n' "$input_json" >"$tmp_file"
chmod 600 "$tmp_file" 2>/dev/null || true
mv "$tmp_file" "$CLAUDE_STATUS_FILE"

command -v jq >/dev/null 2>&1 || {
  printf 'Claude Code · jq is required\n'
  exit 0
}

if ! [[ "$BAR_WIDTH" =~ ^[1-9][0-9]*$ ]] || ((BAR_WIDTH > 24)); then
  BAR_WIDTH=8
fi

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[38;5;81m'
GREEN=$'\033[38;5;77m'
AMBER=$'\033[38;5;220m'
RED=$'\033[38;5;203m'
MUTED=$'\033[38;5;245m'
RESET=$'\033[0m'

json_value() {
  jq -r "$1 // empty" <<<"$input_json" 2>/dev/null
}

ansi_for() {
  local pct="${1:-}"
  local whole

  [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    printf '%s' "$MUTED"
    return
  }

  whole="${pct%%.*}"
  if ((whole >= 80)); then
    printf '%s' "$RED"
  elif ((whole >= 50)); then
    printf '%s' "$AMBER"
  else
    printf '%s' "$GREEN"
  fi
}

progress_bar() {
  local pct="${1:-}"
  local filled=0 empty color

  if [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    filled="$(jq -nr --arg pct "$pct" --argjson width "$BAR_WIDTH" \
      '($pct | tonumber) * $width / 100 | floor | if . < 0 then 0 elif . > $width then $width else . end')"
  fi

  empty=$((BAR_WIDTH - filled))
  color="$(ansi_for "$pct")"
  printf '%s' "$color"
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf '%s' "$MUTED"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf '%s' "$RESET"
}

pct_label() {
  local pct="${1:-}"

  if [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%4.1f%%' "$pct"
  else
    printf -- '--.-%%'
  fi
}

reset_label() {
  local epoch="${1:-}"

  [[ "$epoch" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    printf -- '--:--'
    return
  }
  epoch="${epoch%%.*}"

  if date -r "$epoch" '+%m/%d %H:%M' >/dev/null 2>&1; then
    date -r "$epoch" '+%m/%d %H:%M'
  elif date -d "@$epoch" '+%m/%d %H:%M' >/dev/null 2>&1; then
    date -d "@$epoch" '+%m/%d %H:%M'
  else
    printf -- '--:--'
  fi
}

metric() {
  local label="$1"
  local pct="$2"
  local reset_at="${3:-}"
  local color

  color="$(ansi_for "$pct")"
  printf "${DIM}%-3s${RESET} [%s]  %s%s${RESET}" \
    "$label" "$(progress_bar "$pct")" "$color" "$(pct_label "$pct")"
  [[ -n "$reset_at" ]] && printf "  ${DIM}%s${RESET}" "$(reset_label "$reset_at")"
}

spacing() {
  printf '   '
}

model="$(json_value '.model.display_name')"
cwd="$(json_value '.workspace.current_dir // .cwd')"
session="$(json_value '.session_name')"
branch="$(json_value '.worktree.branch // .workspace.git_worktree')"
ctx_used="$(json_value '.context_window.used_percentage')"
five_used="$(json_value '.rate_limits.five_hour.used_percentage')"
five_reset="$(json_value '.rate_limits.five_hour.resets_at')"
seven_used="$(json_value '.rate_limits.seven_day.used_percentage')"
seven_reset="$(json_value '.rate_limits.seven_day.resets_at')"
cost="$(json_value '.cost.total_cost_usd')"

[[ -n "$model" ]] || model="Claude"
directory="${cwd##*/}"
[[ -n "$directory" ]] || directory="~"

if [[ -z "$branch" && -n "$cwd" ]] && command -v git >/dev/null 2>&1; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
fi

printf "${BOLD}${CYAN}%s${RESET}  ${BOLD}%s${RESET}" "$model" "$directory"
if [[ -n "$branch" ]]; then
  spacing
  printf "${DIM}git${RESET} ${CYAN}%s${RESET}" "$branch"
fi
if [[ -n "$session" ]]; then
  spacing
  printf "${DIM}session${RESET} %s" "$session"
fi
if [[ "$cost" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  spacing
  printf "${DIM}cost${RESET} \$%.2f" "$cost"
fi
# Claude Code trims completely empty output lines. A non-breaking space keeps
# this visually blank spacer row in the rendered statusline.
printf '\n%s\n' $'\u00a0'

metric "ctx" "$ctx_used"
spacing
metric "5h" "$five_used" "$five_reset"
spacing
metric "7d" "$seven_used" "$seven_reset"
printf '\n'
