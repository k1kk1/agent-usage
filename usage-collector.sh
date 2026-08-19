#!/usr/bin/env bash
set -uo pipefail

# Claude Code と Codex のログからトークン利用数を集計する。
#
# 利用枠（5h/7d）は API が返す割合をそのまま使えるが、トークンの実数はどちらの
# エージェントも API では返さないため、ローカルのセッションログを読む。
#
# ログは追記のみで、終了したセッションのファイルは二度と変わらない。そこで
# ファイル単位で (size, mtime) をキャッシュし、変化したファイルだけ読み直す。
#
#   ./usage-collector.sh claude
#   ./usage-collector.sh codex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
CACHE_FILE="${AGENT_USAGE_CACHE_FILE:-$STATE_DIR/usage-cache.json}"
PRICING_FILE="${AGENT_USAGE_PRICING_FILE:-$SCRIPT_DIR/pricing.json}"

CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"

# trap は main のスコープ外で走るため、作業ディレクトリはグローバルに持つ。
TMP_DIR=""

DAILY_DAYS="${AGENT_USAGE_DAILY_DAYS:-7}"
[[ "$DAILY_DAYS" =~ ^[1-9][0-9]*$ ]] || DAILY_DAYS=7

empty_usage() {
  jq -nc '{today:null, session:null, daily:[]}'
}

# ファイルの識別子。mv による差し替えを検知したいので inode も混ぜる。
file_stamp() {
  local path="$1"
  # BSD (macOS) と GNU で stat の書式が違う。
  stat -f '%z:%m:%i' "$path" 2>/dev/null || stat -c '%s:%Y:%i' "$path" 2>/dev/null
}

# --- Claude ------------------------------------------------------------------
#
# transcript の assistant 行に message.usage が載る。同じ API 応答が複数行に
# 現れること、resume でセッションを引き継ぐと前のやり取りが新しいファイルへ
# コピーされることがあるため、message.id + requestId で重複を除く。
#
# timestamp は UTC の ISO8601 でミリ秒付き。jq の fromdateiso8601 は小数秒を
# 受け付けないので落としてから変換する。
claude_rows_program() {
  cat <<'JQ'
  def jst_date(ts):
    if ts == null then null
    else (ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // null) as $e
      | if $e == null then null else (($e + 32400) | strftime("%Y-%m-%d")) end
    end;

  select(.type == "assistant" and (.message.usage != null))
  | .message.usage as $u
  | {
      key: ((.message.id // "?") + "|" + (.requestId // "?")),
      date: jst_date(.timestamp),
      session: (.sessionId // null),
      model: (.message.model // "unknown"),
      input: ($u.input_tokens // 0),
      output: ($u.output_tokens // 0),
      cache_read: ($u.cache_read_input_tokens // 0),
      cache_write_5m: ($u.cache_creation.ephemeral_5m_input_tokens // 0),
      cache_write_1h: ($u.cache_creation.ephemeral_1h_input_tokens // 0),
      cache_write_total: ($u.cache_creation_input_tokens // 0)
    }
  # cache_creation の内訳が無い版でも合計は取れるので、内訳が空なら 5m 側に寄せる。
  | if (.cache_write_5m + .cache_write_1h) == 0 and .cache_write_total > 0
    then .cache_write_5m = .cache_write_total
    else .
    end
  | del(.cache_write_total)
  | select(.date != null)
JQ
}

collect_claude_file() {
  jq -c -f <(claude_rows_program) "$1" 2>/dev/null | jq -sc '.'
}

# --- Codex -------------------------------------------------------------------
#
# rollout ログの token_count イベントに含まれる total_token_usage はセッション
# 累計なので、合算せずファイルごとの最後の値を採る。
#
# 手元に Codex のログが無い環境でも壊れないよう、想定するキーが見つからなければ
# 空を返す。フィールド名は版によって揺れるため複数の綴りを見る。
collect_codex_file() {
  local path="$1"
  local date_hint
  # ログのパスは .../sessions/YYYY/MM/DD/rollout-*.jsonl 形式。
  date_hint="$(sed -n 's#.*/\([0-9]\{4\}\)/\([0-9]\{2\}\)/\([0-9]\{2\}\)/[^/]*$#\1-\2-\3#p' <<<"$path")"

  jq -sc --arg date_hint "$date_hint" '
    def jst_date(ts):
      if ts == null then null
      else (ts | sub("\\.[0-9]+"; "") | sub("Z$"; "Z") | fromdateiso8601? // null) as $e
        | if $e == null then null else (($e + 32400) | strftime("%Y-%m-%d")) end
      end;

    [ .[]
      | (.payload.info.total_token_usage
         // .info.total_token_usage
         // .total_token_usage) as $u
      | select($u != null)
      | { usage: $u, date: (jst_date(.timestamp) // ($date_hint | select(. != ""))) }
    ] as $rows
    | if ($rows | length) == 0 then []
      else
        ($rows | last) as $latest
        | $latest.usage as $u
        | [{
            key: ("codex|" + ($latest.date // "?") + "|" + (input_filename // "file")),
            date: $latest.date,
            session: null,
            model: "codex",
            input: (($u.input_tokens // 0) - ($u.cached_input_tokens // 0) | if . < 0 then 0 else . end),
            output: (($u.output_tokens // 0)),
            cache_read: ($u.cached_input_tokens // 0),
            cache_write_5m: 0,
            cache_write_1h: 0
          }]
        | map(select(.date != null))
      end
  ' "$path" 2>/dev/null
}

# --- 集計 --------------------------------------------------------------------

# 対象ファイルを列挙する。見つからなければ何も出さない。
list_files() {
  local agent="$1"
  case "$agent" in
    claude)
      [[ -d "$CLAUDE_PROJECTS_DIR" ]] || return 0
      find "$CLAUDE_PROJECTS_DIR" -type f -name '*.jsonl' 2>/dev/null
      ;;
    codex)
      [[ -d "$CODEX_SESSIONS_DIR" ]] || return 0
      find "$CODEX_SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null
      ;;
  esac
}

collect_file() {
  case "$1" in
    claude) collect_claude_file "$2" ;;
    codex) collect_codex_file "$2" ;;
  esac
}

main() {
  local agent="${1:-}"
  case "$agent" in
    claude | codex) ;;
    *)
      printf 'usage: %s claude|codex\n' "${0##*/}" >&2
      exit 2
      ;;
  esac

  command -v jq >/dev/null 2>&1 || {
    empty_usage
    exit 0
  }

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  local cache='{}'
  if [[ -s "$CACHE_FILE" ]]; then
    cache="$(jq -c --arg agent "$agent" '.[$agent] // {}' "$CACHE_FILE" 2>/dev/null)" || cache='{}'
    [[ -n "$cache" ]] || cache='{}'
  fi

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-usage-collect.XXXXXX")" || {
    empty_usage
    exit 0
  }
  trap 'rm -rf "$TMP_DIR"' EXIT
  local tmp_dir="$TMP_DIR"

  local next_cache="$tmp_dir/next.json"
  printf '{}' >"$next_cache"

  local rows_file="$tmp_dir/rows.json"
  : >"$rows_file"

  local path stamp cached rows
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    stamp="$(file_stamp "$path")"
    [[ -n "$stamp" ]] || continue

    # 変化していないファイルは前回の集計結果を使い回す。
    cached="$(jq -c --arg p "$path" --arg s "$stamp" \
      '.[$p] | select(. != null and .stamp == $s) | .rows' <<<"$cache" 2>/dev/null)"

    if [[ -n "$cached" && "$cached" != "null" ]]; then
      rows="$cached"
    else
      rows="$(collect_file "$agent" "$path")"
      [[ -n "$rows" ]] || rows='[]'
    fi

    printf '%s\n' "$rows" >>"$rows_file"
    jq -c --arg p "$path" --arg s "$stamp" --argjson rows "$rows" \
      '.[$p] = {stamp: $s, rows: $rows}' "$next_cache" >"$tmp_dir/next.tmp" \
      && mv "$tmp_dir/next.tmp" "$next_cache"
  done < <(list_files "$agent")

  # 消えたファイルのエントリは next_cache に載らないので自然に落ちる。
  if [[ -s "$next_cache" ]]; then
    local merged="$tmp_dir/cache.json"
    local existing='{}'
    [[ -s "$CACHE_FILE" ]] && existing="$(jq -c '.' "$CACHE_FILE" 2>/dev/null || printf '{}')"
    if jq -c --arg agent "$agent" --slurpfile next "$next_cache" \
      '.[$agent] = $next[0]' <<<"$existing" >"$merged" 2>/dev/null; then
      mv "$merged" "$CACHE_FILE" 2>/dev/null || true
      chmod 600 "$CACHE_FILE" 2>/dev/null || true
    fi
  fi

  local pricing='{}'
  [[ -s "$PRICING_FILE" ]] && pricing="$(jq -c '.' "$PRICING_FILE" 2>/dev/null || printf '{}')"

  local today
  today="$(TZ=Asia/Tokyo date +%Y-%m-%d)"

  # 全ファイルの行を重複排除してから日別・セッション別に畳む。
  jq -sc \
    --arg today "$today" \
    --argjson days "$DAILY_DAYS" \
    --argjson pricing "$pricing" '
    def totals:
      { input: (map(.input) | add // 0),
        output: (map(.output) | add // 0),
        cache_read: (map(.cache_read) | add // 0),
        cache_write: (map(.cache_write_5m + .cache_write_1h) | add // 0) }
      | . + { total: (.input + .output + .cache_read + .cache_write) };

    def cost($rows):
      ($pricing.models // {}) as $models
      | ($pricing.multipliers // {}) as $m
      | [ $rows[]
          | ($models[.model]) as $p
          | if $p == null then 0
            else
              ( .input * $p.input
                + .output * $p.output
                + .cache_read * $p.input * ($m.cache_read // 0.1)
                + .cache_write_5m * $p.input * ($m.cache_write_5m // 1.25)
                + .cache_write_1h * $p.input * ($m.cache_write_1h // 2.0)
              ) / 1000000
            end
        ] | add // 0;

    def summarize($rows):
      if ($rows | length) == 0 then null
      else ($rows | totals) + { cost_usd: (cost($rows) | . * 10000 | round / 10000) }
      end;

    # 各ファイルの行を平坦化し、キーで重複排除する。
    ( add // [] )
    | map(select(.date != null))
    | (reduce .[] as $r ({}; .[$r.key] = $r) | to_entries | map(.value)) as $rows

    | ($rows | map(select(.date == $today))) as $today_rows
    | ( $rows
        | group_by(.date)
        | map({ date: .[0].date, total: (map(.input + .output + .cache_read + .cache_write_5m + .cache_write_1h) | add // 0) })
        | sort_by(.date)
        | .[-$days:]
      ) as $daily

    # 直近のセッション = 最新の日付を持つ行の sessionId。
    | ( $rows | map(select(.session != null)) | sort_by(.date) | last | .session ) as $latest_session
    | ( $rows | map(select(.session != null and .session == $latest_session)) ) as $session_rows

    | { today: (summarize($today_rows) | if . == null then null else . + { date: $today } end),
        session: (summarize($session_rows) | if . == null then null else . + { id: $latest_session } end),
        daily: $daily }
  ' "$rows_file" 2>/dev/null || empty_usage
}

main "$@"
