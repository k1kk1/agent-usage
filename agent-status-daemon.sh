#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${AGENT_STATUS_STATE_DIR:-${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status}"
STATE_FILE="${AGENT_STATUS_STATE_FILE:-$STATE_DIR/state.json}"
LOCK_DIR="${AGENT_STATUS_LOCK_DIR:-$STATE_DIR/daemon.lock}"
INTERVAL_SECONDS="${AGENT_STATUS_INTERVAL_SECONDS:-60}"

CLAUDE_STATUS_FILE="${CLAUDE_STATUS_FILE:-$STATE_DIR/claude-status.json}"

USAGE_COLLECTOR="${AGENT_USAGE_COLLECTOR:-$SCRIPT_DIR/usage-collector.sh}"
COLLECT_USAGE="${AGENT_USAGE_COLLECT:-1}"

CODEX_APP_SERVER_COMMAND="${CODEX_APP_SERVER_COMMAND:-codex app-server}"
# Codex app-server はstdinを即時に閉じると応答前に終了するため、
# JSON-RPC応答を待つための保持時間を設定する。
CODEX_APP_SERVER_WAIT_SECONDS="${CODEX_APP_SERVER_WAIT_SECONDS:-10}"
CODEX_RATE_LIMIT_METHOD="${CODEX_RATE_LIMIT_METHOD:-account/rateLimits/read}"
LOCK_OWNER_BASHPID=""

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prepare_state_dir() {
  mkdir -p "$STATE_DIR" || return 1
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

iso_now() {
  TZ=Asia/Tokyo date +"%Y-%m-%d %H:%M:%S JST"
}

json_error() {
  local agent="$1"
  local status="$2"
  local message="$3"
  jq -nc \
    --arg agent "$agent" \
    --arg status "$status" \
    --arg message "$message" \
    --arg updated_at "$(iso_now)" \
    '{agent:$agent,status:$status,message:$message,updated_at:$updated_at,windows:{}}'
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi

  local pid
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  rm -f "$LOCK_DIR/pid" 2>/dev/null || return 1
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

daemon_pid() {
  cat "$LOCK_DIR/pid" 2>/dev/null || true
}

daemon_is_live() {
  local pid
  pid="$(daemon_pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_daemon() {
  local pid
  pid="$(daemon_pid)"

  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || return 1
    local i
    for i in 1 2 3 4 5; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || break
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi

  if ! daemon_is_live; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

start_daemon_background() {
  prepare_state_dir || return 1
  if daemon_is_live; then
    printf 'agent-status-daemon is already running: %s\n' "$(daemon_pid)" >&2
    return 0
  fi

  stop_daemon
  umask 077
  nohup "$SCRIPT_DIR/agent-status-daemon.sh" >>"$STATE_DIR/daemon.log" 2>&1 &
  local i
  for i in 1 2 3 4 5; do
    sleep 1
    if daemon_is_live; then
      printf 'agent-status-daemon started: %s\n' "$(daemon_pid)"
      return 0
    fi
  done

  printf 'agent-status-daemon failed to start\n' >&2
  return 1
}

fetch_claude_usage() {
  local body
  if [[ ! -s "$CLAUDE_STATUS_FILE" ]]; then
    json_error "claude" "offline" "Claude statusLine JSON not found"
    return
  fi

  body="$(cat "$CLAUDE_STATUS_FILE" 2>/dev/null)" || {
    json_error "claude" "offline" "Claude statusLine JSON could not be read"
    return
  }

  jq -c --arg updated_at "$(iso_now)" '
    def pct(v):
      if v == null then null
      elif (v|type) == "number" then v
      else null end;
    def reset(v):
      if v == null then null
      elif (v|type) == "number" then ((v + 32400) | strftime("%Y-%m-%d %H:%M:%S JST"))
      else v end;
    {
      agent:"claude",
      label:"Claude Code",
      status:"ok",
      updated_at:$updated_at,
      windows:{
        primary:{
          label:"5h",
          used_pct:pct(.rate_limits.five_hour.used_percentage),
          reset_at:reset(.rate_limits.five_hour.resets_at)
        },
        secondary:{
          label:"7d",
          used_pct:pct(.rate_limits.seven_day.used_percentage),
          reset_at:reset(.rate_limits.seven_day.resets_at)
        }
      },
      context:{
        remaining_pct:pct(.context_window.remaining_percentage),
        used_pct:pct(.context_window.used_percentage)
      },
      cost:{
        total_usd:(.cost.total_cost_usd // null)
      }
    }
  ' <<<"$body" 2>/dev/null || json_error "claude" "parse_error" "Claude usage response was not understood"
}

fetch_codex_usage() {
  local init_request rate_limit_request output response
  if ! [[ "$CODEX_APP_SERVER_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    CODEX_APP_SERVER_WAIT_SECONDS=10
  fi
  init_request="$(jq -nc '{jsonrpc:"2.0",id:1,method:"initialize",params:{clientInfo:{name:"agent-usage",version:"1.0"}}}')"
  rate_limit_request="$(jq -nc --arg method "$CODEX_RATE_LIMIT_METHOD" \
    '{jsonrpc:"2.0",id:2,method:$method,params:{}}')"

  # app-server が応答を返すまで stdin を開いておく。
  output="$(
    {
      printf '%s\n' "$init_request"
      printf '%s\n' "$rate_limit_request"
      sleep "$CODEX_APP_SERVER_WAIT_SECONDS"
    } | bash -lc "$CODEX_APP_SERVER_COMMAND" 2>/dev/null
  )" || {
    json_error "codex" "offline" "codex app-server request failed"
    return
  }

  response="$(jq -c 'select(.id == 2) | . ' <<<"$output" 2>/dev/null | tail -n 1)"
  if [[ -z "$response" ]]; then
    json_error "codex" "parse_error" "Codex rate-limit response was not found"
    return
  fi

  jq -c --arg updated_at "$(iso_now)" '
    def pct(v):
      if v == null then null
      elif (v|type) == "number" then v
      else null end;
    def ratio(v):
      if v == null then null
      elif (v|type) == "number" then (v * 100)
      else null end;
    def epoch_or_text(v):
      if v == null then null
      elif (v|type) == "number" then ((v + 32400) | strftime("%Y-%m-%d %H:%M:%S JST"))
      else v end;
    # Codex の枠は 5h/7d 固定ではない。windowDurationMins から実際のラベルを作る。
    def window_label(mins):
      if mins == null then null
      elif (mins|type) != "number" then null
      elif mins < 60 then "\(mins)m"
      elif mins < 1440 then "\((mins / 60) | floor)h"
      else "\((mins / 1440) | floor)d" end;
    # 返ってこない枠（secondary が null など）は windows に載せない。
    def window(w; fallback_label):
      if w == null then null
      else {
        label:(window_label(w.windowDurationMins // w.window_duration_mins) // fallback_label),
        window_minutes:(w.windowDurationMins // w.window_duration_mins),
        used_pct:(pct(w.used_percentage // w.usage_percentage // w.percent_used // w.used_pct // w.usedPercent) // ratio(w.used_fraction // w.usage_ratio)),
        reset_at:epoch_or_text(w.reset_at // w.resets_at // w.resetsAt // w.reset_time // w.resetAt)
      } end;
    (.result.rateLimits // .result) as $r
    | {
      agent:"codex",
      label:"Codex",
      status:(if .error then "error" else "ok" end),
      message:(.error.message // null),
      updated_at:$updated_at,
      windows:({
        primary:window($r.primary; "5h"),
        secondary:window($r.secondary; "7d")
      } | with_entries(select(.value != null)))
    }
  ' <<<"$response" 2>/dev/null || json_error "codex" "parse_error" "Codex rate-limit response was not understood"
}

# トークン集計は失敗しても利用枠の表示を止めない。読めなければ空を返す。
fetch_token_usage() {
  local agent="$1"

  if [[ "$COLLECT_USAGE" != "1" || ! -r "$USAGE_COLLECTOR" ]]; then
    printf 'null'
    return
  fi

  local out
  out="$(bash "$USAGE_COLLECTOR" "$agent" 2>/dev/null)" || {
    printf 'null'
    return
  }

  if jq -e . >/dev/null 2>&1 <<<"$out"; then
    printf '%s' "$out"
  else
    printf 'null'
  fi
}

write_state() {
  local claude="$1"
  local codex="$2"
  local claude_usage="${3:-null}"
  local codex_usage="${4:-null}"
  local tmp_file state_parent previous='{}'
  state_parent="$(dirname "$STATE_FILE")"
  mkdir -p "$state_parent" || return 1
  chmod 700 "$state_parent" 2>/dev/null || true
  tmp_file="$(mktemp "$state_parent/state.XXXXXX")" || return 1
  chmod 600 "$tmp_file" 2>/dev/null || true

  if [[ -s "$STATE_FILE" ]]; then
    previous="$(jq -c . "$STATE_FILE" 2>/dev/null || printf '{}')"
  fi

  if jq -n \
    --arg updated_at "$(iso_now)" \
    --argjson previous "$previous" \
    --argjson claude "$claude" \
    --argjson codex "$codex" \
    --argjson claude_usage "$claude_usage" \
    --argjson codex_usage "$codex_usage" \
    '
      def previous_agent($key): $previous.agents[$key] // {};
      # 集計できなかった時は前回値を残す。ログ読み取りの一時的な失敗で
      # 表示が消えると、利用枠側より不安定に見えてしまう。
      def merge_usage($current; $old):
        if $current == null then ($old.usage // null) else $current end;
      def merge_agent($current; $old):
        if $current.status == "ok" then
          $current + {
            last_success_at: $current.updated_at,
            last_success_windows: $current.windows
          }
        else
          $current + {
            last_success_at: ($old.last_success_at // (if $old.status == "ok" then $old.updated_at else null end)),
            last_success_windows: ($old.last_success_windows // (if $old.status == "ok" then $old.windows else {} end))
          }
        end;
      {
        schema_version: 2,
        updated_at: $updated_at,
        agents: {
          claude: (merge_agent($claude; previous_agent("claude"))
            + { usage: merge_usage($claude_usage; previous_agent("claude")) }),
          codex: (merge_agent($codex; previous_agent("codex"))
            + { usage: merge_usage($codex_usage; previous_agent("codex")) })
        }
      }
    ' >"$tmp_file" && mv "$tmp_file" "$STATE_FILE"; then
    chmod 600 "$STATE_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file"
    return 1
  fi
}

collect_once() {
  local tmp_dir claude_file codex_file claude_usage_file codex_usage_file
  local claude codex claude_usage codex_usage

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-status.XXXXXX")" || return 1
  claude_file="$tmp_dir/claude.json"
  codex_file="$tmp_dir/codex.json"

  claude_usage_file="$tmp_dir/claude-usage.json"
  codex_usage_file="$tmp_dir/codex-usage.json"

  fetch_claude_usage >"$claude_file" &
  fetch_codex_usage >"$codex_file" &
  fetch_token_usage claude >"$claude_usage_file" &
  fetch_token_usage codex >"$codex_usage_file" &
  wait

  claude="$(cat "$claude_file" 2>/dev/null || json_error "claude" "error" "No Claude state")"
  codex="$(cat "$codex_file" 2>/dev/null || json_error "codex" "error" "No Codex state")"
  claude_usage="$(cat "$claude_usage_file" 2>/dev/null)"
  codex_usage="$(cat "$codex_usage_file" 2>/dev/null)"
  [[ -n "$claude_usage" ]] || claude_usage=null
  [[ -n "$codex_usage" ]] || codex_usage=null

  if ! write_state "$claude" "$codex" "$claude_usage" "$codex_usage"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
}

main() {
  local started_at elapsed remaining
  if ! command_exists jq; then
    printf 'agent-status-daemon requires jq\n' >&2
    exit 1
  fi

  if ! [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    INTERVAL_SECONDS=60
  fi

  umask 077

  prepare_state_dir || {
    printf 'failed to prepare state directory: %s\n' "$STATE_DIR" >&2
    exit 1
  }

  case "${1:-}" in
    --status)
      if daemon_is_live; then
        printf 'agent-status-daemon running: %s\n' "$(daemon_pid)"
      else
        printf 'agent-status-daemon stopped\n'
      fi
      exit 0
      ;;
    --stop)
      stop_daemon
      printf 'agent-status-daemon stopped\n'
      exit 0
      ;;
    --start)
      start_daemon_background
      exit $?
      ;;
    --restart)
      stop_daemon
      start_daemon_background
      exit $?
      ;;
  esac

  if ! acquire_lock; then
    printf 'agent-status-daemon is already running\n' >&2
    exit 0
  fi
  # TERM/INT でロックだけ消してループを継続すると多重起動する。
  # 終了時にだけロックを掃除し、シグナルでは必ず exit する。
  cleanup_lock() {
    # collect_once内のバックグラウンド子プロセスにもEXIT trapが継承される。
    # ロックを取得した親だけが消せるようにする。
    [[ "$BASHPID" == "$LOCK_OWNER_BASHPID" ]] || return
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  }
  LOCK_OWNER_BASHPID="$BASHPID"
  trap cleanup_lock EXIT
  trap 'exit 0' INT TERM

  if [[ "${1:-}" == "--once" ]]; then
    collect_once
    exit 0
  fi

  while :; do
    started_at="$SECONDS"
    collect_once
    elapsed=$((SECONDS - started_at))
    remaining=$((INTERVAL_SECONDS - elapsed))
    if ((remaining > 0)); then
      sleep "$remaining"
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
