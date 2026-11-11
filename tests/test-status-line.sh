#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export AGENT_STATUS_STATE_DIR="$TMP_DIR"
FILE="$TMP_DIR/claude-status.json"

now="$(date +%s)"
reset_5h=$((now + 3600))
reset_7d=$((now + 7200))

feed() { printf '%s' "$1" | bash "$ROOT_DIR/claude-status-line.sh" >/dev/null; }
expect() {
  local label="$1" query="$2" want="$3" got
  got="$(jq -c "$query" "$FILE")"
  [[ "$got" == "$want" ]] || { printf 'FAIL %s: want %s, got %s\n' "$label" "$want" "$got" >&2; exit 1; }
}

feed "{\"session_id\":\"a\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":$reset_5h},\"seven_day\":{\"used_percentage\":18,\"resets_at\":$reset_7d}}}"
expect "fresh" '.rate_limits.five_hour.used_percentage' '5'

feed '{"session_id":"idle"}'
expect "keeps limits when missing" '[.session_id, .rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage]' '["idle",5,18]'

feed "{\"session_id\":\"stale\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":2,\"resets_at\":$reset_5h}}}"
expect "no decrease within window" '.rate_limits.five_hour.used_percentage' '5'

feed "{\"session_id\":\"a\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":1,\"resets_at\":$((reset_5h + 18000))}}}"
expect "new window replaces" '.rate_limits.five_hour.used_percentage' '1'

jq -c ".rate_limits.five_hour.resets_at = $((now - 10)) | .rate_limits.seven_day.resets_at = $((now - 10))" "$FILE" >"$FILE.tmp"
mv "$FILE.tmp" "$FILE"
feed '{"session_id":"idle"}'
expect "drops expired limits" '.rate_limits' 'null'

printf 'status-line tests passed.\n'
