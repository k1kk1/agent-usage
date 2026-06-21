#!/usr/bin/env bash
set -u

STATE_FILE="/tmp/agent-usage-simple-state.json"
CLAUDE_STATUS_FILE="$HOME/.cache/agent-status/claude-status.json"
INTERVAL_SECONDS=60

json_num() {
  case "${1:-}" in
    ''|null) printf 'null' ;;
    *[!0-9.]*|*.*.*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

epoch_to_iso() {
  local value="${1:-}"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf 'null'
    return
  fi
  date -u -r "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'null'
}

get_claude_json() {
  if [[ ! -s "$CLAUDE_STATUS_FILE" ]]; then
    jq -n '{claude:{five_hour:null, seven_day:null, context_remaining:null, cost_usd:null}}'
    return
  fi

  jq -c '{
    claude: {
      five_hour: (.rate_limits.five_hour.used_percentage // null),
      seven_day: (.rate_limits.seven_day.used_percentage // null),
      context_remaining: (.context_window.remaining_percentage // null),
      cost_usd: (.cost.total_cost_usd // null)
    }
  }' "$CLAUDE_STATUS_FILE" 2>/dev/null \
    || jq -n '{claude:{five_hour:null, seven_day:null, context_remaining:null, cost_usd:null}}'
}

get_codex_json() {
  local output rate_limits
  command -v codex >/dev/null 2>&1 || {
    jq -n '{codex:{five_hour:null, seven_day:null}}'
    return
  }

  output="$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"simple-agent-usage","version":"1.0"}}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
      sleep 10
    } | codex app-server 2>/dev/null
  )"

  rate_limits="$(jq -c 'select(.id == 2) | .result.rateLimits' <<<"$output" 2>/dev/null | head -1)"
  if [[ -z "$rate_limits" ]]; then
    jq -n '{codex:{five_hour:null, seven_day:null}}'
    return
  fi

  jq -c '{codex:{five_hour:(.primary.usedPercent // null), seven_day:(.secondary.usedPercent // null)}}' <<<"$rate_limits"
}

write_state_once() {
  local claude codex tmp
  claude="$(get_claude_json)"
  codex="$(get_codex_json)"
  tmp="${STATE_FILE}.$$"

  jq -n \
    --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson claude "$claude" \
    --argjson codex "$codex" \
    '$claude + $codex + {updated_at:$updated_at}' >"$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

while :; do
  write_state_once
  sleep "$INTERVAL_SECONDS"
done
