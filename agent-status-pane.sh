#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_SCRIPT="${AGENT_STATUS_DAEMON_SCRIPT:-$SCRIPT_DIR/agent-status-daemon.sh}"
STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
STATE_FILE="${AGENT_STATUS_STATE_FILE:-$STATE_DIR/state.json}"
LOCK_DIR="${AGENT_STATUS_LOCK_DIR:-$STATE_DIR/daemon.lock}"
REFRESH_SECONDS="${AGENT_STATUS_PANE_REFRESH_SECONDS:-3}"
DAEMON_LOG="${AGENT_STATUS_DAEMON_LOG:-$STATE_DIR/daemon.log}"
BAR_WIDTH_SETTING="${AGENT_STATUS_BAR_WIDTH:-}"
SHOW_TOKENS="${AGENT_STATUS_SHOW_TOKENS:-1}"
BAR_WIDTH=16
SHOW_RESET=1
PANE_COLS=0
SLEEP_PID=""
LAST_RENDERED_STATE_HASH=""
TEST_MODE=0
TEST_COLS=0
NEED_REDRAW=1

BOLD=$'\033[1m'
DIM=$'\033[2m'

# Soft but readable 256-color palette
CYAN=$'\033[38;5;81m'    # cyan: 元色より少し柔らかい
GREEN=$'\033[38;5;77m'   # green: パステルより見やすい
AMBER=$'\033[38;5;220m'  # amber: 黄色すぎず警告感あり
RED=$'\033[38;5;203m'    # red: 強すぎない赤
MUTED=$'\033[38;5;245m'  # empty bar / subtle text

RESET=$'\033[0m'

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# マルチバイト文字の繰り返し。tr はバイト単位で動くため、`tr ' ' '█'` は
# 3 バイト文字の先頭 1 バイトだけを書き出して壊れる。
repeat_char() {
  local char="$1"
  local count="$2"
  local out="" i

  ((count > 0)) || return 0
  for ((i = 0; i < count; i++)); do
    out+="$char"
  done
  printf '%s' "$out"
}


# 端末幅。--test では再現性のため固定値を使えるようにする。
pane_cols() {
  if ((TEST_COLS > 0)); then
    printf '%s' "$TEST_COLS"
    return
  fi
  local cols
  cols="$(tput cols 2>/dev/null)"
  [[ "$cols" =~ ^[0-9]+$ ]] && ((cols > 0)) || cols=48
  printf '%s' "$cols"
}

# バー以外が使う桁数。名前(7) + 空白 + 枠(3) + 空白 + "[" + "]" + 空白 + 率(6)。
BAR_ROW_OVERHEAD=22
# リセット時刻 " 06/22 13:00" のぶん。
RESET_COLUMN_WIDTH=12

# バー幅は端末幅から決める。AGENT_STATUS_BAR_WIDTH の指定があればそれを優先するが、
# 数値でない値をそのまま使うと printf と算術式が落ちるため必ず検証する。
resolve_bar_width() {
  local cols="$1"
  local overhead=$BAR_ROW_OVERHEAD
  local width

  ((SHOW_RESET == 1)) && overhead=$((overhead + RESET_COLUMN_WIDTH))

  if [[ "$BAR_WIDTH_SETTING" =~ ^[1-9][0-9]*$ ]]; then
    width="$BAR_WIDTH_SETTING"
  else
    width=$((cols - overhead))
  fi

  ((width < 4)) && width=4
  # 指定値が広すぎても行を折り返させない。
  ((width > cols - overhead)) && width=$((cols - overhead))
  ((width < 4)) && width=4
  printf '%s' "$width"
}

# 表示幅に収める。ANSI を混ぜる前に切るので、色は長さに数えない。
truncate_to() {
  local text="$1"
  local limit="$2"

  ((limit > 0)) || limit=1
  if ((${#text} > limit)); then
    printf '%s' "${text:0:limit}"
  else
    printf '%s' "$text"
  fi
}

usage() {
  cat <<EOF
Usage:
  ./agent-status-pane.sh
  ./agent-status-pane.sh --test STATE_JSON

Options:
  --test STATE_JSON   Render the given state JSON once without starting daemon.
  --cols N            Render at a fixed terminal width (for tests).
  --help              Show this help.
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --test|--file|--state-file)
        if [[ -z "${2:-}" ]]; then
          printf '%s requires a file path\n' "$1" >&2
          exit 2
        fi
        STATE_FILE="$2"
        TEST_MODE=1
        shift 2
        ;;
      --cols)
        if [[ -z "${2:-}" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          printf -- '--cols requires a positive number\n' >&2
          exit 2
        fi
        TEST_COLS="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      -*)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        STATE_FILE="$1"
        TEST_MODE=1
        shift
        ;;
    esac
  done
}

daemon_lock_is_live() {
  local pid

  [[ -d "$LOCK_DIR" ]] || return 1

  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1

  kill -0 "$pid" 2>/dev/null
}

start_daemon_if_needed() {
  mkdir -p "$STATE_DIR" || return
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  if daemon_lock_is_live; then
    return
  fi

  if [[ ! -x "$DAEMON_SCRIPT" ]]; then
    chmod +x "$DAEMON_SCRIPT" 2>/dev/null || true
  fi

  umask 077
  nohup "$DAEMON_SCRIPT" >>"$DAEMON_LOG" 2>&1 &
}

ensure_daemon() {
  start_daemon_if_needed
}

fmt_reset() {
  local value="$1"

  if [[ -z "$value" || "$value" == "null" ]]; then
    printf -- '--:--'
    return
  fi

  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ JST$ ]]; then
    printf '%s' "$value" | cut -c 6-16 | tr '-' '/'
  else
    printf '%s' "$value"
  fi
}

ansi_for() {
  local pct="$1"
  local whole

  if [[ ! "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$RESET"
    return
  fi

  whole="${pct%%.*}"

  if ((whole >= 80)); then
    printf '%s' "$RED"
  elif ((whole >= 50)); then
    printf '%s' "$AMBER"
  else
    printf '%s' "$GREEN"
  fi
}

progress_filled() {
  local pct="$1"

  jq -nr \
    --arg pct "$pct" \
    --argjson width "$BAR_WIDTH" '
      ($pct | tonumber? // 0) as $p
      | (($p * $width / 100) | floor)
      | if . < 0 then 0 elif . > $width then $width else . end
    ' 2>/dev/null
}

progress_bar() {
  local pct="$1"
  local filled empty color

  if [[ -z "$pct" || "$pct" == "null" || ! "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$MUTED"
    repeat_char '░' "$BAR_WIDTH"
    printf '%s' "$RESET"
    return
  fi

  filled="$(progress_filled "$pct")"
  [[ "$filled" =~ ^[0-9]+$ ]] || filled=0

  (( filled < 0 )) && filled=0
  (( filled > BAR_WIDTH )) && filled="$BAR_WIDTH"

  empty=$((BAR_WIDTH - filled))
  color="$(ansi_for "$pct")"

  printf '%s' "$color"
  repeat_char '█' "$filled"
  printf '%s' "$MUTED"
  repeat_char '░' "$empty"
  printf '%s' "$RESET"
}

state_value() {
  local expr="$1"
  jq -r "$expr // empty" "$STATE_FILE" 2>/dev/null
}

# 枠は 5h/7d 固定ではない。primary / secondary を先頭にしつつ、
# 将来増える枠も取りこぼさず TSV で取り出す。
state_windows() {
  local agent="$1"

  jq -r --arg agent "$agent" '
    (.agents[$agent].windows // {})
    | to_entries
    | sort_by([
        (if .key == "primary" then 0
         elif .key == "secondary" then 1
         else 2 end),
        .key
      ])
    | .[]
    | [(.value.label // .key), (.value.used_pct // ""), (.value.reset_at // "")]
    | @tsv
  ' "$STATE_FILE" 2>/dev/null
}

state_hash() {
  local json

  json="$(jq -cS . "$STATE_FILE" 2>/dev/null)" || return 1

  if command_exists shasum; then
    printf '%s' "$json" | shasum | awk '{print $1}'
  elif command_exists sha256sum; then
    printf '%s' "$json" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$json" | cksum | awk '{print $1 ":" $2}'
  fi
}

error_row() {
  local name="$1"
  local status="$2"
  local message="$3"
  local label

  case "$status" in
    offline)     label="Offline" ;;
    parse_error) label="Parse Error" ;;
    error)       label="Error" ;;
    no_windows)  label="No Quota Windows" ;;
    "")          label="Unknown" ;;
    *)           label="$status" ;;
  esac

  [[ -n "$message" && "$message" != "null" ]] && label="$label: $message"

  # 40〜50 桁のペインを想定しているのに、daemon のメッセージは長くなりうる。
  # 折り返すと以降の行がずれるので、名前の分を除いた幅で切る。
  label="$(truncate_to "$label" $((PANE_COLS - 8)))"

  printf "%-7.7s ${RED}%s${RESET}" "$name" "$label"
}

row() {
  local name="$1"
  local window="$2"
  local pct="$3"
  local expires="$4"
  local color="$RESET"
  local pct_label="--.-%"

  if [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    color="$(ansi_for "$pct")"
    pct_label="$(printf '%4.1f%%' "$pct")"
  fi

  # ラベルは "5h" "7d" のほか "30m" のような 3 桁もありうる。
  printf "%-7.7s ${DIM}%-3.3s${RESET} [%s] %s%6s${RESET}" \
    "$name" \
    "$window" \
    "$(progress_bar "$pct")" \
    "$color" \
    "$pct_label"

  ((SHOW_RESET == 1)) && printf " ${DIM}%s${RESET}" "$(fmt_reset "$expires")"
  return 0
}

# 幅いっぱいの区切り線。見出しを渡すと "── tokens ────" の形にする。
rule() {
  local title="${1:-}"
  local width=$((PANE_COLS - 2))
  ((width < 4)) && width=4

  if [[ -z "$title" ]]; then
    repeat_char '─' "$width"
    return
  fi

  local head=2
  local tail=$((width - head - ${#title} - 2))
  ((tail < 0)) && tail=0
  repeat_char '─' "$head"
  printf ' %s ' "$title"
  repeat_char '─' "$tail"
}

# 1_234_567 → "1.2M"。桁が変わっても幅が動かないよう 4 文字前後に丸める。
fmt_tokens() {
  local n="$1"

  [[ "$n" =~ ^[0-9]+$ ]] || {
    printf -- '--'
    return
  }

  jq -nr --argjson n "$n" '
    if $n >= 1000000 then ($n / 1000000 * 10 | floor / 10 | tostring) + "M"
    elif $n >= 10000 then ($n / 1000 | floor | tostring) + "k"
    elif $n >= 1000 then ($n / 1000 * 10 | floor / 10 | tostring) + "k"
    else ($n | tostring)
    end'
}

# トークン行。集計はローカルのログ由来なので、利用枠の取得が失敗していても出す。
agent_token_lines() {
  local name="$1"
  local agent="$2"
  local rows first="$name"

  rows="$(jq -r --arg a "$agent" '
    .agents[$a].usage // empty
    | [ (.today  | select(. != null) | ["today",   (.total // 0), (.cost_usd // "")]),
        (.session| select(. != null) | ["session", (.total // 0), (.cost_usd // "")]) ]
    | .[] | @tsv
  ' "$STATE_FILE" 2>/dev/null)"

  [[ -n "$rows" ]] || return 0

  local label total cost line
  while IFS=$'\t' read -r label total cost; do
    [[ -n "$label" ]] || continue
    # 枠の行と数値の列を揃える: 名前(7) + 枠(3) + " [" + バー + "] "。
    line="$(printf "%-7.7s ${DIM}%-*.*s${RESET} %6s" \
      "$first" \
      "$((BAR_WIDTH + 6))" "$((BAR_WIDTH + 6))" "$label" \
      "$(fmt_tokens "$total")")"
    # ここまでで 名前(7) + 空白 + ラベル(BAR_WIDTH+6) + 空白 + 数値(6)。
    # 概算コスト "  ~$12.34" は 9 桁使うので、残り幅がある時だけ足す。
    if [[ -n "$cost" && "$cost" != "null" ]] \
      && ((PANE_COLS - (BAR_WIDTH + 21) >= 9)); then
      line+="$(printf "  ${DIM}~\$%.2f${RESET}" "$cost")"
    fi
    printf '%s\033[K\n' "$line"
    first=""
  done <<<"$rows"
}

# エージェント 1 つ分を描画する。エラー時と、枠が 1 つも無い時は 1 行にまとめる。
agent_block() {
  local name="$1"
  local agent="$2"
  local status message windows first="$name"

  status="$(state_value ".agents.$agent.status")"
  message="$(state_value ".agents.$agent.message")"

  if [[ "${status:-ok}" != "ok" ]]; then
    printf '%s\033[K\n' "$(error_row "$name" "$status" "$message")"
    return
  fi

  windows="$(state_windows "$agent")"
  if [[ -z "$windows" ]]; then
    printf '%s\033[K\n' "$(error_row "$name" "no_windows" "")"
    return
  fi

  local label pct expires
  while IFS=$'\t' read -r label pct expires; do
    printf '%s\033[K\n' "$(row "$first" "$label" "$pct" "$expires")"
    first=""
  done <<<"$windows"
}

clear_to_end() {
  printf '\033[J'
}

render_starting() {
  local log_tail=""

  if [[ -f "$DAEMON_LOG" ]]; then
    log_tail="$(tail -n 3 "$DAEMON_LOG" 2>/dev/null || true)"
  fi

  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET} ${DIM}· starting daemon...${RESET}\033[K\n"
  printf "${DIM}state: %s${RESET}\033[K\n" "$(truncate_to "$STATE_FILE" $((PANE_COLS - 7)))"

  if [[ -n "$log_tail" ]]; then
    printf "\033[K\n"
    printf "${DIM}daemon log:${RESET}\033[K\n"
    while IFS= read -r line; do
      printf "${RED}%s${RESET}\033[K\n" "$(truncate_to "$line" "$PANE_COLS")"
    done <<<"$log_tail"
  fi

  clear_to_end
}

render_dashboard() {
  local updated="$1"
  local updated_label="waiting"

  [[ -n "$updated" ]] && updated_label="$(fmt_reset "$updated")"

  printf '\033[H'
  printf "${BOLD}${CYAN} Agent Status${RESET}"
  # " Agent Status" が 13 桁、" · updated MM/DD HH:MM" が 23 桁。
  ((PANE_COLS >= 36)) && printf "  ${DIM}· updated %s${RESET}" "$updated_label"
  printf '\033[K\n'
  printf "${DIM} %s${RESET}\033[K\n" "$(rule)"

  agent_block "Claude" "claude"
  agent_block "Codex" "codex"

  if [[ "$SHOW_TOKENS" == "1" ]]; then
    local claude_tokens codex_tokens
    claude_tokens="$(agent_token_lines "Claude" "claude")"
    codex_tokens="$(agent_token_lines "Codex" "codex")"

    if [[ -n "$claude_tokens" || -n "$codex_tokens" ]]; then
      printf "${DIM} %s${RESET}\033[K\n" "$(rule "tokens")"
      [[ -n "$claude_tokens" ]] && printf '%s\n' "$claude_tokens"
      [[ -n "$codex_tokens" ]] && printf '%s\n' "$codex_tokens"
    fi
  fi

  clear_to_end
}

draw() {
  local updated current_hash

  PANE_COLS="$(pane_cols)"
  # 狭いペインではリセット時刻を落とす。バーを削るより先にこちらを削った方が
  # 「あとどれだけ使えるか」が読める。
  SHOW_RESET=1
  ((PANE_COLS < BAR_ROW_OVERHEAD + RESET_COLUMN_WIDTH + 8)) && SHOW_RESET=0
  BAR_WIDTH="$(resolve_bar_width "$PANE_COLS")"

  tput civis 2>/dev/null || true

  if ((TEST_MODE == 0)); then
    ensure_daemon
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    if ((TEST_MODE == 1)); then
      printf 'state file not found: %s\n' "$STATE_FILE" >&2
      return 1
    else
      render_starting
    fi
    return
  fi

  current_hash="$(state_hash)" || {
    printf '\033[H'
    printf "${BOLD}${CYAN} Agent Status${RESET} ${RED}· invalid state json${RESET}\033[K\n"
    printf "${DIM}state: %s${RESET}\033[K\n" "$STATE_FILE"
    clear_to_end
    return
  }

  # 端末幅もハッシュに混ぜる。state が変わるまで最大 60 秒あるため、
  # 幅の変化を見ないとリサイズ後の崩れがそのまま残る。
  current_hash="$current_hash:${PANE_COLS}"

  if ((NEED_REDRAW == 0)) && [[ -n "$current_hash" && "$current_hash" == "$LAST_RENDERED_STATE_HASH" ]]; then
    return
  fi

  NEED_REDRAW=0
  LAST_RENDERED_STATE_HASH="$current_hash"

  updated="$(state_value '.updated_at')"
  render_dashboard "$updated"
}

cleanup() {
  if [[ -n "${SLEEP_PID:-}" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi

  tput cnorm 2>/dev/null || true
}

stop_pane() {
  cleanup
  exit 0
}

sleep_for_refresh() {
  sleep "$REFRESH_SECONDS" &
  SLEEP_PID="$!"
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
}

main() {
  parse_args "$@"

  if ! command_exists jq; then
    printf 'agent-status-pane requires jq\n' >&2
    exit 1
  fi

  trap cleanup EXIT
  trap stop_pane INT TERM
  # リサイズは state の更新とは無関係に起きる。次の描画で必ず引き直す。
  trap 'NEED_REDRAW=1' WINCH

  if ((TEST_MODE == 1)); then
    draw
    exit $?
  fi

  while :; do
    draw
    sleep_for_refresh
  done
}

main "$@"
