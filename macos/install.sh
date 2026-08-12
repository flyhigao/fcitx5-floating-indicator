#!/bin/bash
# 安装：构建 .app → 拷贝到 ~/Applications → 注册 LaunchAgent 开机自启
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP_BUNDLE="FloatingIM.app"
DEST="$HOME/Applications/$APP_BUNDLE"
PLIST="$HOME/Library/LaunchAgents/local.xiang.floating-im.plist"
LABEL="local.xiang.floating-im"

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/FloatingIM</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "安装完成。"
echo "  应用位置: $DEST"
echo "  已注册自启: $PLIST"
echo "  首次运行请授权「输入监控」：系统设置 → 安全性与隐私 → 隐私 → 输入监控"
echo "  退出方式：点击菜单栏的 中/英 图标 → 退出 FloatingIM"
