#!/bin/bash
#
#  在 EFI 分区里放一份「已知可用」的 config.plist，方便万一开不了机时一行命令救回来
#
#  用法：sudo ./stage_fallback_efi.sh
#
#  放好之后，如果真的卡在开机，进恢复模式 → 终端，执行：
#      mkdir -p /tmp/efi && mount_msdos /dev/disk0s4 /tmp/efi
#      cp /tmp/efi/EFI/OC/config.plist.orig /tmp/efi/EFI/OC/config.plist
#      reboot
#

set -e

SRC="/Users/anoxia-m/WorkBuddy/重写Ghelp/Backup/EFI-20261031-000709/config.plist.orig"
MOUNT="/tmp/efimount"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo ./stage_fallback_efi.sh" >&2
    exit 1
fi

[ -f "$SRC" ] || { echo "找不到备份: $SRC" >&2; exit 1; }

mkdir -p "$MOUNT"
# 已经挂着就直接用，避免 mount_msdos 报 "Resource busy"
if mount | grep -q "$MOUNT"; then
    echo "（EFI 已挂载，直接使用）"
else
    mount_msdos /dev/disk0s4 "$MOUNT"
fi

echo "▸ 把改动前的 config.plist 存进 EFI 分区…"
cp "$SRC" "$MOUNT/EFI/OC/config.plist.orig"

echo "▸ 写一份恢复说明到 EFI 分区…"
cat > "$MOUNT/EFI/OC/如何恢复.txt" <<'TXT'
如果开不了机（卡苹果 logo / 内核崩溃）：

1. 开机进恢复模式：开机按住 Cmd+R，或在 OpenCore 界面选 Recovery
2. 菜单 → 实用工具 → 终端
3. 依次执行：
     mkdir -p /tmp/efi
     mount_msdos /dev/disk0s4 /tmp/efi
     cp /tmp/efi/EFI/OC/config.plist.orig /tmp/efi/EFI/OC/config.plist
     reboot

这一步会把 config.plist 恢复成加入 AMDRyzenCPUPowerManagement 之前的样子，
风扇相关的 -asusfanpct=100 也会一并去掉。

只想去掉 AMD 电源管理驱动、保留风扇参数的话，改用：
     rm -rf /tmp/efi/EFI/OC/Kexts/AMDRyzenCPUPowerManagement.kext
     （再手动把 config.plist 里该驱动那一条删掉，或直接用 config.plist.orig）
TXT

echo "▸ 校验…"
plutil -lint "$MOUNT/EFI/OC/config.plist.orig"
ls -la "$MOUNT/EFI/OC/config.plist.orig"

sync
umount "$MOUNT" || diskutil unmount force "$MOUNT" || true

echo "✓ 后路已备好：EFI 里现在有 config.plist.orig 和《如何恢复.txt》"
