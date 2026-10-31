#!/bin/bash
#
#  把 AMD 电源管理驱动的改动整个撤销（如果你不想冒这个险）
#
#  用法：sudo ./remove_amd_kexts.sh
#
#  做两件事：
#    1. 恢复改动前的 config.plist（连带去掉 -asusfanpct=100）
#    2. 删掉 EFI/OC/Kexts/AMDRyzenCPUPowerManagement.kext
#
#  结果：机器回到今天改动之前的状态，风扇控制照常可用（占空比封顶回到 75%），
#        CPU 温度仍然没有，App 继续用 GPU 温度驱动曲线。
#

set -e

BK="/Users/anoxia-m/WorkBuddy/重写Ghelp/Backup/EFI-20261031-000709/config.plist.orig"
MOUNT="/tmp/efimount"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo ./remove_amd_kexts.sh" >&2
    exit 1
fi

mkdir -p "$MOUNT"
# 已经挂着就直接用，避免 mount_msdos 报 "Resource busy"
if mount | grep -q "$MOUNT"; then
    echo "（EFI 已挂载，直接使用）"
else
    mount_msdos /dev/disk0s4 "$MOUNT"
fi

echo "▸ 恢复 config.plist…"
cp "$BK" "$MOUNT/EFI/OC/config.plist"

echo "▸ 移除 AMDRyzenCPUPowerManagement.kext…"
rm -rf "$MOUNT/EFI/OC/Kexts/AMDRyzenCPUPowerManagement.kext"

echo "▸ 校验…"
plutil -lint "$MOUNT/EFI/OC/config.plist"
python3 -c "
import plistlib
c = plistlib.load(open('$MOUNT/EFI/OC/config.plist','rb'))
names = [e.get('BundlePath','') for e in c['Kernel']['Add']]
print('AMDRyzenCPUPowerManagement 是否还在配置里:', any('AMDRyzen' in n for n in names))
g='7C436110-AB2A-4BBB-A880-FE41995C9F82'
print('boot-args 是否还有 -asusfanpct:', '-asusfanpct' in c['NVRAM']['Add'][g]['boot-args'])
"

sync
umount "$MOUNT" || diskutil unmount force "$MOUNT" || true

echo "✓ AMD 驱动改动已撤销，现在重启就回到改动前的状态"
