# 設定と利用方法

## 基本起動

Viewer を起動すると、Daemon が未起動の場合は自動でバックグラウンド起動します。

```sh
./agent-status-pane.sh
```

表示だけを確認したい場合は、テスト用の state JSON を渡すと Daemon を起動せず 1 回だけ描画します。

```sh
./agent-status-pane.sh --test ./path/to/state.json
```

利用率は 50% 未満が緑、50% 以上が黄、80% 以上が赤で表示されます。サンプル state で確認できます。

```sh
./agent-status-pane.sh --test sample/state-low.json
./agent-status-pane.sh --test sample/state-medium.json
./agent-status-pane.sh --test sample/state-high.json
```

Daemon だけを 1 回実行して状態 JSON を作る場合:

```sh
./agent-status-daemon.sh --once
```

Daemon を操作する場合:

```sh
./agent-status-daemon.sh --status
./agent-status-daemon.sh --restart
./agent-status-daemon.sh --stop
./agent-status-daemon.sh --start
```

設定やスクリプトを変更したあと cmux の表示を更新したい場合は、通常 `--restart` だけで十分です。

## tmux / cmux

tmux の右側に 48 桁のペインを作る例:

```sh
tmux split-window -h -l 48 './agent-status-pane.sh'
```

バー幅は端末幅から自動で決まります。明示したい場合だけ指定します。

```sh
AGENT_STATUS_BAR_WIDTH=12 ./agent-status-pane.sh
```

26 桁がこのレイアウトの下限です。これより狭いと行が収まりません。狭いペインでは
リセット時刻が先に省かれます。

表示を固定幅で確認したいときは `--cols` を使います。

```sh
./agent-status-pane.sh --test sample/state-low.json --cols 34
```

表示される更新時刻とリセット時刻は JST です。

## 共通設定

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `AGENT_STATUS_STATE_DIR` | `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status` | 状態ファイル、ロック、ログを置くディレクトリ |
| `AGENT_STATUS_STATE_FILE` | `$AGENT_STATUS_STATE_DIR/state.json` | Daemon と Viewer が共有する状態 JSON |
| `AGENT_STATUS_INTERVAL_SECONDS` | `60` | Daemon の取得間隔 |
| `AGENT_STATUS_PANE_REFRESH_SECONDS` | `3` | Viewer の再描画間隔 |
| `AGENT_STATUS_BAR_WIDTH` | 端末幅から自動 | プログレスバー幅。数値でない値と、行が折り返す値は無視します |
| `AGENT_STATUS_SHOW_TOKENS` | `1` | `0` でペインのトークン行を消します |
| `CODEX_APP_SERVER_COMMAND` | `codex app-server` | Codex の stdio JSON-RPC コマンド |
| `CODEX_APP_SERVER_WAIT_SECONDS` | `10` | Codex app-server からのレスポンス待機秒数 |

## トークン集計

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `AGENT_USAGE_COLLECT` | `1` | `0` で集計を止めます。利用枠の表示だけ残ります |
| `AGENT_USAGE_COLLECTOR` | `<repo>/usage-collector.sh` | 集計スクリプトのパス |
| `AGENT_USAGE_PRICING_FILE` | `<repo>/pricing.json` | モデル単価表 |
| `AGENT_USAGE_CACHE_FILE` | `$AGENT_STATUS_STATE_DIR/usage-cache.json` | ファイル単位の集計キャッシュ |
| `AGENT_USAGE_DAILY_DAYS` | `7` | 日別推移として残す日数 |
| `CLAUDE_PROJECTS_DIR` | `$HOME/.claude/projects` | Claude Code の transcript 置き場 |
| `CODEX_SESSIONS_DIR` | `$HOME/.codex/sessions` | Codex の rollout ログ置き場 |

集計だけを単体で実行できます。

```sh
./usage-collector.sh claude
./usage-collector.sh codex
```

単価を変えたい場合は `pricing.json` をコピーして差し替えます。

```sh
AGENT_USAGE_PRICING_FILE=~/my-pricing.json ./agent-status-daemon.sh --once
```

キャッシュはファイルの `(size, mtime, inode)` で判定します。集計結果が合わないときは
キャッシュを消すと全ファイルを読み直します。

```sh
rm "$HOME/.cache/agent-status/usage-cache.json"
```

## Claude Code

Claude Code は API を直接叩かず、statusLine が外部コマンドに渡す JSON を読みます。これにより OAuth token や非公開 usage API への直接リクエストを避けます。

Claude Code の設定ファイルに statusLine コマンドを追加してください。

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/kikki/src/agent-usage/claude-status-line.sh",
    "refreshInterval": 5
  }
}
```

`claude-status-line.sh` は Claude Code から受け取った JSON を以下に保存します。

```sh
${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/claude-status.json
```

同時に、モデル、作業ディレクトリ、git ブランチ、セッションコスト、およびコンテキスト・5h・7d 使用率を色付きの2行 statusline として出力します。利用率は 50% 未満が緑、50% 以上が黄、80% 以上が赤です。バー幅は `CLAUDE_STATUS_BAR_WIDTH`（既定 `8`、最大 `24`）で変更できます。

Daemon はその JSON から以下を読みます。

```text
rate_limits.five_hour.used_percentage
rate_limits.five_hour.resets_at
rate_limits.seven_day.used_percentage
rate_limits.seven_day.resets_at
context_window.remaining_percentage
cost.total_cost_usd
```

これは statusLine JSON 側のキー名です。state.json へは `cost.total_usd` として書き出します。

## Codex

Codex は `codex app-server` を stdio JSON-RPC として起動し、`initialize` のあと `account/rateLimits/read` を送ります。

```sh
CODEX_APP_SERVER_COMMAND='codex app-server'
CODEX_APP_SERVER_WAIT_SECONDS=10
```

内部的には次のような JSON-RPC を送ります。

```sh
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-usage","version":"1.0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
  sleep 10
} | codex app-server
```

送信する JSON-RPC メソッド:

```text
account/rateLimits/read
```

メソッド名を差し替える場合:

```sh
CODEX_RATE_LIMIT_METHOD=account/rateLimits/read
```

Daemon は Claude Code の OAuth token を直接扱いません。
