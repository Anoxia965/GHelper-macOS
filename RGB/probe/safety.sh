#!/bin/bash
# GHRGB 探针安全审计 —— 当前安装状态（默认静默版）
# 用法: ./safety.sh          只检查
#       ./safety.sh clean    额外清除所有可能的残留（需 sudo，会提示）

KEXT_NAME="GHRGBProbe"
BUNDLE_ID="cn.anoxia.GHRGBProbe"
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
DIRTY=0

say_ok()   { echo -e "  ${GRN}✓${NC} $1"; }
say_bad()  { echo -e "  ${RED}✗ $1${NC}"; DIRTY=1; }
say_warn() { echo -e "  ${YEL}!${NC} $1"; }

echo "=============== GHRGB 探针 · 持久化审计 ==============="
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "[1] 当前内核是否加载"
if kmutil showloaded 2>/dev/null | grep -qiE "$KEXT_NAME|$BUNDLE_ID"; then
  say_warn "已加载（默认静默版，未带 ghrgbprobe=1 时不采样）"
  echo "      卸载命令: sudo kmutil unload -p <kext路径>"
else
  say_ok "未加载"
fi
echo ""

echo "[2] /Library/Extensions（默认静默版会加载，但不采样）"
if ls /Library/Extensions/ 2>/dev/null | grep -qi "$KEXT_NAME"; then
  say_warn "已安装默认静默版（开机加载但不碰硬件）"
else
  say_ok "无残留"
fi
echo ""

echo "[3] AuxKC 辅助内核集合（macOS 11+ 第三方 kext 的持久化入口）"
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
AUX=$(sudo strings "$KC" 2>/dev/null | grep -c "$BUNDLE_ID")
if [ "${AUX:-0}" -gt 0 ]; then
  say_bad "AuxKC 里已存在 $AUX 条 → 开机一定会加载，必须重建集合"
else
  say_ok "AuxKC 无条目"
fi
echo ""

echo "[4] 启动项（LaunchAgents / LaunchDaemons）"
if ls ~/Library/LaunchAgents/ /Library/LaunchAgents/ /Library/LaunchDaemons/ 2>/dev/null | grep -qiE "ghrgb|rgbprobe"; then
  say_bad "有指向探针的自启项"
else
  say_ok "无相关自启项"
fi
echo ""

echo "[5] 内核启动参数 boot-args"
BA=$(nvram boot-args 2>/dev/null)
if echo "$BA" | grep -qiE "ghrgb|kext"; then
  say_warn "boot-args 里有 kext 相关字样（多数是正常项，请人工确认）"
  echo "      $BA"
else
  say_ok "未被探针改动"
fi
echo ""

echo "[6] EFI 分区（OpenCore 注入路径）"
EFI_HIT=0
for V in /Volumes/*/EFI/OC/Kexts; do
  [ -d "$V" ] || continue
  if ls "$V" 2>/dev/null | grep -qi "$KEXT_NAME"; then
    say_bad "EFI 里出现探针: $V"
    EFI_HIT=1
  fi
done
[ "$EFI_HIT" -eq 0 ] && say_ok "所有已挂载 EFI 的 OC/Kexts 中均无探针"
echo ""

echo "======================================================"
if [ "$DIRTY" -eq 0 ]; then
  echo -e "${GRN}结论：状态正常。若已安装默认静默版，下次开机会加载但不采样（ProbeResult=armed-disabled）。${NC}"
else
  echo -e "${RED}结论：存在残留，见上面标 ✗ 的项。${NC}"
fi
echo "======================================================"

# ---------- clean 模式 ----------
if [ "$1" = "clean" ]; then
  echo ""
  echo ">>> 执行清除 <<<"
  sudo rm -rf "/Library/Extensions/$KEXT_NAME.kext" 2>/dev/null && echo "  已删 /Library/Extensions 副本（若有）"
  sudo kmutil unload -p "/Library/Extensions/$KEXT_NAME.kext" 2>/dev/null && echo "  已尝试卸载（若有加载）"
  echo "  提示：若 AuxKC 曾有条目，需重建集合：sudo kmutil install -R -u -v"
  echo "  完成。建议重启一次确认。"
fi
