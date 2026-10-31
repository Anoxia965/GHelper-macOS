#!/bin/bash
#
#  把 Build/GHelper.app + Kexts/ 打成 DMG，作为 GitHub Release 的安装包
#
set -e
cd "$(dirname "$0")"

STAGE="Build/dmg_root"
OUT="Build/GHelper.dmg"

echo "▸ 组装 DMG 内容…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "Build/GHelper.app" "$STAGE/"
cp -R "Kexts" "$STAGE/Kexts"
cp "README.md" "$STAGE/README.md" 2>/dev/null || true
# 清理 macOS 资源叉垃圾
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

echo "▸ 生成 DMG…"
rm -f "$OUT"
/usr/bin/hdiutil create -volname "GHelper" -srcfolder "$STAGE" -ov -format UDZO "$OUT"

rm -rf "$STAGE"
echo "✓ 完成：$OUT  ($(du -h "$OUT" | cut -f1))"
