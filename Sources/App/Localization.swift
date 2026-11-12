//
//  Localization.swift — 中英文切换框架
//
//  设计：以「中文原文」作为字典 key（zh 默认直接回退到 key），
//  只需为需要切换的可见文案补英文翻译即可，无需维护两份中文表。
//  用法：Text(L("监控")) 或 L("监控") 拼接到插值字符串里。
//

import Foundation
import SwiftUI

enum Lang: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var label: String { self == .zh ? "中文" : "English" }
}

enum L10n {
    /// 英文翻译表（key = 中文原文）。未列出的 key 在英文模式下也会回退显示中文。
    static let en: [String: String] = [
        // 导航 / 标签
        "监控": "Monitor",
        "风扇": "Fans",
        "灯光": "Lighting",
        "硬件": "Hardware",
        "设置": "Settings",

        // 头部 / 状态
        "GHelper": "GHelper",
        "助手在线": "Helper Online",
        "未接管": "Not Connected",
        "展开到独立窗口": "Open in Window",
        "退出 GHelper": "Quit GHelper",
        "在线": "Online",
        "离线": "Offline",

        // 状态胶囊
        "过热": "Overheat",
        "偏高": "High",
        "正常": "Normal",
        "自动": "Auto",
        "手动": "Manual",

        // 监控页卡片标题 / 标签
        "温度 · CPU": "CPU Temp",
        "显卡": "GPU",
        "电池": "Battery",
        "近 60 秒走势": "Last 60s trend",
        "全局负载": "Load",
        "实时频率": "Frequency",
        "采样中…": "Sampling…",
        "充电中": "Charging",
        "已接电源": "AC Power",
        "电池供电": "On Battery",
        "CPU 线程占用": "CPU Thread Load",
        "WindowServer · 窗口合成": "WindowServer",
        "常驻内存": "Memory",

        // 监控页 KPI 副标签
        "温度": "Temp",
        "负载": "Load",
        "转速": "Fan",
        "核心 / 线程": "Cores / Threads",
        "峰值": "Peak",
        "线程平均": "Avg",
        "高载": "Busy",

        // 按钮 / 开关
        "下载驱动": "Download Kexts",
        "登录时自动启动": "Launch at Login",
        "在程序坞显示图标": "Show Dock Icon",
        "菜单栏显示 WindowServer 占用": "Menu Bar shows WindowServer",

        // 设置分区
        "版本与更新": "Version & Update",
        "特权助手": "Privileged Helper",
        "系统前置（风扇/灯光 + 睿频必需）": "System Prereqs",
        "驱动与 EFI 管理": "Drivers & EFI",
        "开机启动": "Startup",
        "界面": "Appearance",
        "监控显示": "Monitoring",
        "致谢 / Credits": "Credits",

        // 电池
        "电量": "Charge",
        "健康": "Health",
        "实时": "Live",
        "电池养护 · 充电上限 80%": "Battery Care · 80% Cap",
        "开启电池养护（钉 80% 上限）": "Enable Battery Care (80%)",
        "设计容量": "Design",
        "循环次数": "Cycles",
        "电压": "Voltage",
        "电流": "Current",
        "频率": "Freq",
        "显存": "VRAM",
        "核心": "Core",

        // 右侧栏 / 状态
        "系统状态": "Status",
        "快捷": "Quick",
        "活动": "Activity",
        "概览": "Overview",
        "散热控制": "Cooling",
        "语言": "Language",
        "电池养护": "Battery Care",
        "状态": "Status",
        "转速总览": "Fan Overview",
        "双扇强冷": "Cool All",
        "CPU 温度校准": "CPU Temp Calibration",
        "需要特权助手": "Helper Required",
        "特权助手版本过旧": "Helper outdated",
        "点「设置 ▸ 安装/重装」更新": "Update in Settings",
        "GPU 温度不可用": "GPU temp N/A",
        "未检测到风扇": "No fans",
        "需装 SMCAMDProcessor 驱动": "Need SMCAMDProcessor",
        "机型": "Model",
        "处理器": "CPU",
        "内存": "Memory",
        "SMC 键": "SMC Keys",
        "CPU 温度源": "Temp Source",
        "缺失": "Missing",
        "未检测到电池": "No Battery",
        "检查更新": "Check Update",
        "检查中…": "Checking…",
        "下载并更新": "Download & Update",
        "更新中…": "Updating…",
        "安装 / 重装": "Install / Reinstall",
        "卸载": "Uninstall",
        "刷新": "Refresh",
        "重新测绘风扇": "Re-probe Fans",
        "测绘中…": "Probing…",
        "重新扫描": "Re-scan",
        "扫描中…": "Scanning…",
        "一键补齐缺失驱动": "Fix Missing Kexts",
        "重新检测": "Re-detect",
        "去安装": "Install",
        "提示": "Notice",
        "检测并配置…": "Configure…",
        "睿频跑满": "Boost On",
        "强冷 30s": "Cool 30s",
        "双扇强冷 30s": "Cool All 30s",
        "恢复默认曲线": "Reset Curve",
        "限制最高转速": "Cap Max RPM",
        "模式": "Mode",
        "颜色": "Color",
        "亮度与速度": "Brightness & Speed",
        "应用": "Apply",
        "关闭": "Off",
        "已是最新版本": "Up to date",
        "正在向 GitHub 检查…": "Checking GitHub…",
        "尚未检查。": "Not checked yet.",
        "查看发布说明": "Release Notes",
        "发现新版本": "New version available",

        // 菜单栏浮层（默认界面，必须可切换）
        "线程占用": "Thread Load",
        "无温度数据": "No temp data",
        "占用": "util",
        "未检测到": "None detected",
        "打开主窗口确认": "Open Main Window",
        "有 EFI 启动参数配置等待你确认（尚未写入任何 EFI 文件）":
            "EFI boot-arg config awaiting confirmation (nothing written yet)",
        "曲线已平滑 · 单核 100% 口径，多核可超过 100%":
            "Smoothed · 100% = one core; multi-core may exceed 100%",
    ]

    static func get(_ key: String, _ lang: Lang) -> String {
        guard lang == .en else { return key }
        return en[key] ?? key
    }
}

/// 当前语言镜像（非 actor 隔离，便于在任意上下文取词；UI 切换时由 AppModel 同步）。
private(set) var currentLang: Lang = .zh

/// AppModel 切换语言时调用，更新镜像并触发依赖刷新。
func setLang(_ lang: Lang) { currentLang = lang }

/// 取当前语言的可见文案。中文默认直接回退到 key（即中文原文）。
func L(_ key: String) -> String {
    L10n.get(key, currentLang)
}
