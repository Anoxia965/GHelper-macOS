#!/bin/bash
#
#  回滚：把 EFI 恢复到修改前的状态
#
#  用法（需要 sudo）：
#      sudo ./rollback_efi.sh
#
#  会做两件事：
#    1. 用备份的 config.plist.orig 覆盖 EFI/OC/config.plist
#    2. 删除 EFI/OC/Kexts/AMDRyzenCPUPowerManagement.kext
#
#  如果开不了机：用 OpenCore 启动菜单选择，或在 OC 界面按空格显示隐藏项，
#  也可以直接从别的盘/PE 挂载 EFI 手动改回来——备份就在 Backup/EFI-20261031-000709/
#

set -e

BK="/Users/anoxia-m/WorkBuddy/重写Ghelp/Backup/EFI-20261031-000709"
MOUNT="/tmp/efimount"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行" >&2
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
cp "$BK/config.plist.orig" "$MOUNT/EFI/OC/config.plist"

echo "▸ 移除 AMDRyzenCPUPowerManagement.kext…"
rm -rf "$MOUNT/EFI/OC/Kexts/AMDRyzenCPUPowerManagement.kext"

echo "▸ 校验…"
plutil -lint "$MOUNT/EFI/OC/config.plist"

sync
umount "$MOUNT"

echo "✓ 已回滚，可以重启了"
