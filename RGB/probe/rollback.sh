#!/bin/bash
# GHRGBProbe 回滚 / 卸载脚本
#
# 用途：把 GHRGBProbe 探针 kext 从 AuxKC（辅助内核集合）里彻底移除，
#      使下一次开机不再加载它。
#
# 用法：sudo ./rollback.sh
#
# 什么时候用：
#   - 探针测试完成，不想再让它加载
#   - 开机时内核崩溃（panic），进安全模式后执行本脚本
#
# 安全模式进法（黑苹果 OpenCore）：
#   OC 启动选择界面选中 macOS，按住 Shift 再回车，或启动参数加 -x。
#   安全模式不加载 AuxKC，所以一定能进系统。

set -u

KEXT_ID="cn.anoxia.GHRGBProbe"
KEXT_PATH="/Library/Extensions/GHRGBProbe.kext"
KC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
MGMT="/private/var/db/KernelExtensionManagement/AuxKC/CurrentAuxKC"
INSTR="$MGMT/com.apple.kcgen.instructions.plist"

echo "================================================================"
echo " GHRGBProbe 回滚"
echo "================================================================"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限。请用：sudo $0"
    exit 1
fi

# ---------- 1. 备份指令文件 ----------
if [ -f "$INSTR" ]; then
    BK="$INSTR.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$INSTR" "$BK"
    echo "[1/5] 已备份指令文件 -> $BK"
else
    echo "[1/5] 指令文件不存在，跳过备份"
fi

# ---------- 2. 从 kcgen 指令中删除我们的条目 ----------
if [ -f "$INSTR" ]; then
    /usr/bin/python3 - "$INSTR" "$KEXT_ID" <<'PY'
import plistlib, sys
path, kext_id = sys.argv[1], sys.argv[2]
d = plistlib.load(open(path, "rb"))
build = d.get("kextsToBuild", {})
if kext_id in build:
    del build[kext_id]
    plistlib.dump(d, open(path, "wb"))
    print("[2/5] 已从 kextsToBuild 移除 %s" % kext_id)
else:
    print("[2/5] kextsToBuild 里本来就没有 %s" % kext_id)
PY
else
    echo "[2/5] 无指令文件，跳过"
fi

# ---------- 3. 删除 StashedExtensions 里的副本 ----------
if [ -d "$MGMT/StashedExtensions" ]; then
    removed=0
    for d in "$MGMT/StashedExtensions"/*/; do
        [ -d "$d" ] || continue
        if find "$d" -maxdepth 2 -name "GHRGBProbe.kext" | grep -q .; then
            rm -rf "$d"
            removed=$((removed + 1))
        fi
    done
    echo "[3/5] 已删除 $removed 个暂存副本"
else
    echo "[3/5] 无暂存目录"
fi

# ---------- 4. 重建 AuxKC ----------
echo "[4/5] 重建 AuxKC（可能需要几十秒）..."
kmutil rebuild 2>&1 | tail -5
if [ -f "$KC" ]; then
    if strings "$KC" 2>/dev/null | grep -q "$KEXT_ID"; then
        echo "      ⚠️  重建后 AuxKC 里仍能看到 $KEXT_ID"
        echo "      保险做法：直接删除 $KC 让系统下次开机自动重建"
    else
        echo "      ✓ 重建完成，AuxKC 里已无 $KEXT_ID"
    fi
fi

# ---------- 5. 删除 kext 文件本体 ----------
for p in "$KEXT_PATH" "/Library/Application Support/GHRGBDev/GHRGBProbe.kext"; do
    if [ -d "$p" ]; then
        rm -rf "$p"
        echo "[5/5] 已删除 $p"
    fi
done
rmdir "/Library/Application Support/GHRGBDev" 2>/dev/null || true
echo "[5/5] 完成：kext 已从所有位置移除"

echo
echo "================================================================"
echo " 完成。确认状态："
echo "================================================================"
echo "  AuxKC 中 $KEXT_ID 出现次数: $(strings "$KC" 2>/dev/null | grep -c "$KEXT_ID")"
echo "  当前内核是否加载: $(kextstat 2>/dev/null | grep -c "$KEXT_ID")"
echo
echo "两者都为 0 即彻底清除干净。下次开机不会再加载。"
