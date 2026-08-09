# Agent Usage macOS App + Widget

Claude Code と Codex の利用枠を macOS のウィジェットに表示します。

利用状況の取得は、このリポジトリ直下の `agent-status-daemon.sh` に任せ、
このディレクトリは通常の macOS アプリ、メニューバー表示、WidgetKit 表示を担当します。

## 前提

`agent-usage` の daemon が動いていて、state.json が更新されていること。

```sh
cd ../..
./agent-status-daemon.sh --start
jq . "$HOME/.cache/agent-status/state.json"
```

Claude Code 側の statusLine 設定も `agent-usage` の README に従って済ませてください。

## インストール

```sh
brew install xcodegen
cd macos/AgentUsage
./install.sh
```

その後、デスクトップを右クリック →「ウィジェットを編集」→ 検索欄に `Agent Usage` で追加します。
Small / Medium / Large に対応しています。

`AgentUsage.app` は通常のアプリとして Dock とアプリケーションスイッチャーに表示されます。同時に、メニューバーにはゲージアイコンと `Claude Code 33%` または `Codex 33%` のような最大利用率を表示します。クリックすると同じ利用状況をコンパクトに確認できます。「ログイン時に起動」の設定は本体ウィンドウにのみ表示されます。

## 構成

```text
agent-status-daemon.sh          （リポジトリ直下）
  └─ ~/.cache/agent-status/state.json
       └─ AgentUsage.app        通常アプリ + メニューバー表示。監視してミラー＋ウィジェット更新要求
            └─ ~/Library/Containers/dev.kikki.AgentUsage.Widget/Data/.../state.json
                 └─ AgentUsageWidget.appex   ウィジェット描画
```

- `Sources/Shared/`: state.json のモデルと共通の SwiftUI 部品。アプリと拡張の両方でビルドされます。
- `Sources/App/`: メニューバー常駐アプリ。
- `Sources/Widget/`: WidgetKit 拡張。
- `Tools/make-icon.swift`: アプリアイコンの生成スクリプト。

## なぜホストアプリが必要か

ウィジェット拡張は **App Sandbox が有効でないと pluginkit に登録されず、ウィジェットギャラリーに出てきません**。
サンドボックス内からは `~/.cache/agent-status/state.json` を直接読めません。

本来は App Group コンテナで受け渡しますが、App Group の entitlement には Apple Developer の
Team ID とプロビジョニングプロファイルが必要で、ローカルの ad-hoc 署名ではビルドが通りません。

そのため、非サンドボックスのホストアプリが state.json を
**ウィジェット自身のサンドボックスコンテナ**へミラーする方式にしています。
自分のコンテナであれば entitlement なしで読み書きできます。

つまり `AgentUsage.app` が起動していないとウィジェットの値が更新されません。
本体ウィンドウの「ログイン時に起動」を有効にしておくのを推奨します。daemonもログイン中に
常駐させるには、リポジトリ直下から `bash macos/AgentUsage/install-daemon-launch-agent.sh` を実行します。

## 更新のタイミング

- ホストアプリ: `state.json` を DispatchSource で監視し、inode置換時にも監視を張り直します。
  内容が変わったら `WidgetCenter.reloadTimelines(ofKind:)` を呼びます。
- ウィジェット: ホストアプリの更新要求でのみ再描画します（`.never` ポリシー）。

WidgetKit の更新は OS の予算管理下にあるため、要求どおりの間隔で必ず再描画されるとは限りません。

## 表示

`used_pct` のしきい値は pane 版に合わせています。

| 使用率 | 色 |
| --- | --- |
| 80% 以上 | 赤 |
| 50% 以上 | 橙 |
| それ未満 | 緑 |

枠のラベル（`5h` / `7d` など）は state.json の `label` をそのまま出します。
Codex は現在 7 日枠しか返さないため 1 行だけになります。返ってこない枠は行ごと省きます。

`used_pct` が `null` の枠は `--%` と表示します。
エージェントの `status` が `ok` 以外のときは、バーの代わりに `message` を赤字で表示します。

メニューバーには全エージェント・全枠のうち最大の使用率を出します。
更新から150秒以上経過したデータは、鮮度表示を橙色で示します。取得に失敗しても、前回成功した
利用枠があれば薄く表示してエラー理由を併記します。

本体ウィンドウでは「80%・95%で通知」を有効にすると、各エージェント・各利用枠がしきい値を
初めて超えた時だけ通知します。同じ枠が一度下がるまで、同じしきい値を繰り返し通知しません。

## アイコン

利用率ゲージをモチーフにした角丸アイコンで、リングの色は表示のしきい値（緑 → 橙 → 赤）と揃えています。

生成済みの PNG は `Sources/App/Assets.xcassets/AppIcon.appiconset/` にコミットしてあるため、
通常のビルドで再生成は不要です。デザインを変えたときだけ次を実行してください。

```sh
swift Tools/make-icon.swift Sources/App/Assets.xcassets/AppIcon.appiconset
```

メニューバーのアイコンは SF Symbols の `gauge.with.dots.needle.33percent` を使っています。

## 開発

```sh
xcodegen generate
open AgentUsage.xcodeproj
```

`AgentUsage.xcodeproj` は `project.yml` から生成されるため、コミット対象外です。
