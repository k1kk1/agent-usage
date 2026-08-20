#!/usr/bin/env bash
# ビルドして /Applications へ配置し、ウィジェットを登録する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="AgentUsage"
INSTALL_PATH="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf 'xcodegen が必要です: brew install xcodegen\n' >&2
  exit 1
fi

xcodegen generate

xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath build \
  build

# 起動中だと差し替えられないので先に落とす。
pkill -f "$INSTALL_PATH" 2>/dev/null || true
sleep 1

rm -rf "$INSTALL_PATH"
cp -R "build/Build/Products/Release/$APP_NAME.app" /Applications/

# ウィジェット拡張を LaunchServices / pluginkit に認識させる。
"$LSREGISTER" -f "$INSTALL_PATH"
open "$INSTALL_PATH"
pluginkit -a "$INSTALL_PATH/Contents/PlugIns/AgentUsageWidget.appex" 2>/dev/null || true

# pkd への登録は 30 秒近く遅れることがある。
for _ in $(seq 1 30); do
  sleep 2
  # grep -q が早期終了すると pipefail で pluginkit 側が SIGPIPE 扱いになるため、
  # 先に出力を変数へ受けてから判定する。
  registered="$(pluginkit -mAvvv 2>/dev/null || true)"
  if [[ "$registered" == *'dev.kikki.AgentUsage.Widget'* ]]; then
    printf 'インストール完了。ウィジェットギャラリーから "Agent Usage" を追加してください。\n'
    exit 0
  fi
done

printf 'アプリは起動しましたが、ウィジェットがまだ登録されていません。数秒待って再確認してください:\n' >&2
printf '  pluginkit -mAvvv | grep AgentUsage\n' >&2
exit 1
