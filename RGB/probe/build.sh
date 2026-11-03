#!/bin/bash
# 编译 GHRGBProbe.kext（ad-hoc 签名）
#
# 两个源文件：
#   GHRGBProbe.cpp  —— 探针本体（默认静默，boot-args 带 ghrgbprobe=1 才采样）
#   kmod_stub.cpp   —— 手工 _kmod_info + __start/__stop 桩
#                      （Xcode 26 的 ld 在 -kext 下不再自动合成这些符号）
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
KSRC="GHRGBProbe.kext/Contents/MacOS"
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
	-o "$KSRC/GHRGBProbe" src/GHRGBProbe.cpp src/kmod_stub.cpp

chmod 755 "$KSRC/GHRGBProbe"

# ad-hoc 签名（SIP kext-signing 为 Custom Configuration，ad-hoc 可用）
codesign --force --sign - --timestamp=none "GHRGBProbe.kext"

# kext 必须 root:wheel
chown -R root:wheel "GHRGBProbe.kext"
chmod -R 755 "GHRGBProbe.kext"

# 源码与产物还给调用者，方便继续编辑
if [ -n "$SUDO_UID" ]; then
	chown -R "$SUDO_UID:$SUDO_GID" src "$KSRC/GHRGBProbe"
fi

echo "--- 产出 ---"
ls -la "$KSRC/GHRGBProbe"
file "$KSRC/GHRGBProbe"
echo "--- 关键符号 ---"
nm "$KSRC/GHRGBProbe" | grep -E "_kmod_info|__realmain|__antimain|__start|__stop|PE_parse_boot_argn"
echo "--- 签名 ---"
codesign -dv "GHRGBProbe.kext" 2>&1 | head -5
