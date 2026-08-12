#!/bin/bash
# 卸载：停止 LaunchAgent 并删除应用
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/local.xiang.floating-im.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/FloatingIM.app"

echo "已卸载。"
