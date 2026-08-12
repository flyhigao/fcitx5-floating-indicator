#!/bin/bash
# 编译 FloatingIM.swift 并打包成 .app（含 Info.plist 与临时签名）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FloatingIM"
APP_BUNDLE="$APP_NAME.app"
BIN_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# 本机 swiftc 5.4.2 与默认的 MacOSX12.1 SDK 不兼容，优先使用 11.x SDK
SDK_DIR="$(xcrun --show-sdk-path 2>/dev/null || true)"
for CANDIDATE in \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX11.3.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX11.1.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX11.sdk"; do
    if [ -d "$CANDIDATE" ]; then
        SDK_DIR="$CANDIDATE"
        break
    fi
done

swiftc -O -sdk "$SDK_DIR" -framework Cocoa -framework Carbon \
    FloatingIM.swift -o "$BIN_PATH"

# 诊断工具（排查输入法内部中英切换用，不打包进 .app）
swiftc -O -sdk "$SDK_DIR" -framework Carbon \
    diagnose.swift -o diagnose

cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>FloatingIM</string>
    <key>CFBundleIdentifier</key>
    <string>local.xiang.floating-im</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FloatingIM</string>
    <key>CFBundleDisplayName</key>
    <string>输入法浮动指示器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 稳定签名身份：使用钥匙串访问创建的「FloatingIM Dev」代码签名证书
# （身份固定后，TCC 权限不会因重新编译而失效）
IDENTITY_HASH=$(security find-identity -p codesigning 2>/dev/null | grep "FloatingIM Dev" | head -1 | awk '{print $2}')
if [ -n "$IDENTITY_HASH" ]; then
    codesign --force -s "$IDENTITY_HASH" "$APP_BUNDLE" 2>/dev/null || codesign --force -s - "$APP_BUNDLE"
else
    echo "警告：未找到 FloatingIM Dev 签名证书，使用 ad-hoc 签名（权限可能在重编译后失效）"
    codesign --force -s - "$APP_BUNDLE"
fi

echo "构建完成: $APP_BUNDLE"
echo "运行方式: open $APP_BUNDLE"

# 窗口探针（排查豆包中英小窗用）
swiftc -O -sdk "$SDK_DIR" -framework CoreGraphics \
    probe-popup.swift -o probe-popup
