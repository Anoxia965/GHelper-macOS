//
//  AuraController.swift — 华硕键盘 RGB 控制（后端：GHRGB kext → ACPI WMNB）
//
//  原理：本机（华硕 FA607 黑苹果）键盘 RGB 走 ACPI WMNB（与风扇共用 EC 信箱，由 AML
//  互斥），不是 USB Aura 控制器（vendor 0x0B05 在本机不可见，旧 HID 方案走不通）。
//
//  通道链：App → root 特权助手（LaunchDaemon）→ /usr/local/bin/rgbctl（root）→
//  GHRGB kext（IOUserClient）→ \_SB.ATKD WMNB。rgbctl / IOServiceOpen 需要 root，
//  普通用户进程调不动，所以必须经助手。
//
//  本类只持有 UI 状态（available / statusMessage / lastApplied）并把指令转交给注入的
//  RGBBackend（由 AppModel 实现，实际走 HelperClient）。这样 Shared 层不反向依赖 App 层。
//

import Foundation
import SwiftUI

/// 灯光模式。modeByte 映射到 asus-wmi / DSDT TU56 的 mode 字节：
/// 0=静态（本机已真机验证）；其余为按协议下发的特效，本机未逐一验证。
public enum AuraMode: String, CaseIterable, Identifiable, Codable {
    case staticColor = "静态"
    case breathing  = "呼吸"
    case colorCycle = "色彩循环"
    case rainbow    = "彩虹"
    public var id: String { rawValue }
    public var modeByte: UInt8 {
        switch self {
        case .staticColor: return 0
        case .breathing:   return 1
        case .colorCycle:  return 2
        case .rainbow:     return 3
        }
    }
}

/// 一个 RGB 颜色（0…255），便于与 SwiftUI Color 互转
public struct RGB: Equatable {
    public var r: UInt8 = 0
    public var g: UInt8 = 0
    public var b: UInt8 = 0
    public init(r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0) { self.r = r; self.g = g; self.b = b }
    public init(_ t: (UInt8, UInt8, UInt8)) { r = t.0; g = t.1; b = t.2 }
}

/// 灯光后端抽象：由 App 注入（实际实现走 root 助手 → rgbctl → GHRGB kext）。
/// 放在 Shared 层，避免 Shared 反向依赖 App 层的 HelperClient。
@MainActor
public protocol RGBBackend: AnyObject {
    /// 应用颜色 + 模式 + 亮度 + 速度（本机 kext 仅支持全局单色，per-zone 未实现）
    func rgbSet(r: UInt8, g: UInt8, b: UInt8, mode: UInt8, brightness: Int, speed: Int)
    /// 关闭（黑 + 亮度 0）
    func rgbTurnOff()
}

@MainActor
public final class AuraController: ObservableObject {
    @Published public var available = false
    @Published public var statusMessage = "未检测"
    @Published public var lastApplied = ""

    /// 由 AppModel 注入；nil 时表示后端不可用（未装助手）
    public weak var backend: RGBBackend?

    public init() {}

    // MARK: 检测

    /// 重新检测可用性（实际 = 后端是否就位，即 root 助手已装）
    public func refresh() {
        if backend != nil {
            available = true
            statusMessage = "GHRGB 驱动已就绪，可控制"
        } else {
            available = false
            statusMessage = "未连接灯光后端（需先安装特权助手）"
        }
    }

    // MARK: 对外接口

    /// 应用整套灯光配置。perZone / zones 本机 kext 暂不支持（全局单色），取主色。
    public func apply(mode: AuraMode, color: RGB, color2: RGB,
                      brightness: Int, speed: Int, perZone: Bool, zones: [RGB]) {
        guard let backend = backend else {
            statusMessage = "未连接灯光后端"
            return
        }
        let c = perZone && zones.count == 4 ? zones[0] : color
        backend.rgbSet(r: c.r, g: c.g, b: c.b,
                       mode: mode.modeByte, brightness: brightness, speed: speed)
        lastApplied = "已应用：\(mode.rawValue) · 亮度 \(brightness)"
        statusMessage = lastApplied
    }

    /// 关闭灯光（黑 + 亮度 0）
    public func turnOff() {
        guard let backend = backend else {
            statusMessage = "未连接灯光后端"
            return
        }
        backend.rgbTurnOff()
        lastApplied = "已关闭"
        statusMessage = lastApplied
    }
}
