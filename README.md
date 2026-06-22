# Agent Usage Pane

Claude Code と Codex の利用枠を cmux/tmux の細いペインに表示するモニターです。

## まず使う

```sh
brew install jq bc
./install.sh
./agent-status-pane.sh
```

`agent-status-pane.sh` を起動すれば、裏側の Daemon も自動で起動します。

うまく表示されないときは診断を実行します。

```sh
./install.sh --doctor
```

設定やスクリプトを変更したあと daemon を入れ替える場合:

```sh
./agent-status-daemon.sh --restart
```

## 設定する場所

設定は `install.sh` が作る `agent-status.env` に書きます。cmux 側に長い環境変数を書く必要はありません。

最低限よく触るのはこのあたりです。

```sh
AGENT_STATUS_BAR_WIDTH=12
```

Codex はデフォルトで `codex app-server` を使うので、通常は設定不要です。

Claude Code は statusLine から渡される JSON を読みます。Claude Code の設定に次を追加してください。

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/kikki/src/agent-usage/claude-status-line.sh",
    "refreshInterval": 5
  }
}
```

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
cd /Users/kikki/src/agent-usage
./agent-status-pane.sh
```

tmux なら例として:

```sh
tmux split-window -h -l 48 'cd /Users/kikki/src/agent-usage && ./agent-status-pane.sh'
```

## ファイル構成

- `agent-status.env`: あなたの設定。Git 管理しません。
- `agent-status.env.example`: 設定サンプル。
- `agent-status-daemon.sh`: API を取得して状態 JSON を作る常駐プロセス。
- `agent-status-pane.sh`: 状態 JSON を表示するペイン用 UI。

状態ファイルは既定で `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status/state.json` に作られます。

## 詳細

- [設定と利用方法](docs/configuration.md)
- [仕様と内部設計](docs/specification.md)
