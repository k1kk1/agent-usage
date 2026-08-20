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

# 表示幅に収まること。ペインは細い列で使うので、1 行でも溢れると以降がずれる。
# バー幅の下限からレイアウトが成立する 26 桁を最小として確認する。
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[[?0-9;]*[HJKlhc]//g'
}

# awk の length はロケールによってバイト数を返すことがあるため、文字数は python で数える。
assert_fits() {
  local state="$1"
  local cols="$2"

  "$ROOT_DIR/agent-status-pane.sh" --test "$state" --cols "$cols" \
    | strip_ansi \
    | python3 -c '
import sys
cols = int(sys.argv[1])
path = sys.argv[2]
over = [line for line in sys.stdin.read().splitlines() if len(line) > cols]
if over:
    print(f"pane overflowed at {cols} cols: {path}", file=sys.stderr)
    for line in over:
        print(f"  {len(line)}: {line}", file=sys.stderr)
    raise SystemExit(1)
' "$cols" "$state"
}

if command -v python3 >/dev/null 2>&1; then
  for state in "$ROOT_DIR"/sample/state-*.json; do
    for cols in 26 34 48 80; do
      assert_fits "$state" "$cols"
    done
  done
fi

# 長いエラーメッセージでも折り返さないこと。
long_error="$(mktemp "${TMPDIR:-/tmp}/agent-usage-longerr.XXXXXX")"
trap 'rm -f "$TEST_FILE" "$long_error"' EXIT
jq '.agents.claude.message = "Claude statusLine JSON not found: please configure statusLine in ~/.claude/settings.json and restart Claude Code"' \
  "$ROOT_DIR/sample/state-offline.json" >"$long_error"
if command -v python3 >/dev/null 2>&1; then
  assert_fits "$long_error" 48
fi

# 数値でない AGENT_STATUS_BAR_WIDTH でも落ちないこと。
# 以前は set -u 下の算術比較で "unbound variable" になっていた。
if ! AGENT_STATUS_BAR_WIDTH=abc "$ROOT_DIR/agent-status-pane.sh" \
  --test "$ROOT_DIR/sample/state-low.json" --cols 48 >/dev/null 2>"$long_error.err"; then
  printf 'pane failed with a non-numeric bar width\n' >&2
  exit 1
fi
if [[ -s "$long_error.err" ]]; then
  printf 'pane wrote errors with a non-numeric bar width:\n' >&2
  cat "$long_error.err" >&2
  rm -f "$long_error.err"
  exit 1
fi
rm -f "$long_error.err"

# トークン行が出ること、無効化できること。
rendered="$("$ROOT_DIR/agent-status-pane.sh" --test "$ROOT_DIR/sample/state-low.json" --cols 48)"
[[ "$rendered" == *"tokens"* ]]
[[ "$rendered" == *"1.2M"* ]]

rendered="$(AGENT_STATUS_SHOW_TOKENS=0 "$ROOT_DIR/agent-status-pane.sh" \
  --test "$ROOT_DIR/sample/state-low.json" --cols 48)"
[[ "$rendered" != *"tokens"* ]]
