# 設定と利用方法

## 基本起動

初回だけ設定ファイルを作ります。

```sh
./install.sh
```

インストーラは `agent-status.env` を作成し、Claude Code の既存 credentials と Codex app-server コマンドを確認します。以後、設定は `agent-status.env` に書きます。`agent-status-pane.sh` と `agent-status-daemon.sh` は起動時にこのファイルを自動で読み込みます。

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

狭いペインではバー幅を調整します。

```sh
AGENT_STATUS_BAR_WIDTH=12 ./agent-status-pane.sh
```

表示される更新時刻とリセット時刻は JST です。

## 共通設定

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `AGENT_STATUS_CONFIG_FILE` | `./agent-status.env` | 読み込む設定ファイル |
| `AGENT_STATUS_STATE_DIR` | `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status` | 状態ファイル、ロック、ログを置くディレクトリ |
| `AGENT_STATUS_STATE_FILE` | `$AGENT_STATUS_STATE_DIR/state.json` | Daemon と Viewer が共有する状態 JSON |
| `AGENT_STATUS_INTERVAL_SECONDS` | `60` | Daemon の取得間隔 |
| `AGENT_STATUS_PANE_REFRESH_SECONDS` | `3` | Viewer の再描画間隔 |
| `AGENT_STATUS_BAR_WIDTH` | `16` | プログレスバー幅 |
| `CODEX_APP_SERVER_COMMAND` | `codex app-server` | Codex の stdio JSON-RPC コマンド |
| `CODEX_APP_SERVER_WAIT_SECONDS` | `10` | Codex app-server からのレスポンス待機秒数 |

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

Daemon はその JSON から以下を読みます。

```text
rate_limits.five_hour.used_percentage
rate_limits.five_hour.resets_at
rate_limits.seven_day.used_percentage
rate_limits.seven_day.resets_at
context_window.remaining_percentage
cost.total_cost_usd
```

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
