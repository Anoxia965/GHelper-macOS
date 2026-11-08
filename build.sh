#!/bin/bash
#
#  构建 GHelper.app（菜单栏 App）与 GHelperHelper（root 常驻助手）
#
set -e
cd "$(dirname "$0")"

APP_NAME="GHelper"
BUILD="Build"
APPDIR="$BUILD/$APP_NAME.app"
CONTENTS="$APPDIR/Contents"

SRC_SHARED="Sources/Shared/SMC.swift Sources/Shared/HelperProtocol.swift Sources/Shared/Sensors.swift Sources/Shared/Shell.swift Sources/Shared/CoreMonitor.swift Sources/Shared/AuraController.swift Sources/Shared/WindowServerMonitor.swift"

# 兼容性：AMD 黑苹果均为 x86_64；明确指定部署目标 13.0（Ventura），
# 否则 swiftc 默认按本机 SDK（macOS 26）锁定最低版本，Sequoia(15) 及以下会打不开。
DEPLOY="-target x86_64-apple-macosx13.0"

echo "▸ 编译特权助手…"
swiftc -O $DEPLOY $SRC_SHARED Sources/Helper/main.swift \
       -o "$BUILD/GHelperHelper"

echo "▸ 编译主程序…"
swiftc -O $DEPLOY $SRC_SHARED Sources/App/FanCurve.swift \
       Sources/App/HelperClient.swift \
       Sources/App/UpdateChecker.swift \
       Sources/App/AppModel.swift \
       Sources/App/Views.swift \
       Sources/App/Components.swift \
       Sources/Shared/Hardware.swift \
       Sources/App/AppDelegate.swift \
       Sources/App/AppMain.swift \
       -o "$BUILD/GHelperBin"

echo "▸ 编译 rgbctl（灯光用户态工具，随 App 分发，安装时拷到 /usr/local/bin）…"
clang $DEPLOY -framework IOKit -framework CoreFoundation \
      RGB/kext/rgbctl.c -o "$BUILD/rgbctl" || \
    echo "  （rgbctl 编译失败）"

# 确保图标资源存在（clean checkout 自动生成，无需手动）
if [ ! -f Build/GHelper.icns ]; then
  echo "▸ 生成图标资源（make_icons.swift）…"
  swift make_icons.swift
  iconutil --convert icns Build/GHelper.iconset -o Build/GHelper.icns
fi

echo "▸ 组装 App 包…"
rm -rf "$APPDIR"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
cp "$BUILD/GHelperBin"    "$CONTENTS/MacOS/$APP_NAME"
cp "$BUILD/GHelperHelper" "$CONTENTS/MacOS/GHelperHelper"
cp Info.plist "$CONTENTS/Info.plist"
cp Build/GHelper.icns "$CONTENTS/Resources/"
cp Build/Menubar.pdf  "$CONTENTS/Resources/"
# 把随附驱动打进 App，供「一键补齐缺失驱动」从自身资源拷贝到 EFI
COPYFILE_DISABLE=1 cp -R Kexts "$CONTENTS/Resources/Kexts" 2>/dev/null || echo "  （警告：未找到仓库 Kexts/ 目录）"
# 灯光：rgbctl 用户态工具（放 MacOS，安装时拷到 /usr/local/bin）+ GHRGB.kext（放 Resources，安装时拷到 /Library/Extensions）
cp "$BUILD/rgbctl" "$CONTENTS/MacOS/rgbctl" 2>/dev/null || echo "  （警告：未编译 rgbctl）"
chmod +x "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/MacOS/GHelperHelper" "$CONTENTS/MacOS/rgbctl"
# 灯光 kext：优先本次编译产物 Build/GHRGB.kext（含通用 WMNB 选择器），其次仓库预编译 RGB/kext/GHRGB.kext
if [ -d "$BUILD/GHRGB.kext" ]; then
  COPYFILE_DISABLE=1 cp -R "$BUILD/GHRGB.kext" "$CONTENTS/Resources/GHRGB.kext"
  echo "▸ 打包 GHRGB.kext（Build 编译产物，含 WMNB 通用通道）"
else
  COPYFILE_DISABLE=1 cp -R RGB/kext/GHRGB.kext "$CONTENTS/Resources/GHRGB.kext" 2>/dev/null || echo "  （警告：未找到 GHRGB.kext）"
fi

echo "▸ 签名（ad-hoc）…"
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || \
    echo "  （签名失败，不影响本地运行）"

echo "▸ 构建 .pkg 安装器（--root 方式，固定装到 /Applications，绝不重定位）…"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
rm -rf Build/_pkgroot Build/GHelper_component.pkg "Build/GHelper-$VERSION.pkg"
mkdir -p Build/_pkgroot/Applications
cp -R "$APPDIR" Build/_pkgroot/Applications/
# 注：不 sudo chown，保持 anoxia-m:staff 即可正常安装运行，避免构建需输密码
pkgbuild --root Build/_pkgroot \
  --identifier cn.anoxia.GHelper \
  --version "$VERSION" \
  --install-location / \
  Build/GHelper_component.pkg
productbuild --package Build/GHelper_component.pkg \
  --version "$VERSION" \
  --identifier cn.anoxia.GHelper.installer \
  "Build/GHelper-$VERSION.pkg"
echo "  产物：Build/GHelper-$VERSION.pkg"

echo "▸ 打包 app.zip（供 App 内「检查更新 → 下载并更新」一键更新，仅替换 GHelper.app；更新器只认 .dmg/app.zip，故必须一并产出）…"
rm -f "Build/GHelper-$VERSION.app.zip"
# --keepParent 把 GHelper.app 目录名一并打进压缩包（顶层即 GHelper.app/），更新器解包才能定位；ditto 同时保留扩展属性与代码签名
ditto -c -k --keepParent "$APPDIR" "Build/GHelper-$VERSION.app.zip"
echo "  产物：Build/GHelper-$VERSION.app.zip"

echo "✓ 完成：$APPDIR"
