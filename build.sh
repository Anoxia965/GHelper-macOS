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

SRC_SHARED="Sources/Shared/SMC.swift Sources/Shared/HelperProtocol.swift Sources/Shared/Sensors.swift Sources/Shared/Shell.swift"

echo "▸ 编译特权助手…"
swiftc -O $SRC_SHARED Sources/Helper/main.swift \
       -o "$BUILD/GHelperHelper"

echo "▸ 编译主程序…"
swiftc -O $SRC_SHARED Sources/App/FanCurve.swift \
       Sources/App/HelperClient.swift \
       Sources/App/AppModel.swift \
       Sources/App/Views.swift \
       Sources/Shared/Hardware.swift \
       Sources/App/AppDelegate.swift \
       Sources/App/AppMain.swift \
       -o "$BUILD/GHelperBin"

echo "▸ 组装 App 包…"
rm -rf "$APPDIR"
mkdir -p "$CONTENTS/MacOS"
cp "$BUILD/GHelperBin"    "$CONTENTS/MacOS/$APP_NAME"
cp "$BUILD/GHelperHelper" "$CONTENTS/MacOS/GHelperHelper"
cp Info.plist "$CONTENTS/Info.plist"
chmod +x "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/MacOS/GHelperHelper"

echo "▸ 签名（ad-hoc）…"
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || \
    echo "  （签名失败，不影响本地运行）"

echo "✓ 完成：$APPDIR"
