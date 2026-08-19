#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

export AGENT_STATUS_STATE_DIR="$TEST_DIR/state"
export AGENT_STATUS_STATE_FILE="$AGENT_STATUS_STATE_DIR/state.json"
export AGENT_STATUS_LOCK_DIR="$AGENT_STATUS_STATE_DIR/daemon.lock"

# mainは直接実行時だけ呼ばれるため、収集関数をネットワークなしで検証できる。
source "$ROOT_DIR/agent-status-daemon.sh"

success_claude='{"agent":"claude","label":"Claude Code","status":"ok","updated_at":"2026-08-09 10:00:00 JST","windows":{"primary":{"label":"5h","used_pct":42,"reset_at":null}}}'
success_codex='{"agent":"codex","label":"Codex","status":"ok","updated_at":"2026-08-09 10:00:00 JST","windows":{"secondary":{"label":"7d","used_pct":12,"reset_at":null}}}'
write_state "$success_claude" "$success_codex"

jq -e '
  .schema_version == 2
  and .agents.claude.last_success_windows.primary.used_pct == 42
  and .agents.codex.last_success_windows.secondary.used_pct == 12
' "$AGENT_STATUS_STATE_FILE" >/dev/null

failed_claude='{"agent":"claude","label":"Claude Code","status":"offline","message":"fixture failure","updated_at":"2026-08-09 10:01:00 JST","windows":{}}'
write_state "$failed_claude" "$success_codex"

jq -e '
  .agents.claude.status == "offline"
  and .agents.claude.last_success_windows.primary.used_pct == 42
  and .agents.claude.last_success_at != null
' "$AGENT_STATUS_STATE_FILE" >/dev/null

# トークン集計は利用枠とは別経路なので、集計だけ落ちても枠は残り、
# 逆に枠が落ちても集計は前回値が残る。
usage='{"today":{"date":"2026-08-09","input":1,"output":2,"cache_write":3,"cache_read":4,"total":10,"cost_usd":0.5},"session":{"id":"s1","input":1,"output":2,"cache_write":3,"cache_read":4,"total":10,"cost_usd":0.5},"daily":[{"date":"2026-08-09","total":10}]}'
write_state "$success_claude" "$success_codex" "$usage" 'null'

jq -e '
  .agents.claude.usage.today.total == 10
  and .agents.claude.usage.session.id == "s1"
  and (.agents.claude.usage.daily | length) == 1
  and .agents.codex.usage == null
' "$AGENT_STATUS_STATE_FILE" >/dev/null

# 集計に失敗した回（null）は、直前の集計結果を捨てない。
write_state "$success_claude" "$success_codex" 'null' 'null'

jq -e '.agents.claude.usage.today.total == 10' "$AGENT_STATUS_STATE_FILE" >/dev/null
