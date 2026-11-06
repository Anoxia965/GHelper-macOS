//
//  FanCurve.swift — 风扇曲线模型与求值
//
//  安全底线：拿不到有效温度读数时，必须交回固件自动控制。
//  宁可不接管，也不能因为读数为 0 让风扇停在最低转速上。
//

import Foundation

struct CurvePoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var temperature: Double
    var percent: Double
}

struct FanCurve: Codable, Equatable {
    var points: [CurvePoint]

    /// 转速下限（%），防止曲线把风扇压得太低
    var floorPercent: Double = 25

    static func `default`(for source: TempSource) -> FanCurve {
        switch source {
        case .cpuSMC:
            // 灵敏曲线：本机 Ryzen 9 7940HX 在华硕固件下「固件自动」严重钝，
            // 80℃ 还不拉高转速。WMNB 通道接管后可按占空比（0–100%）直接控速。
            // 顶部按 SMC 额定 maxRPM 用满程：100% 占空比稳态 ≈ 7300 RPM，
            // 固件上限 F0Mx=7800，故末点给到 100%（让固件跑满额定转速）。
            // 30% 以下 fan0 仍卡在 ~3900 地板，故 floor 从 35% 起步避免浪费。
            return FanCurve(points: zip(
                [50, 58, 65, 72, 78, 82, 88, 95],
                [35, 45, 55, 65, 75, 82, 86, 100]
            ).map { CurvePoint(temperature: $0, percent: $1) }, floorPercent: 35)
        case .gpu:
            // GPU 曲线同样提前提速。注意：GPU 风扇（fan1）经 WMNB 接管后已可正常控速
            // （此前 SMC 手动会停转），空闲 ≈2100、100% 占空比 ≈6500+（F1Mx=7400 额定）。
            // 末点给到 100% 占空比，按 SMC 额定上限跑满。
            return FanCurve(points: zip(
                [40, 50, 58, 65, 72, 78, 84, 90],
                [30, 38, 48, 60, 70, 82, 86, 100]
            ).map { CurvePoint(temperature: $0, percent: $1) }, floorPercent: 30)
        case .battery:
            return FanCurve(points: zip(
                [25, 30, 35, 40, 45, 50, 55, 60],
                [20, 30, 40, 50, 65, 80, 92, 100]
            ).map { CurvePoint(temperature: $0, percent: $1) }, floorPercent: 25)
        case .cpuLoad:
            return FanCurve(points: zip(
                [10, 25, 40, 55, 70, 80, 90, 100],
                [20, 30, 42, 55, 70, 82, 92, 100]
            ).map { CurvePoint(temperature: $0, percent: $1) }, floorPercent: 25)
        }
    }

    /// 按温度线性插值出目标转速百分比
    func percent(at temperature: Double) -> Double {
        guard !points.isEmpty else { return 100 }
        let sorted = points.sorted { $0.temperature < $1.temperature }

        if temperature <= sorted[0].temperature { return max(floorPercent, sorted[0].percent) }
        if temperature >= sorted.last!.temperature { return sorted.last!.percent }

        for i in 0..<(sorted.count - 1) {
            let lo = sorted[i], hi = sorted[i + 1]
            if temperature >= lo.temperature && temperature <= hi.temperature {
                let span = hi.temperature - lo.temperature
                guard span > 0 else { return hi.percent }
                let ratio = (temperature - lo.temperature) / span
                return max(floorPercent, lo.percent + (hi.percent - lo.percent) * ratio)
            }
        }
        return sorted.last!.percent
    }

    mutating func sortPoints() {
        points.sort { $0.temperature < $1.temperature }
    }
}

// MARK: - 风扇角色

/// 本机（AsusFanSMC）约定：index 0 = CPU 风扇，index 1 = GPU 风扇。
/// 把「物理索引」和「语义角色」分开，UI 与指令下发都按角色走，
/// 这样以后即便索引顺序变了，也只改这一处映射。
enum FanRole: String, CaseIterable, Codable, Identifiable {
    case cpu = "CPU 风扇"
    case gpu = "GPU 风扇"

    var id: String { rawValue }

    /// 物理索引 → 角色
    static func from(index: Int) -> FanRole { index == 0 ? .cpu : .gpu }
}

// MARK: - 单把扇的独立配置

/// 每把风扇一份：各自选模式、各自选温度来源、各自有手动转速与曲线。
struct FanControl: Codable, Equatable {
    var mode: FanMode = .auto
    var tempSource: TempSource = .gpu
    var manualPercent: Double = 55
    var curve: FanCurve = .default(for: .gpu)

    /// 限制最高转速：开启后把实际转速压在 rpmLimit 以下（按 SMC 额定 maxRPM 换算成占空比封顶）。
    /// 0 = 未设，使用角色默认（CPU 7500 / GPU 7000）。
    var rpmLimitEnabled: Bool = false
    var rpmLimit: Double = 0

    /// 切到曲线模式时，把曲线重置成「当前温度来源」的默认形状
    mutating func resetCurveToDefault() {
        curve = .default(for: tempSource)
    }
}

// MARK: - 模式

enum FanMode: String, CaseIterable, Identifiable, Codable {
    case auto    = "固件自动"
    case curve   = "自定义曲线"
    case manual  = "固定转速"

    var id: String { rawValue }
}

/// 曲线引擎的输出指令（保留给调试用，正常下发已内联进 AppModel.applyNow）
struct FanCommand {
    let index: Int
    let manual: Bool
    let rpm: Double
}
