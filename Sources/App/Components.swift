//
//  Components.swift — 仪表盘通用组件与设计令牌
//
//  统一 GHelper 的视觉语言：品牌青绿配色、卡片、环形转速表、
//  温度走势、状态胶囊、CPU 核心占用网格。浅色/深色随系统自动适配。
//

import SwiftUI
import AppKit   // NSColor 动态外观色（Brand.canvas 深浅模式自适应）

// MARK: - 设计令牌

enum Brand {
    /// 主强调色：靛紫（截图那种旗舰仪表盘的质感主色）
    static let primary  = Color(rgb: 0x5B6CF0)
    /// 次强调色：青色（图表第二系列 / 点缀）
    static let secondary = Color(rgb: 0x18C2C9)
    /// 兼容别名：accent → 主紫，accent2 → 青
    static let accent  = primary
    static let accent2 = secondary
    /// 深底（图标底色 / 深色模式下导航栏底）
    static let deep    = Color(rgb: 0x0E1B18)
    /// 浅底（选中态 / 浅色模式导航栏底）
    static let soft    = Color(rgb: 0xE1F5EE)
    /// 琥珀（偏高 / 警告）
    static let amber   = Color(rgb: 0xE0A23A)
    /// 红（过热 / 高载）
    static let danger  = Color(rgb: 0xE5544B)
    /// 页面底色：浅色 = 极浅紫灰、深色 = 深紫灰（动态色，跟随系统外观）。
    /// 必须整窗铺满，否则内容不足时会露出系统窗口白底，右下角像凸出一块白板。
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 0xF4 / 255, green: 0xF5 / 255, blue: 0xFB / 255, alpha: 1)
    })
    /// 签名渐变（紫 → 青），用于转速环描边与关键高光，强化设计感
    static var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary],
                      startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// 由 RRGGBB 整数构造（不含 alpha）
    init(rgb hex: UInt32) {
        self.init(red:  Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255)
    }

    /// 按负载 0…100 给核心格子上色：绿 → 琥珀 → 红
    static func core(_ load: Double) -> Color {
        if load >= 85 { return Brand.danger }
        if load >= 55 { return Brand.amber }
        return Brand.accent
    }
}

// MARK: - 卡片

struct DashCard<Content: View>: View {
    let title: String
    /// 保留参数以兼容现有调用点；第一方风格下标题统一用中性灰，不再用强调色圆点
    var accent: Color = Brand.accent
    @ViewBuilder var content: Content

    init(_ title: String, accent: Color = Brand.accent, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

// MARK: - 大数字读数

struct BigStat: View {
    let value: String
    let unit: String
    var caption: String = ""
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 34, weight: .thin)).monospacedDigit()
                    .foregroundStyle(color)
                Text(unit)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 环形仪表

struct RingGauge: View {
    var value: Double     // 0…1
    var title: String
    var detail: String
    var color: Color
    var size: CGFloat = 88
    var thickness: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, value))))
                .stroke(Brand.gradient, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: thickness * 0.7, x: 0, y: 0)
                .animation(.easeInOut(duration: 0.6), value: value)
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                Text(detail)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 趋势图（折线 + 渐变填充）

struct TrendChart: View {
    var data: [Double]
    var color: Color = Brand.accent
    var range: ClosedRange<Double>? = nil

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let lo = range?.lowerBound ?? (data.min() ?? 0)
            let hi = range?.upperBound ?? (data.max() ?? 1)
            let span = max(0.001, hi - lo)
            let step = data.count > 1 ? w / CGFloat(data.count - 1) : w

            ZStack {
                // 面积填充
                Path { p in
                    guard data.count > 1 else { return }
                    for (i, v) in data.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h - CGFloat((v - lo) / span) * h
                        i == 0 ? p.move(to: CGPoint(x: x, y: y))
                               : p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))

                // 折线
                Path { p in
                    guard !data.isEmpty else { return }
                    for (i, v) in data.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h - CGFloat((v - lo) / span) * h
                        i == 0 ? p.move(to: CGPoint(x: x, y: y))
                               : p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {
    var text: String
    var level: Level
    enum Level { case ok, warn, danger, neutral }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fill.opacity(0.16), in: Capsule())
            .foregroundStyle(fill)
            .fixedSize()
    }

    private var fill: Color {
        switch level {
        case .ok:      return Brand.accent
        case .warn:    return Brand.amber
        case .danger:  return Brand.danger
        case .neutral: return .secondary
        }
    }
}

// MARK: - CPU 核心 / 线程占用网格

/// 逻辑线程编号与物理核的对应关系，两种 CPU 不一样：
/// - Intel HT：同一核的两个线程编号相邻（0,1 / 2,3 …）→ `interleaved`，列 = 物理核、行 = 线程序号
/// - AMD SMT（Ryzen）：前一半是各物理核的首线程、后一半是第二线程（0…n-1 / n…2n-1）→ `splitHalf`
/// 选错会让「同一核两个线程」的分组看起来错位，所以按 CPU 品牌自动选，也允许 UI 显示出来。
enum CorePairing {
    case interleaved
    case splitHalf

    /// 把网格里的 (列 c, 行 r) 映射到 loads 的索引
    func index(column c: Int, row r: Int, physical: Int, threads: Int) -> Int {
        switch self {
        case .interleaved: return c * threads + r
        case .splitHalf:   return r * physical + c
        }
    }

    var label: String {
        switch self {
        case .interleaved: return "HT 交错编号"
        case .splitHalf:   return "SMT 分半编号"
        }
    }

    /// 按 CPU 品牌推断（本机 Ryzen 走 splitHalf；Intel 机型走 interleaved）。
    /// 用纯 Swift String 的 lowercased/contains，不依赖 NSString 的隐式桥接。
    static func detect(from brand: String) -> CorePairing {
        brand.lowercased().contains("intel") ? .interleaved : .splitHalf
    }
}

/// loads 长度 = 逻辑线程数；physical = 物理核数 → 排成 physical 列 × 每核线程数行
struct CoreGrid: View {
    var loads: [Double]
    var physical: Int
    var cell: CGFloat = 17
    var pairing: CorePairing = .splitHalf
    var showLabel: Bool = false

    private var threads: Int { max(loads.count / max(physical, 1), 1) }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<threads, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<physical, id: \.self) { c in
                        let idx = pairing.index(column: c, row: r,
                                                physical: physical, threads: threads)
                        Cell(load: idx < loads.count ? loads[idx] : 0,
                             size: cell,
                             index: idx,
                             label: showLabel ? "\(idx)" : nil)
                    }
                }
            }
        }
    }

    struct Cell: View {
        var load: Double
        var size: CGFloat
        /// 真实逻辑线程编号（tooltip 用；不再依赖可选 label 反推）
        var index: Int
        var label: String?

        private var normalized: Double { min(1, max(0, load / 100)) }

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    // 低负载时留 0.28 底色，避免深色主题下格子几乎看不见
                    .fill(Color.core(load).opacity(0.28 + 0.72 * normalized))
                // 细描边让每个格子边界清晰（浅色/深色都成立）
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                if let label = label {
                    Text(label)
                        .font(.system(size: size >= 17 ? 8 : 7, weight: .medium))
                        .monospacedDigit()
                        // 低负载底色浅 → 用深色字；高负载底色深 → 用白字
                        .foregroundStyle(normalized > 0.55
                                         ? Color.white.opacity(0.92)
                                         : Color.primary.opacity(0.62))
                }
            }
            .frame(width: size, height: size)
            .help(String(format: "线程 %d · %.0f%%", index, load))
        }
    }
}

// MARK: - 细进度条

struct MiniBar: View {
    var value: Double      // 0…1
    var color: Color = Brand.accent
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, value)))),
                           height: 5)
            }
        }
        .frame(height: 5)
    }
}

/// 带标签与百分比文字的小进度条（value 为 0…100 的百分比）
struct LabeledBar: View {
    let label: String
    let value: Double
    var color: Color = Brand.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            MiniBar(value: value / 100, color: color)
        }
        .frame(width: 104)
    }
}

// MARK: - KPI 大数字卡（旗舰仪表盘顶部那一排）

/// 单个 KPI 卡：图标 + 标题 + 任意内容（大数字 / 走势）
struct KpiCard<Content: View>: View {
    let title: String
    var icon: String = ""
    var tint: Color = Brand.primary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

/// 顶部 KPI 一排：温度 / 负载 / 风扇 / 显卡
struct KPIStrip: View {
    @EnvironmentObject var model: AppModel

    private func delta(_ arr: [Double]) -> Double? {
        guard arr.count >= 2 else { return nil }
        return arr[arr.count - 1] - arr[arr.count - 2]
    }

    private func trendChip(_ d: Double, unit: String, goodWhenUp: Bool = true) -> some View {
        let up = d >= 0
        let good = goodWhenUp ? up : !up
        return HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%+.0f%@", abs(d), unit))
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(good ? Brand.secondary : Brand.amber)
    }

    private func tempColor(_ t: Double) -> Color {
        t >= 90 ? Brand.danger : t >= 80 ? Brand.amber : Brand.primary
    }

    var body: some View {
        HStack(spacing: 12) {
            // CPU 温度
            KpiCard(title: L("温度"), icon: "thermometer.medium", tint: tempColor(model.cpuTemperature ?? 0)) {
                if let t = model.cpuTemperature {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", t))
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                            .foregroundStyle(tempColor(t))
                        Text("°C").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if let d = delta(model.tempHistory) {
                        trendChip(d, unit: "°", goodWhenUp: false)
                    }
                } else {
                    Text("—").font(.system(size: 26, weight: .bold)).foregroundStyle(.secondary)
                    Text(L("需装 SMCAMDProcessor 驱动")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            // CPU 负载
            KpiCard(title: L("负载"), icon: "cpu", tint: Brand.primary) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", model.cpuUsage))
                        .font(.system(size: 30, weight: .bold)).monospacedDigit()
                        .foregroundStyle(model.cpuUsage > 80 ? Brand.danger
                                         : model.cpuUsage > 50 ? Brand.amber : Brand.primary)
                    Text("%").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let f = model.cpuFrequencyMHz {
                    Text(String(format: "%.2f GHz", f / 1000))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(L("实时频率")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            // 风扇（主扇转速）
            KpiCard(title: L("转速"), icon: "fan", tint: Brand.secondary) {
                if let fan = model.fans.first {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", fan.actualRPM))
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Brand.secondary)
                        Text("RPM").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text(model.roleTitle(for: fan.index))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 26, weight: .bold)).foregroundStyle(.secondary)
                    Text(L("未检测到风扇")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            // 显卡温度
            KpiCard(title: L("显卡"), icon: "display", tint: Brand.primary) {
                if let t = model.gpuTemperature {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", t))
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                            .foregroundStyle(t > 85 ? Brand.danger : t > 75 ? Brand.amber : Brand.primary)
                        Text("°C").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if let u = model.gpu.utilization {
                        Text(String(format: "%.0f%% 占用", u))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").font(.system(size: 26, weight: .bold)).foregroundStyle(.secondary)
                    Text(L("GPU 温度不可用")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 124)
    }
}
