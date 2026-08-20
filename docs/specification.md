# 仕様と内部設計

## アーキテクチャ

このツールは Daemon と Viewer を分離しています。

```text
agent-status-daemon.sh ──> state.json ──┬─> agent-status-pane.sh
  └─ usage-collector.sh                 └─> AgentUsage.app ─> Widget
```

Daemon は Codex の取得、Claude statusLine JSON の統合、トークンの集計を担当し、Viewer は状態 JSON の表示だけを担当します。API のレート制限回避と、ターミナル描画負荷の抑制が目的です。

Viewer は tmux/cmux ペイン版（`agent-status-pane.sh`）と macOS アプリ版（`macos/AgentUsage`）の 2 系統がありますが、どちらも state.json だけを入力とします。

## Daemon

`agent-status-daemon.sh` は既定で 60 秒ごとに以下を並列取得します。

- Claude Code: 5 時間枠、7 日枠、コンテキスト残量、コスト
- Codex: primary、secondary
- 両エージェントのトークン利用数（`usage-collector.sh`）

Codex の枠は 5h/7d 固定ではありません。応答の `windowDurationMins` からラベルを算出し、`60` 分未満なら `30m`、`1440` 分未満なら `5h`、それ以上なら `7d` のような形にします。応答に無い枠（`secondary` が `null` など）は `windows` に載せません。

各エージェントの取得は独立しており、1 つが失敗しても他の状態更新を継続します。

取得に失敗したエージェントは `offline`、`parse_error` などの status を状態 JSON に書き、直前の成功時の枠を `last_success_windows` に残します。Viewer はこれを薄く表示して、値が消えるのではなく古い値だと分かるようにします。

## トークン集計

利用枠の割合は API から取れますが、トークンの実数は Claude Code も Codex も API では返しません。どちらもローカルのセッションログには残しているため、`usage-collector.sh` がそこから集計します。

| エージェント | 読むファイル | 読む場所 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | `type: "assistant"` 行の `message.usage` |
| Codex | `~/.codex/sessions/**/*.jsonl` | `token_count` イベントの `last_token_usage`（1 回の API 呼び出しぶん） |

集計時の注意点:

- Claude は同じ API 応答が複数行に現れることがあり、resume でセッションを引き継ぐと前のやり取りが新しいファイルへ複製されます。`message.id` + `requestId` で重複を除きます。
- Claude の `timestamp` は UTC の ISO8601 でミリ秒付きです。jq の `fromdateiso8601` は小数秒を受け付けないため、落としてから変換します。
- Codex は `token_count` イベントごとの `last_token_usage`（その 1 回ぶん）を 1 行として扱います。累計の `total_token_usage` と足し合わせが一致することは確認済みで、1 回ごとに時刻が付くため、日付をまたぐセッションでも正しい日に振り分けられます。`last_token_usage` を持たない版のログでは、従来どおり累計の最後の値を採ります。
- Codex のログは版によって `ordinal` を持ちません。行の識別子には並び順を使います（`ordinal` を当てにすると、無い版で全行が同じキーになり重複除去に飲まれます）。
- 日付は state.json の他の時刻表記と揃えて JST 境界で切ります。

ログは追記のみで、終了したセッションのファイルは変わりません。`(size, mtime, inode)` をキーにファイル単位でキャッシュ（`usage-cache.json`）し、変化したものだけ読み直します。60 秒周期の収集でログが育っても走査量が増えません。

コストはキャッシュの読み書きが支配的なため、入力単価に対して read を 0.1 倍、write を TTL 5 分で 1.25 倍・1 時間で 2 倍に重み付けします。単価は `pricing.json` に切り出してあり、`AGENT_USAGE_PRICING_FILE` で差し替えられます。Codex は ChatGPT プランに含まれ単価を持たないため、トークン数のみ集計します。

Claude Code のセッションコストは statusLine が渡す実測値（`cost.total_usd`）が権威です。集計側の `cost_usd` は日次の概算用で、表示では `~$4.31` のように概算であることを示します。

Daemon には操作用サブコマンドがあります。

```sh
./agent-status-daemon.sh --status
./agent-status-daemon.sh --start
./agent-status-daemon.sh --stop
./agent-status-daemon.sh --restart
```

## Viewer

`agent-status-pane.sh` は既定で 3 秒ごとに状態 JSON を読み、`tput` で画面を再描画します。

行は状態 JSON の `windows` にある枠だけを、その `label` で描きます。枠が 1 つしか無いエージェントは 1 行になります。

```text
 Agent Status  · updated 06/21 15:30
 ──────────────────────────────────────────────
Claude  5h  [███░░░░░░░░░░░]  20.0% 06/21 17:00
        7d  [████░░░░░░░░░░]  35.0% 06/24 09:00
Codex   7d  [██████░░░░░░░░]  40.0% 06/27 09:00
 ── tokens ────────────────────────────────────
Claude  today                  1.2M  ~$4.31
        session                753k  ~$0.62
Codex   today                  210k
```

取得失敗時はプログレスバーの代わりに `Offline`、`Parse Error` などの status を表示します。メッセージは幅に収まるよう切り詰めます。

### 幅への追従

バー幅は端末幅（`tput cols`）から決まります。`AGENT_STATUS_BAR_WIDTH` を指定した場合はそちらを優先しますが、行が折り返さないよう上限で丸めます。数値でない値は無視します。

狭いペインではリセット時刻を先に落とします。バーを削るより「あとどれだけ使えるか」が残る方が読めるためです。このレイアウトの下限は 26 桁です。

再描画の判定には状態のハッシュに端末幅を混ぜ、`SIGWINCH` でも引き直します。状態のハッシュだけを見ていると、リサイズ後に次の更新まで最大 60 秒崩れたままになります。

`AGENT_STATUS_SHOW_TOKENS=0` でトークン行を消せます。

### 描画上の注意

バーの塗りつぶしに `tr` を使ってはいけません。`tr` はバイト単位で動くため、`tr ' ' '█'` は 3 バイト文字の先頭 1 バイトだけを書き出して壊れます。`repeat_char` を使います。

## 状態 JSON

既定パス:

```sh
${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json
```

`updated_at` と各 `reset_at` は表示しやすいよう JST 文字列で保存します。`schema_version` は
状態ファイルの後方互換性を判定するための整数で、現在は `2`（`usage` の追加）です。取得に
失敗したエージェントには、直前の成功時の枠を `last_success_windows` として残します。

例:

```json
{
  "schema_version": 2,
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
      },
      "context": { "remaining_pct": 69, "used_pct": 31 },
      "cost": { "total_usd": 1.23 },
      "usage": {
        "today": {
          "date": "2026-06-21",
          "input": 1240,
          "output": 24800,
          "cache_write": 148800,
          "cache_read": 1065160,
          "total": 1240000,
          "cost_usd": 4.31
        },
        "session": {
          "id": "4d862133-6d81-5a63-a111-2fef5ee79ca3",
          "input": 753,
          "output": 15061,
          "cache_write": 90369,
          "cache_read": 646897,
          "total": 753082,
          "cost_usd": 0.62
        },
        "daily": [
          {
            "date": "2026-06-20",
            "input": 1020,
            "output": 20400,
            "cache_write": 122400,
            "cache_read": 876180,
            "total": 1020000,
            "cost_usd": 3.57
          },
          {
            "date": "2026-06-21",
            "input": 1240,
            "output": 24800,
            "cache_write": 148800,
            "cache_read": 1065160,
            "total": 1240000,
            "cost_usd": 4.31
          }
        ]
      }
    }
  }
}
```

`used_pct` は 0 から 100 のパーセント値です。`used_fraction` や `usage_ratio` のような比率フィールドが API 応答にある場合のみ 100 倍して正規化します。

`usage` は集計できなかった場合 `null` になります。集計だけが失敗した回は直前の値を残すため、利用枠の失敗でトークン表示が消えることはありません（逆も同じです）。

`usage.recent_5h` は、いまの 5h 枠に入るぶんの実測です。枠の開始時刻は state.json の
`reset_at` から 5 時間引いて求めます（前回周期の値を読むことになりますが、5h 枠のリセット時刻は
5 時間に一度しか変わらないため問題になりません）。macOS アプリはこれと枠の使用率から
「5h 枠 1 本ぶんのトークン量」を見積もり、日別グラフの基準線に使います。Codex は 5h 枠を返さないため `null` で、アプリ側は 7d 枠と直近 7 日の合計から日割りで見積もります。

`usage.daily` は既定で直近 31 日分で、`today` と同じ内訳を日ごとに持ちます。「直近 N 日」や「更新日から N 日ごと」といった集計期間は契約側の都合で決まり、表示先ごとに変わることもあるため、daemon は日別までを出し、期間の合算は表示側（macOS アプリの `TokenPeriod`）が行います。日数は `AGENT_USAGE_DAILY_DAYS` で変えられます。

### キー名の整合

state.json は pane（シェル）と macOS アプリ（Swift）の両方が読みます。片側だけキー名を変えると値が黙って `nil` になり、UI からは「単に表示されない」としか見えません。実際に `cost` がこの状態でした。

`tests/test-schema-keys.sh` が daemon の出力キーと `UsageState.swift` の `CodingKeys` を突き合わせます。snake_case のキーは Swift のプロパティ名にできないため、必ず `CodingKeys` の生値として現れます。プロパティ名での一致を許すと生値が誤っていても通ってしまうので、生値だけを見ます。

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

テストのうち表示幅の検証だけ `python3` を使います。ロケールによっては `awk` の `length` が
バイト数を返し、マルチバイト文字を含む行を正しく数えられないためです。`python3` が無い環境
ではその検証を飛ばします。
