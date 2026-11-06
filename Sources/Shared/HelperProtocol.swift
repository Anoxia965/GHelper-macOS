//
//  HelperProtocol.swift — App 与 root 特权助手之间的 XPC 协议
//
//  为什么要分开：AppleSMC 的写入路径不允许普通用户进程调用（实测 euid=501 时
//  一律返回 kIOReturnNotReady）。所以所有写操作都交给常驻的 LaunchDaemon 去做。
//

import Foundation

/// LaunchDaemon 注册的 mach service 名，同时也是 Label
let kHelperMachServiceName = "cn.anoxia.GHelper.helper"
let kHelperInstallPath = "/Library/PrivilegedHelperTools/cn.anoxia.GHelper.helper"
let kHelperPlistPath = "/Library/LaunchDaemons/cn.anoxia.GHelper.helper.plist"

// MARK: - 助手提供的能力

@objc protocol HelperProtocol {

    /// 心跳，顺便确认助手在跑、且确实有 root
    func ping(reply: @escaping (String) -> Void)

    /// 设置风扇模式：manual=false 交回固件自动控制
    func setFanManual(_ index: Int, manual: Bool, reply: @escaping (Bool, String) -> Void)

    /// 设置风扇目标转速（RPM）。需先切到手动模式
    func setFanTargetRPM(_ index: Int, rpm: Double, reply: @escaping (Bool, String) -> Void)

    /// 读取 CPU 实时频率（MHz）。powermetrics 需要 root，所以放助手这里跑。
    /// 返回 (MHz, 状态描述)；读不到时返回 (0, 错误原因)。
    func readFrequency(reply: @escaping (Double, String) -> Void)

    /// 设置 CPU 睿频模式（经 root 助手调 zenmaster 操作 SMU）。
    /// enabled = true：放开睿频上限，CPU 跑满；false：把睿频上限钉到基础频率（不睿频·降温）。
    /// 返回 (是否成功, 描述)。后端（debug=0x144 或 DirectHW）未就绪时返回失败并附带指引。
    func setBoostMode(enabled: Bool, reply: @escaping (Bool, String) -> Void)

    /// 读取一个 SMC 键（走 root 通道，备用）
    func readKey(_ key: String, reply: @escaping (NSNumber?, String) -> Void)

    /// 写入一个 SMC 键的原始值（应急/调试用）
    func writeKey(_ key: String, value: Double, reply: @escaping (Bool, String) -> Void)

    /// 卸载自己（删除 LaunchDaemon 与二进制）
    func uninstall(reply: @escaping (Bool, String) -> Void)

    /// 设置键盘 RGB 灯光（经 GHRGB kext → ACPI WMNB）。
    /// 参数均为 0…255（r/g/b）、mode（0=静态…）、brightness（0…15，本机实测 0–3）、speed（0/1/2）。
    /// 返回 (是否成功, 描述)。rgbctl 未安装或 GHRGB 驱动未加载时返回失败并附带指引。
    func applyKeyboardLighting(r: Int, g: Int, b: Int, mode: Int,
                              brightness: Int, speed: Int,
                              reply: @escaping (Bool, String) -> Void)

    /// 通用 WMNB 直通（经 rgbctl 调 GHRGB kext → ACPI ATKD）。
    /// sig: 0x53564544("DEVS") 写 / 0x53545344("DSTS") 查；devid/a1..a4 为 WMNB 参数。
    /// 返回 (是否成功, 输出/错误文本)。用于读取风扇曲线缓存与调试。
    func callWMNB(sig: UInt32, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                 reply: @escaping (Bool, String) -> Void)

    /// 经 WMNB 写风扇自定义曲线并接管（替代 SMC 手动模式，目标接近 Windows GHelper）。
    /// devid: 0x00110024=CPU 风扇 / 0x00110025=GPU 风扇。
    /// a1..a4 为 asus-wmi 打包的 8 点曲线：a1=温度字节(点0..3)，a2=温度字节(点4..7)，
    /// a3=占空比字节(点0..3)，a4=占空比字节(点4..7)（固件用 0–100，100*percent/255 缩放）。
    /// 首次接管会先读出厂曲线缓存，看门狗超时/交回时写回出厂曲线（比 SMC Md=0 更彻底）。
    func setFanCurve(_ index: Int, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                    reply: @escaping (Bool, String) -> Void)

    /// 把某把扇交回固件自动（写回缓存的出厂曲线）；未缓存出厂曲线时退回 SMC Md=0。
    func releaseFanCurve(_ index: Int, reply: @escaping (Bool, String) -> Void)

    /// 维持 WMNB 风扇看门狗心跳（不改变曲线，仅刷新 lastCommand，防止 App 活着却被误回收）。
    func keepFanAlive(_ index: Int, reply: @escaping (Bool, String) -> Void)

    /// 助手自报版本（与安装它的 App 版本一致）。读不到返回 "0"，便于 App 判断是否需要重装。
    /// 由 App 内「安装/重装」/install_now 写入 /Library/PrivilegedHelperTools/.ghelper-helper-version。
    func helperVersion(reply: @escaping (String) -> Void)
}

// MARK: - 错误

enum HelperError: LocalizedError {
    case notInstalled
    case connectionFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notInstalled:       return "特权助手尚未安装"
        case .connectionFailed:   return "无法连接特权助手"
        case .timeout:            return "特权助手响应超时"
        }
    }
}
