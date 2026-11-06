#!/bin/bash
#
#  install_now.sh —— 仅开发者本地部署用：把本次编译的新 GHelper 装进本机系统
#  （App + root 助手 + rgbctl + GHRGB.kext）。普通用户请勿直接用此脚本，
#  请用 App 内「设置 ▸ 安装/重装」（从 App 自身 bundle 取资源，对任意机器通用）。
#  由 osascript with administrator privileges 触发（以 root 运行）。
#  保守策略：旧的 App / 助手 / kext 全部「移到备份（废纸篓 / 带时间戳目录）」，不删除。
#
set -e

# 当前登录用户（用于废纸篓路径与重启主程序），避免写死用户名
LOGUSER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo "$USER")}"
# 源 App 默认取仓库 Build 目录；可通过第一个参数覆盖（适配其他构建路径）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="${1:-$SCRIPT_DIR/Build/GHelper.app}"
SRC_HELPER="$SRC_APP/Contents/MacOS/GHelperHelper"
SRC_RGBCTL="$SRC_APP/Contents/MacOS/rgbctl"
SRC_KEXT="$SRC_APP/Contents/Resources/GHRGB.kext"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_APP/Contents/Info.plist" 2>/dev/null || echo "0")"

DST_APP="/Applications/GHelper.app"
DST_HELPER="/Library/PrivilegedHelperTools/cn.anoxia.GHelper.helper"
DST_RGBCTL="/usr/local/bin/rgbctl"
DST_KEXT="/Library/Extensions/GHRGB.kext"
PLIST="/Library/LaunchDaemons/cn.anoxia.GHelper.helper.plist"

TS=$(date +%Y%m%d-%H%M%S)
LOG="/tmp/gh_install_$TS.log"
exec >"$LOG" 2>&1
echo "[install] 开始于 $TS"

# ---- 0. 前置检查 ----
[ -d "$SRC_APP" ] || { echo "缺少源 App：$SRC_APP"; exit 2; }
[ -x "$SRC_HELPER" ] || { echo "缺少源助手"; exit 2; }

# ---- 1. 备份旧的 App（移到废纸篓，可恢复）----
if [ -d "$DST_APP" ]; then
  echo "[install] 备份旧 App → 废纸篓"
  mv "$DST_APP" "/Users/anoxia-m/.Trash/GHelper.app.bak-$TS" 2>/dev/null \
    || mv "$DST_APP" "/Library/Extensions/_bak_GHelper_app_$TS" 
fi

# ---- 2. 拷贝新 App ----
echo "[install] 拷贝新 App → $DST_APP"
cp -R "$SRC_APP" "$DST_APP"
chown -R root:wheel "$DST_APP"
chmod -R 755 "$DST_APP"
chmod 644 "$DST_APP/Contents/Info.plist"

# ---- 3. 助手 ----
echo "[install] 安装助手 → $DST_HELPER"
mkdir -p /Library/PrivilegedHelperTools
if [ -f "$DST_HELPER" ]; then
  mv "$DST_HELPER" "/Users/anoxia-m/.Trash/cn.anoxia.GHelper.helper.bak-$TS" 2>/dev/null \
    || mv "$DST_HELPER" "/Library/Extensions/_bak_helper_$TS"
fi
cp "$SRC_HELPER" "$DST_HELPER"
chown root:wheel "$DST_HELPER"
chmod 755 "$DST_HELPER"
# 记录助手版本，供 App 判断是否需要重装（与安装它的 App 版本比对）
echo "$VERSION" > /Library/PrivilegedHelperTools/.ghelper-helper-version

# ---- 4. rgbctl ----
echo "[install] 安装 rgbctl → $DST_RGBCTL"
if [ -f "$DST_RGBCTL" ]; then
  mv "$DST_RGBCTL" "/Users/anoxia-m/.Trash/rgbctl.bak-$TS" 2>/dev/null || true
fi
cp "$SRC_RGBCTL" "$DST_RGBCTL"
chmod 755 "$DST_RGBCTL"

# ---- 5. GHRGB.kext（备份旧的，不删除）----
echo "[install] 安装 GHRGB.kext → $DST_KEXT"
if [ -d "$DST_KEXT" ]; then
  mv "$DST_KEXT" "/Library/Extensions/GHRGB.kext.bak-$TS" 2>/dev/null \
    || mv "$DST_KEXT" "/Library/Extensions/_bak_GHRGB_$TS"
fi
cp -R "$SRC_KEXT" "$DST_KEXT"
chown -R root:wheel "$DST_KEXT"
chmod -R 755 "$DST_KEXT"
# 尝试立即加载（macOS 26 下通常需重启才真正生效，失败忽略）
kmutil load -p "$DST_KEXT" -z 2>/dev/null || echo "[install] kext 立即加载未成功（重启后生效），忽略"

# ---- 6. LaunchDaemon plist ----
echo "[install] 写 plist → $PLIST"
cat > "$PLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>cn.anoxia.GHelper.helper</string>
    <key>MachServices</key>
    <dict><key>cn.anoxia.GHelper.helper</key><true/></dict>
    <key>ProgramArguments</key>
    <array><string>/Library/PrivilegedHelperTools/cn.anoxia.GHelper.helper</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/var/log/GHelper.helper.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# ---- 7. 重新拉起助手 ----
echo "[install] 重启助手守护进程"
launchctl bootout system/cn.anoxia.GHelper.helper 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
sleep 1
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
sleep 1

# ---- 8. 重启 GHelper 主程序，立刻用上新 UI（以当前登录用户身份启动）----
echo "[install] 重启主程序以加载新 UI"
sudo -u anoxia-m osascript -e 'try' -e 'quit app "GHelper"' -e 'end try' 2>/dev/null || true
sleep 1
sudo -u anoxia-m open "$DST_APP"

echo "[install] 完成。日志：$LOG"
echo "OK"
