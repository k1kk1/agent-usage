#!/usr/bin/env bash
# agent-status-daemon をユーザーのログイン中だけ単一起動するLaunchAgentを登録する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="dev.kikki.agent-usage.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-status"
UID_VALUE="$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  printf 'LaunchAgent を解除しました。\n'
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true

cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>exec '$ROOT_DIR/agent-status-daemon.sh'</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launch-agent.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launch-agent.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID_VALUE" "$PLIST_PATH"
printf 'LaunchAgent を登録しました: %s\n' "$LABEL"
