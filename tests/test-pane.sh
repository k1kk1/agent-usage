#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-usage-pane.XXXXXX")"
trap 'rm -f "$TEST_FILE"' EXIT

bash -n "$ROOT_DIR/agent-status-daemon.sh" "$ROOT_DIR/agent-status-pane.sh" "$ROOT_DIR/claude-status-line.sh"

for state in "$ROOT_DIR"/sample/state-*.json; do
  "$ROOT_DIR/agent-status-pane.sh" --test "$state" >/dev/null
done

jq '
  .agents.codex.windows.tertiary = {
    label: "30m",
    used_pct: 18,
    reset_at: "2026-08-09 11:00:00 JST"
  }
' "$ROOT_DIR/sample/state-low.json" >"$TEST_FILE"

rendered="$("$ROOT_DIR/agent-status-pane.sh" --test "$TEST_FILE")"
[[ "$rendered" == *"30m"* ]]
