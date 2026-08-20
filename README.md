# Agent Usage Pane

Claude Code と Codex の利用枠を cmux/tmux の細いペインに表示するモニターです。

## まず使う

```sh
brew install jq
./agent-status-pane.sh
```

`agent-status-pane.sh` を起動すれば、裏側の Daemon も自動で起動します。

## macOS アプリとウィジェット

通常の macOS アプリ、メニューバー表示、WidgetKit 拡張のソースは [macos/AgentUsage](macos/AgentUsage) にあります。アプリは Dock から起動でき、メニューバーにはエージェントごとにアイコンと `33%` のような使用率を並べて表示します。クリックすると全利用枠を確認でき、外側をクリックすると閉じます。WidgetKit 拡張はデスクトップの小・中・大ウィジェットに対応します。

```sh
brew install xcodegen
cd macos/AgentUsage
./install.sh
```

インストール後、デスクトップで「ウィジェットを編集」を開き、`Agent Usage` を追加してください。

うまく表示されないときは、まず状態ファイルを確認します。

```sh
jq . "$HOME/.cache/agent-status/state.json"
```

設定やスクリプトを変更したあと daemon を入れ替える場合:

```sh
./agent-status-daemon.sh --restart
```

アプリとウィジェットだけを使う場合は、daemon をログイン中に単一起動する LaunchAgent も登録できます。

```sh
bash macos/AgentUsage/install-daemon-launch-agent.sh
```

解除する場合は `bash macos/AgentUsage/install-daemon-launch-agent.sh --uninstall` を実行します。

## 設定

通常は設定不要です。必要な場合だけ環境変数で上書きします。

```sh
AGENT_STATUS_BAR_WIDTH=12 ./agent-status-pane.sh
```

Codex はデフォルトで `codex app-server` を使うので、通常は設定不要です。

Claude Code は statusLine から渡される JSON を読みます。Claude Code の設定に次を追加してください。

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/agent-usage/claude-status-line.sh",
    "refreshInterval": 5
  }
}
```

`command` は絶対パスで書いてください（`~` は展開されません）。

## テスト表示

テスト用の state JSON を渡すと、Daemon を起動せず 1 回だけ描画できます。

```sh
./agent-status-pane.sh --test ./path/to/state.json
```

利用率ごとの色を確認するサンプル:

```sh
./agent-status-pane.sh --test sample/state-low.json
./agent-status-pane.sh --test sample/state-medium.json
./agent-status-pane.sh --test sample/state-high.json
```

## cmux で起動する

cmux のペインではこれだけ起動してください。

```sh
cd /path/to/agent-usage
./agent-status-pane.sh
```

tmux なら例として:

```sh
tmux split-window -h -l 48 'cd /path/to/agent-usage && ./agent-status-pane.sh'
```

## ファイル構成

- `agent-status-daemon.sh`: API を取得して状態 JSON を作る常駐プロセス。
- `agent-status-pane.sh`: 状態 JSON を表示するペイン用 UI。
- `usage-collector.sh`: セッションログからトークン利用数を集計する。
- `pricing.json`: コスト概算に使うモデル単価表。
- `macos/AgentUsage/`: macOS メニューバーアプリと WidgetKit 拡張。
- `claude-status-line.sh`: Claude Code の statusLine から受け取った JSON を保存するスクリプト。
- `sample/state-*.json`: 表示テスト用の状態 JSON。
- `tests/`: シェル側のテスト。`bash tests/run.sh` で実行。

状態ファイルは既定で `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json` に作られます。

## 仕組み

```
pane 起動
  └─ daemon を自動起動（多重起動は PID チェックで防止）
       └─ 60 秒ごとに収集
            ├─ Claude 使用量を並列取得
            ├─ Codex 使用量を並列取得
            └─ トークン利用数を並列集計（変化したログだけ読み直す）
                 └─ state.json にアトミック書き込み（tmp → mv）

pane
  └─ 3 秒ごとにstate.jsonのハッシュだけを確認し、変化時だけ描画
```

### Claude 使用量の取得

`claude-status-line.sh` が Claude Code の statusLine フックから受け取った JSON を `claude-status.json` に保存しています。daemon はこのファイルを jq でパースして 5h/7d の利用率を取り出します。

statusline 自体にも、モデル、ディレクトリ、git ブランチ、セッションコストと、コンテキスト・5h・7d の使用率バーを2行で表示します。バー幅は `CLAUDE_STATUS_BAR_WIDTH`（既定 `8`）で変更できます。

statusLine の仕様: https://code.claude.com/docs/ja/statusline

### Codex 使用量の取得

`codex app-server` プロセスに JSON-RPC で `account/rateLimits/read` を送り、レスポンスから利用率を取り出します。

### トークン利用数の集計

利用枠の割合は API から取れますが、トークンの実数はどちらのエージェントも API では返しません。`usage-collector.sh` がローカルのセッションログ（Claude は `~/.claude/projects`、Codex は `~/.codex/sessions`）を読み、今日ぶん・現在のセッションぶん・直近 31 日の日別内訳を集計します。「直近 N 日」や「更新日から N 日ごと」といった集計期間は契約側の都合で決まるため、daemon は日別までを出し、期間の合算と上限に対する色分けは macOS アプリ側で行います。

ログは追記のみなので、変化したファイルだけを読み直すようキャッシュしています。

```sh
./usage-collector.sh claude
```

コストはキャッシュの読み書きが支配的なため、read と write を単価に対して重み付けして概算します。単価は `pricing.json` で差し替えられます。Codex は ChatGPT プランに含まれ単価を持たないため、トークン数だけを出します。

ペインでのトークン行は `AGENT_STATUS_SHOW_TOKENS=0` で消せます。

### エラー時の挙動

取得に失敗した場合、daemon は `status: "offline"` / `"parse_error"` / `"error"` を state.json に書きます。pane はこれを読んでクォータバーの代わりに赤字でエラー内容を表示します。

エラー状態のサンプルで確認できます。

```sh
./agent-status-pane.sh --test sample/state-offline.json
```

## 詳細

- [設定と利用方法](docs/configuration.md)
- [仕様と内部設計](docs/specification.md)

## テスト

```sh
bash tests/run.sh
```

## ライセンス

MIT License です。詳細は [LICENSE](LICENSE) を参照してください。

## 商標について

このリポジトリは第三者のロゴ画像を同梱していません。macOS アプリは、インストール済みの
公式アプリが持つメニューバー用テンプレート画像を**実行時に**読み込み、読めない環境では
SF Symbols にフォールバックします（詳細は [macos/AgentUsage/README.md](macos/AgentUsage/README.md)）。

Claude、Claude Code は Anthropic の、ChatGPT、Codex は OpenAI の商標です。本プロジェクトは
いずれの企業とも関係がなく、公認・後援もされていません。
