# 仕様と内部設計

## アーキテクチャ

このツールは Daemon と Viewer を分離しています。

```text
agent-status-daemon.sh -> state.json -> agent-status-pane.sh
```

Daemon は Codex の取得と Claude statusLine JSON の統合を担当し、Viewer は状態 JSON の表示だけを担当します。API のレート制限回避と、ターミナル描画負荷の抑制が目的です。

## Daemon

`agent-status-daemon.sh` は既定で 60 秒ごとに以下を並列取得します。

- Claude Code: 5 時間枠、7 日枠、コンテキスト残量、コスト
- Codex: primary、secondary

各エージェントの取得は独立しており、1 つが失敗しても他の状態更新を継続します。

初回取得や前回状態も失敗していた場合は、`auth_error`、`offline`、`parse_error` などの status を状態 JSON に書きます。直前に成功した値がある場合は、その値を `stale` として保持し、`message` に今回の失敗理由を残します。

Daemon には操作用サブコマンドがあります。

```sh
./agent-status-daemon.sh --status
./agent-status-daemon.sh --start
./agent-status-daemon.sh --stop
./agent-status-daemon.sh --restart
```

## Viewer

`agent-status-pane.sh` は既定で 3 秒ごとに状態 JSON を読み、`tput` で画面を再描画します。

表示は 40 から 50 桁程度のペインを想定しています。

```text
AI Agent Quotas
================
Updated 06/21 15:30

Claude        20.0%
  5h [███░░░░░░░░░░░░░] 06/21 17:00
  7d [████░░░░░░░░░░░░] 06/24 00:00
```

取得失敗時はプログレスバーの代わりに `Auth Error`、`Offline`、`Parse Error` を表示します。直前の成功値を保持している `stale` 状態では、プログレスバーを表示したまま `stale` ラベルを付けます。

## 状態 JSON

既定パス:

```sh
${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json
```

`updated_at` と各 `reset_at` は表示しやすいよう JST 文字列で保存します。

例:

```json
{
  "updated_at": "2026-06-21T06:18:41Z",
  "agents": {
    "claude": {
      "agent": "claude",
      "label": "Claude Code",
      "status": "ok",
      "updated_at": "2026-06-21T06:18:41Z",
      "windows": {
        "primary": {
          "label": "5h",
          "used_pct": 20,
          "reset_at": "2026-06-21T08:00:00Z"
        },
        "secondary": {
          "label": "7d",
          "used_pct": 35,
          "reset_at": "2026-06-24T00:00:00Z"
        }
      }
    }
  }
}
```

`used_pct` は 0 から 100 のパーセント値です。`used_fraction` や `usage_ratio` のような比率フィールドが API 応答にある場合のみ 100 倍して正規化します。

## 権限とセキュリティ

- 状態ディレクトリは `700`、状態ファイルは `600` で作成します。
- 状態ファイルは一時ファイルに書き出してから `mv` するため、Viewer が途中書き込みの JSON を読む可能性を下げています。
- Bearer トークンは `curl -H` のコマンドライン引数に載せず、stdin の curl config として渡します。
- raw API 応答は既定では保存しません。
- `AGENT_STATUS_INCLUDE_RAW=1` はデバッグ用途に限定してください。

## ロック

Daemon は `$AGENT_STATUS_STATE_DIR/daemon.lock` ディレクトリを作って多重起動を防ぎます。ロック内には PID を保存し、Viewer はその PID が生存している場合だけ Daemon 起動済みと判断します。

## 依存コマンド

- `bash`
- `curl`
- `jq`
- `bc`
- `security`
- `tput`

`jq` と `bc` は Homebrew で入れる想定です。
