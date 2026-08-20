#!/usr/bin/env bash
set -euo pipefail

# daemon が state.json へ書くキーと、macOS アプリが読むキーの一致を検証する。
# 片側だけ名前を変えると値が黙って nil になり、UI からは「単に表示されない」
# としか見えないため、機械的に突き合わせる。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-schema.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

MODEL_FILE="$ROOT_DIR/macos/AgentUsage/Sources/Shared/UsageState.swift"

export AGENT_STATUS_STATE_DIR="$TEST_DIR/state"
export AGENT_STATUS_STATE_FILE="$AGENT_STATUS_STATE_DIR/state.json"
export AGENT_STATUS_LOCK_DIR="$AGENT_STATUS_STATE_DIR/daemon.lock"
export CLAUDE_STATUS_FILE="$AGENT_STATUS_STATE_DIR/claude-status.json"

mkdir -p "$AGENT_STATUS_STATE_DIR"

source "$ROOT_DIR/agent-status-daemon.sh"

# context と cost まで含んだ statusLine JSON を食わせ、実際の変換結果で検証する。
cat >"$CLAUDE_STATUS_FILE" <<'EOF'
{
  "rate_limits": {
    "five_hour": {"used_percentage": 42, "resets_at": 1786000000},
    "seven_day": {"used_percentage": 17, "resets_at": 1786400000}
  },
  "context_window": {"used_percentage": 31, "remaining_percentage": 69},
  "cost": {"total_cost_usd": 1.23}
}
EOF

claude_json="$(fetch_claude_usage)"
codex_json='{"agent":"codex","label":"Codex","status":"ok","updated_at":"2026-08-09 10:00:00 JST","windows":{"secondary":{"label":"7d","used_pct":12,"reset_at":null}}}'

# usage も照合対象にするため、collector が実際に出す形をそのまま流し込む。
# cost_usd を持たない Codex 側も入れて、任意フィールドの取りこぼしを見る。
claude_usage="$(jq -nc '{
  today: {date:"2026-08-09", input:1, output:2, cache_write:3, cache_read:4, total:10, cost_usd:0.5},
  session: {id:"s1", input:1, output:2, cache_write:3, cache_read:4, total:10, cost_usd:0.5},
  recent_5h: {input:1, output:2, cache_write:3, cache_read:4, total:10, cost_usd:0.5},
  daily: [{date:"2026-08-09", input:1, output:2, cache_write:3, cache_read:4, total:10, cost_usd:0.5}]
}')"
codex_usage="$(jq -nc '{
  today: {date:"2026-08-09", input:1, output:2, cache_write:0, cache_read:4, total:7},
  session: null,
  daily: [{date:"2026-08-09", input:1, output:2, cache_write:0, cache_read:4, total:7}]
}')"

write_state "$claude_json" "$codex_json" "$claude_usage" "$codex_usage"

# 変換結果に context / cost が実際に載っていること。載っていなければ以降の照合が
# 素通りしてしまうため、まず存在を確かめる。
jq -e '
  .agents.claude.context.used_pct == 31
  and .agents.claude.context.remaining_pct == 69
  and .agents.claude.cost.total_usd == 1.23
' "$AGENT_STATUS_STATE_FILE" >/dev/null

# 構造体に対応するオブジェクトのキーだけを集める。
# エージェント ID と枠 ID は辞書のキーなので対象外。
mapfile -t state_keys < <(jq -r '
  [ keys_unsorted[],
    (.agents[] | keys_unsorted[]),
    (.agents[].windows[]? | keys_unsorted[]),
    (.agents[].last_success_windows[]? | keys_unsorted[]),
    (.agents[].context | select(type == "object") | keys_unsorted[]),
    (.agents[].cost | select(type == "object") | keys_unsorted[]),
    (.agents[].usage | select(type == "object") | keys_unsorted[]),
    (.agents[].usage.today? | select(type == "object") | keys_unsorted[]),
    (.agents[].usage.session? | select(type == "object") | keys_unsorted[]),
    (.agents[].usage.recent_5h? | select(type == "object") | keys_unsorted[]),
    (.agents[].usage.daily[]? | select(type == "object") | keys_unsorted[])
  ] | unique[]
' "$AGENT_STATUS_STATE_FILE")

missing=()
for key in "${state_keys[@]}"; do
  if [[ "$key" == *_* ]]; then
    # snake_case のキーは Swift のプロパティ名にできないため、必ず CodingKeys の
    # 生値として現れる。プロパティ名（totalUsd など）での一致を許すと、生値が
    # 間違っていても通ってしまうので、ここでは生値だけを見る。
    grep -qF "\"$key\"" "$MODEL_FILE" && continue
  else
    # 単語のキーは CodingKeys を書かずプロパティ名で受けられる。
    grep -qF "\"$key\"" "$MODEL_FILE" && continue
    grep -qE "\b${key}\b" "$MODEL_FILE" && continue
  fi
  missing+=("$key")
done

if ((${#missing[@]} > 0)); then
  printf 'state.json のキーを %s が読めていません:\n' "${MODEL_FILE#"$ROOT_DIR"/}" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi
