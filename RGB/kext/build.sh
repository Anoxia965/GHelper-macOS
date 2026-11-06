#!/bin/bash
# 编译 GHRGB.kext（ad-hoc 签名）
#
# 源文件：
#   GHRGB.cpp     —— 驱动本体（ACPI/WMNB 通道，控制键盘 RGB）
#   kmod_stub.cpp —— 手工 _kmod_info + __start/__stop 桩
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
KSRC="GHRGB.kext/Contents/MacOS"
mkdir -p "$KSRC"

KFW="$SDK/System/Library/Frameworks/Kernel.framework"

clang++ -arch x86_64 -mkernel -fapple-kext -nostdinc -nostdlib \
	-fno-builtin -fno-common -fno-exceptions -fno-rtti \
	-DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE \
	-isysroot "$SDK" \
	-isystem "$KFW/Headers" \
	-isystem "$KFW/PrivateHeaders" \
	-isystem "$SDK/usr/include" \
	-O2 -Wall -Wno-unused-variable -Wno-sign-conversion \
	-Wl,-kext \
	-o "$KSRC/GHRGB" src/GHRGB.cpp src/kmod_stub.cpp

chmod 755 "$KSRC/GHRGB"

# ad-hoc 签名（SIP kext-signing 为 Custom Configuration，ad-hoc 可用）
codesign --force --sign - --timestamp=none "GHRGB.kext"

# kext 最终需 root:wheel（加载时要求）；若以 root 执行则在此设置，否则留给安装脚本
if [ "$(id -u)" = "0" ]; then
	chown -R root:wheel "GHRGB.kext"
fi
chmod -R 755 "GHRGB.kext"

# 源码与产物还给调用者，方便继续编辑
if [ -n "$SUDO_UID" ]; then
	chown -R "$SUDO_UID:$SUDO_GID" src "$KSRC/GHRGB"
fi

echo "--- 产出 ---"
ls -la "$KSRC/GHRGB"
file "$KSRC/GHRGB"
echo "--- 关键符号 ---"
nm "$KSRC/GHRGB" | grep -E "_kmod_info|__realmain|__antimain|__start|__stop"
echo "--- 未定义符号（应为空或仅内核导出） ---"
nm -u "$KSRC/GHRGB" | head -20
echo "--- 签名 ---"
codesign -dv "GHRGB.kext" 2>&1 | head -5
