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

Codex の枠は 5h/7d 固定ではありません。応答の `windowDurationMins` からラベルを算出し、`60` 分未満なら `30m`、`1440` 分未満なら `5h`、それ以上なら `7d` のような形にします。応答に無い枠（`secondary` が `null` など）は `windows` に載せません。

各エージェントの取得は独立しており、1 つが失敗しても他の状態更新を継続します。

取得に失敗したエージェントは `offline`、`parse_error` などの status を状態 JSON に書きます。直前の成功値は保持せず、現在の取得結果だけを表示します。

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

行は状態 JSON の `windows` にある枠だけを、その `label` で描きます。枠が 1 つしか無いエージェントは 1 行になります。

```text
Agent Status  · updated 06/21 15:30
 ─────────────────────────────────────────
Claude  5h  [███░░░░░░░░░░░░░]  20.0% 06/21 17:00
        7d  [████░░░░░░░░░░░░]  35.0% 06/24 09:00
Codex   7d  [██████░░░░░░░░░░]  40.0% 06/27 09:00
```

取得失敗時はプログレスバーの代わりに `Offline`、`Parse Error` などの status を表示します。

## 状態 JSON

既定パス:

```sh
${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json
```

`updated_at` と各 `reset_at` は表示しやすいよう JST 文字列で保存します。`schema_version` は
状態ファイルの後方互換性を判定するための整数です。取得に失敗したエージェントには、直前の
成功時の枠を `last_success_windows` として残します。

例:

```json
{
  "schema_version": 1,
  "updated_at": "2026-06-21 15:18:41 JST",
  "agents": {
    "claude": {
      "agent": "claude",
      "label": "Claude Code",
      "status": "ok",
      "updated_at": "2026-06-21 15:18:41 JST",
      "windows": {
        "primary": {
          "label": "5h",
          "used_pct": 20,
          "reset_at": "2026-06-21 17:00:00 JST"
        },
        "secondary": {
          "label": "7d",
          "used_pct": 35,
          "reset_at": "2026-06-24 09:00:00 JST"
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
- Claude Code は statusLine JSON を読み、OAuth token や非公開 usage API へ直接アクセスしません。

## ロック

Daemon は `$AGENT_STATUS_STATE_DIR/daemon.lock` ディレクトリを作って多重起動を防ぎます。ロック内には PID を保存し、Viewer はその PID が生存している場合だけ Daemon 起動済みと判断します。

## 依存コマンド

- `bash`
- `jq`
- `tput`

`jq` は Homebrew で入れる想定です。
