#!/usr/bin/env python3
"""
生成修改后的 OpenCore config.plist（候选文件，不直接写盘）

用法：
    python3 prepare_efi.py <源 config.plist> <输出 config.plist> [--fanpct=N]

做的事：
    1. 在 Kernel/Add 里，把 AMDRyzenCPUPowerManagement.kext 插到 SMCAMDProcessor.kext 之前
       （顺序要求：OpenCore 按数组顺序链接，依赖必须在前）
    2. 可选：在 boot-args 里追加 -asusfanpct=N，解除手动占空比 75% 的默认封顶
"""
import sys
import plistlib
import argparse


def find_boot_args(cfg):
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    return cfg.get("NVRAM", {}).get("Add", {}).get(guid, {}).get("boot-args", "")


def set_boot_args(cfg, value):
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    cfg.setdefault("NVRAM", {}).setdefault("Add", {}).setdefault(guid, {})["boot-args"] = value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--fanpct", type=int, default=None,
                    help="解除风扇占空比封顶，如 100；不加则保持现状")
    args = ap.parse_args()

    with open(args.src, "rb") as f:
        cfg = plistlib.load(f)

    add = cfg["Kernel"]["Add"]
    changes = []

    # --- 1. 插入依赖驱动 ---
    target = "AMDRyzenCPUPowerManagement.kext"
    if any(e.get("BundlePath") == target for e in add):
        print(f"[跳过] {target} 已在配置中")
    else:
        idx = next((i for i, e in enumerate(add)
                    if e.get("BundlePath") == "SMCAMDProcessor.kext"), None)
        if idx is None:
            print("[错误] 配置里找不到 SMCAMDProcessor.kext 条目")
            return 1

        entry = {
            "Arch": "Any",
            "BundlePath": target,
            "Comment": "AMD Ryzen CPU 电源管理与传感器采集（SMCAMDProcessor 的依赖，必须排在其前面）",
            "Enabled": True,
            "ExecutablePath": "Contents/MacOS/AMDRyzenCPUPowerManagement",
            "MaxKernel": "",
            "MinKernel": "",
            "PlistPath": "Contents/Info.plist",
        }
        add.insert(idx, entry)
        changes.append(f"在 Kernel/Add 第 {idx} 位插入 {target}（SMCAMDProcessor.kext 之前）")

    # --- 2. boot-args ---
    if args.fanpct is not None:
        old = find_boot_args(cfg)
        flag = f"-asusfanpct={args.fanpct}"
        if flag in old:
            print(f"[跳过] boot-args 已包含 {flag}")
        else:
            # 已存在同名参数则先替换
            parts = [p for p in old.split() if not p.startswith("-asusfanpct=")]
            new = " ".join(parts + [flag])
            set_boot_args(cfg, new)
            changes.append(f"boot-args 追加 {flag}")

    with open(args.dst, "wb") as f:
        plistlib.dump(cfg, f, sort_keys=False)

    print(f"\n已生成候选配置: {args.dst}")
    for c in changes:
        print(f"  · {c}")
    if not changes:
        print("  （无改动）")
    print("\nboot-args 现为:")
    print("  " + find_boot_args(cfg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
