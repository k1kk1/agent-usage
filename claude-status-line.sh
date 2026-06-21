#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
CLAUDE_STATUS_FILE="${CLAUDE_STATUS_FILE:-$STATE_DIR/claude-status.json}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

input_json="$(cat)"
tmp_file="$(mktemp "$STATE_DIR/claude-status.XXXXXX")" || exit 0
printf '%s\n' "$input_json" >"$tmp_file"
chmod 600 "$tmp_file" 2>/dev/null || true
mv "$tmp_file" "$CLAUDE_STATUS_FILE"

ctx_remain="$(jq -r '.context_window.remaining_percentage // "N/A"' <<<"$input_json" 2>/dev/null)"
rate_used="$(jq -r '.rate_limits.five_hour.used_percentage // 0' <<<"$input_json" 2>/dev/null)"
total_cost="$(jq -r '.cost.total_cost_usd // 0' <<<"$input_json" 2>/dev/null)"

if [[ "$rate_used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  rate_remain="$(jq -nr --argjson used "$rate_used" '100 - $used')"
else
  rate_remain="N/A"
fi

printf 'Context残: %s%% | RateLimit残: %s%% | Cost: $%s\n' "$ctx_remain" "$rate_remain" "$total_cost"
