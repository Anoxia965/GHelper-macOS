//
//  Components.swift — 仪表盘通用组件与设计令牌
//
//  统一 GHelper 的视觉语言：品牌青绿配色、卡片、环形转速表、
//  温度走势、状态胶囊、CPU 核心占用网格。浅色/深色随系统自动适配。
//

import SwiftUI

// MARK: - 设计令牌

enum Brand {
    /// 主青绿
    static let accent  = Color(rgb: 0x1D9E75)
    /// 亮青绿
    static let accent2 = Color(rgb: 0x5DCAA5)
    /// 深青黑（图标底色）
    static let deep    = Color(rgb: 0x0E1B18)
    /// 浅青底（选中态）
    static let soft    = Color(rgb: 0xE1F5EE)
    /// 琥珀（偏高）
    static let amber   = Color(rgb: 0xE0A23A)
    /// 红（过热 / 高载）
    static let danger  = Color(rgb: 0xD9544B)
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
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(.quaternary, lineWidth: 1))
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
                    .font(.system(size: 30, weight: .light)).monospacedDigit()
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
                .stroke(color.opacity(0.15), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, value))))
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                .rotationEffect(.degrees(-90))
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

/// loads 长度 = 逻辑核数；physical = 物理核数 → 自动排成 physical 列 × 每核线程数行
struct CoreGrid: View {
    var loads: [Double]
    var physical: Int
    var cell: CGFloat = 17
    var showLabel: Bool = false

    private var threads: Int { max(loads.count / max(physical, 1), 1) }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<threads, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<physical, id: \.self) { c in
                        let idx = c * threads + r
                        Cell(load: idx < loads.count ? loads[idx] : 0,
                             size: cell,
                             label: showLabel ? "\(idx)" : nil)
                    }
                }
            }
        }
    }

    struct Cell: View {
        var load: Double
        var size: CGFloat
        var label: String?

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.core(load)
                            .opacity(0.16 + 0.84 * min(1, max(0, load) / 100)))
                if let label = label {
                    Text(label)
                        .font(.system(size: 7))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: size, height: size)
            .help(String(format: "线程 %d · %.0f%%", label.map { Int($0) ?? 0 } ?? 0, load))
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
