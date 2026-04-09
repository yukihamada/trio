#!/bin/bash
# Trioを.appバンドル化 + Developer ID署名
# 署名により同一アプリIDで永続化 → 権限ダイアログが再ビルド後も再表示されない
set -e
cd "$(dirname "$0")/.."

BIN=.build/debug/Trio
[ ! -f "$BIN" ] && { echo "❌ build first: swift build"; exit 1; }

APP=Trio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Trio"

# アイコン埋め込み
if [ -f Trio.icns ]; then
  cp Trio.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f /tmp/TrioTemplate.png ]; then
  cp /tmp/TrioTemplate.png "$APP/Contents/Resources/TrioTemplate.png"
fi
if [ -f /tmp/TrioTemplate@2x.png ]; then
  cp "/tmp/TrioTemplate@2x.png" "$APP/Contents/Resources/TrioTemplate@2x.png"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Trio</string>
    <key>CFBundleIdentifier</key><string>ai.trio.app</string>
    <key>CFBundleName</key><string>Trio</string>
    <key>CFBundleDisplayName</key><string>Trio</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>LINE等への自動メッセージ送信に使用します</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LINEメッセージをOCRで取得するため画面収録が必要です</string>
    <key>NSContactsUsageDescription</key>
    <string>送信者のプロフィール情報を取得します</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>重要メッセージ受信時に通知します</string>
</dict>
</plist>
PLIST

# Developer ID署名 (同一IDで永続化 → 権限が再ビルドで消えない)
SIGN_ID="Developer ID Application: Yuki Hamada (5BV85JW8US)"
ENTITLEMENTS="$(dirname "$0")/entitlements.plist"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: Yuki Hamada"; then
  echo "🔏 Developer ID で署名中..."
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" \
    "$APP" 2>&1 | grep -v "replacing existing signature" || true
  # 署名確認 (Authority にDeveloper IDが含まれているか)
  if codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "✅ 署名OK (Authority: Developer ID Application)"
    codesign -dvvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Developer ID|TeamIdentifier=" | head -4
  else
    echo "⚠️ 署名確認に失敗"
  fi
else
  echo "⚠️ Developer ID証明書が無いので ad-hoc署名"
  codesign --force --deep --sign - "$APP"
fi

echo ""
echo "✅ $APP built & signed"
echo "起動: open $APP"
