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
STATE_FILE="${AGENT_STATUS_STATE_FILE:-$STATE_DIR/state.json}"

# 行の形（フィールドや識別子の作り方）を変えたら上げる。
# 変えないと、更新されていないログのキャッシュが旧形式のまま残り続ける。
CACHE_VERSION=2
PRICING_FILE="${AGENT_USAGE_PRICING_FILE:-$SCRIPT_DIR/pricing.json}"

CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"

# trap は main のスコープ外で走るため、作業ディレクトリはグローバルに持つ。
TMP_DIR=""

# アプリ側で「直近 N 日」を自由に合算できるよう、1 か月分を残す。
DAILY_DAYS="${AGENT_USAGE_DAILY_DAYS:-31}"
[[ "$DAILY_DAYS" =~ ^[1-9][0-9]*$ ]] || DAILY_DAYS=31

empty_usage() {
  jq -nc '{today:null, session:null, recent_5h:null, daily:[]}'
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
  def epoch(ts):
    if ts == null then null
    else (ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // null)
    end;

  def jst_date(ts):
    epoch(ts) as $e
    | if $e == null then null else (($e + 32400) | strftime("%Y-%m-%d")) end;

  select(.type == "assistant" and (.message.usage != null))
  | .message.usage as $u
  | {
      key: ((.message.id // "?") + "|" + (.requestId // "?")),
      date: jst_date(.timestamp),
      # 直近 5 時間ぶんを切り出すために時刻も残す。日付だけでは 5h 枠に合わせられない。
      ts: epoch(.timestamp),
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

  # token_count イベントの last_token_usage は、その 1 回の API 呼び出しぶん。
  # イベントごとに timestamp が付くので、これを 1 行として扱えば日付をまたぐ
  # セッションでも正しい日に振り分けられ、枠ごとの切り出しもできる。
  # 累計（total_token_usage）と足し合わせが一致することは確認済み。
  #
  # last_token_usage を持たない版のために、累計の最後の値を使う従来の経路も残す。
  jq -sc --arg date_hint "$date_hint" --arg path "$path" '
    def epoch(ts):
      if ts == null then null
      else (ts | sub("\\.[0-9]+"; "") | fromdateiso8601? // null)
      end;

    def jst_date(ts):
      epoch(ts) as $e
      | if $e == null then null else (($e + 32400) | strftime("%Y-%m-%d")) end;

    def row($u; $key; $date; $ts):
      { key: $key,
        date: $date,
        ts: $ts,
        session: null,
        model: "codex",
        input: (($u.input_tokens // 0) - ($u.cached_input_tokens // 0) | if . < 0 then 0 else . end),
        output: ($u.output_tokens // 0),
        cache_read: ($u.cached_input_tokens // 0),
        cache_write_5m: ($u.cache_write_input_tokens // 0),
        cache_write_1h: 0
      };

    # ordinal を持たない版のログがあるため、行の識別子には並び順を使う。
    # ordinal を当てにすると、無い版で全行が同じキーになって重複除去に飲まれる。
    [ .[]
      | { info: (.payload.info // .info),
          ts: epoch(.timestamp),
          date: (jst_date(.timestamp) // ($date_hint | select(. != ""))) }
      | select(.info != null)
    ]
    | to_entries
    | map(.value + { index: .key }) as $events

    | ($events | map(select(.info.last_token_usage != null))) as $turns
    | if ($turns | length) > 0 then
        $turns
        | map(row(.info.last_token_usage;
                  ($path + "|" + (.index | tostring));
                  .date;
                  .ts))
      else
        ($events | map(select(.info.total_token_usage != null))) as $totals
        | if ($totals | length) == 0 then []
          else
            ($totals | last) as $latest
            # 累計しか無い版では 1 回ごとに切り出せないので、時刻は持たせない。
            | [row($latest.info.total_token_usage;
                   ($path + "|total");
                   $latest.date;
                   null)]
          end
      end
    | map(select(.date != null))
  ' "$path" 2>/dev/null
}

# 現在の 5h 枠が始まった時刻。state.json の reset_at から 5 時間引いて求める。
#
# 「直近 5 時間」で切ると枠のリセットをまたいだときに前の枠ぶんまで数えてしまい、
# 枠の使用率と突き合わせた見積りが実際より大きく出る。
#
# state.json は 1 つ前の周期の値だが、5h 枠のリセット時刻は 5 時間に一度しか
# 変わらないため、60 秒古くても問題にならない。
window_start_epoch() {
  local agent="$1" reset epoch
  [[ -s "$STATE_FILE" ]] || return 1

  reset="$(jq -r --arg a "$agent" '
    .agents[$a].windows // {}
    | to_entries[]
    | select(.value.label == "5h")
    | .value.reset_at // empty
  ' "$STATE_FILE" 2>/dev/null | head -1)"
  [[ -n "$reset" ]] || return 1

  # BSD (macOS) と GNU で date の書式が違う。
  epoch="$(TZ=Asia/Tokyo date -j -f '%Y-%m-%d %H:%M:%S JST' "$reset" +%s 2>/dev/null \
    || TZ=Asia/Tokyo date -d "${reset% JST}" +%s 2>/dev/null)"
  [[ -n "$epoch" ]] || return 1

  printf '%s\n' "$((epoch - 18000))"
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
    cache="$(jq -c --arg agent "$agent" --argjson version "$CACHE_VERSION" \
      'if (.version // 0) == $version then (.[$agent] // {}) else {} end' \
      "$CACHE_FILE" 2>/dev/null)" || cache='{}'
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
    if [[ -s "$CACHE_FILE" ]]; then
      # 版が違うキャッシュは、もう片方のエージェントぶんも作り直す。
      existing="$(jq -c --argjson version "$CACHE_VERSION" \
        'if (.version // 0) == $version then . else {} end' \
        "$CACHE_FILE" 2>/dev/null || printf '{}')"
    fi
    if jq -c --arg agent "$agent" --argjson version "$CACHE_VERSION" \
      --slurpfile next "$next_cache" \
      '.version = $version | .[$agent] = $next[0]' <<<"$existing" >"$merged" 2>/dev/null; then
      mv "$merged" "$CACHE_FILE" 2>/dev/null || true
      chmod 600 "$CACHE_FILE" 2>/dev/null || true
    fi
  fi

  local pricing='{}'
  [[ -s "$PRICING_FILE" ]] && pricing="$(jq -c '.' "$PRICING_FILE" 2>/dev/null || printf '{}')"

  local today
  today="$(TZ=Asia/Tokyo date +%Y-%m-%d)"

  # 全ファイルの行を重複排除してから日別・セッション別に畳む。
  local now_epoch window_start
  now_epoch="$(date +%s)"

  window_start="$(window_start_epoch "$agent" 2>/dev/null || true)"
  # 枠の開始が取れない、未来を指している（枠がまだ開いていない）、または
  # 5 時間より前を指している（reset_at を跨いで state.json が古い）ときは
  # 直近 5 時間で代用する。
  if [[ ! "$window_start" =~ ^[0-9]+$ ]] \
    || ((window_start > now_epoch)) \
    || ((window_start < now_epoch - 18000)); then
    window_start=$((now_epoch - 18000))
  fi

  jq -sc \
    --arg today "$today" \
    --argjson now "$now_epoch" \
    --argjson window_start "$window_start" \
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

    # いまの 5h 枠に入るぶんの実測。枠の使用率と突き合わせて「1 日の目安」を出すのに使う。
    | ($rows | map(select(.ts != null and .ts >= $window_start))) as $recent_rows
    # 日別も today と同じ内訳で出す。表示側が任意の期間を合算できるようにするため、
    # 合計だけでなく input/output やコストも持たせる。
    | ( $rows
        | group_by(.date)
        | map(summarize(.) + { date: .[0].date })
        | sort_by(.date)
        | .[-$days:]
      ) as $daily

    # 直近のセッション = 最新の日付を持つ行の sessionId。
    | ( $rows | map(select(.session != null)) | sort_by(.date) | last | .session ) as $latest_session
    | ( $rows | map(select(.session != null and .session == $latest_session)) ) as $session_rows

    | { today: (summarize($today_rows) | if . == null then null else . + { date: $today } end),
        recent_5h: summarize($recent_rows),
        session: (summarize($session_rows) | if . == null then null else . + { id: $latest_session } end),
        daily: $daily }
  ' "$rows_file" 2>/dev/null || empty_usage
}

main "$@"
