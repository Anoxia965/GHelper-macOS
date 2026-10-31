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

    /// 读取一个 SMC 键（走 root 通道，备用）
    func readKey(_ key: String, reply: @escaping (NSNumber?, String) -> Void)

    /// 写入一个 SMC 键的原始值（应急/调试用）
    func writeKey(_ key: String, value: Double, reply: @escaping (Bool, String) -> Void)

    /// 卸载自己（删除 LaunchDaemon 与二进制）
    func uninstall(reply: @escaping (Bool, String) -> Void)
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
