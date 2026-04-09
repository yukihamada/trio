#!/bin/bash
# Trio DMG生成 + (任意で) Notarization
set -e
cd "$(dirname "$0")/.."

APP="Trio.app"
VERSION="0.1.0"
DMG="Trio-$VERSION.dmg"

[ ! -d "$APP" ] && { echo "❌ $APP not found. Run make_app_bundle.sh first"; exit 1; }

# 署名確認
if ! codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "❌ Developer ID署名がありません。make_app_bundle.sh を先に実行"
  exit 1
fi

# DMG作成
echo "📦 DMG作成中..."
rm -f "$DMG"
TMPDIR=$(mktemp -d)
cp -R "$APP" "$TMPDIR/"
ln -s /Applications "$TMPDIR/Applications"
hdiutil create -volname "Trio" -srcfolder "$TMPDIR" -ov -format UDZO "$DMG"
rm -rf "$TMPDIR"

# DMGを署名
echo "🔏 DMGを署名..."
codesign --force --sign "Developer ID Application: Yuki Hamada (5BV85JW8US)" "$DMG"

ls -lh "$DMG"
echo "✅ $DMG 作成完了"

# Notarization (NOTARY_PROFILEが設定されてる場合のみ)
if [ -n "$NOTARY_PROFILE" ]; then
  echo ""
  echo "🍎 Notarization中..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "✅ Notarization完了、stapler適用済"
else
  echo ""
  echo "ℹ️  Notarizationをスキップ (NOTARY_PROFILE未設定)"
  echo "   本番配布時は以下を実行:"
  echo "   xcrun notarytool store-credentials trio-notary --apple-id you@example.com --team-id 5BV85JW8US"
  echo "   NOTARY_PROFILE=trio-notary ./scripts/build_dmg.sh"
fi
