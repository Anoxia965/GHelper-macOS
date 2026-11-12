//
//  Views.swift — 仪表盘风格界面
//

import SwiftUI

// MARK: - 根视图（主窗口）

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .monitor

    /// 弹层版传入「展开到独立窗口」回调；主窗口版传 nil
    var showWindowAction: (() -> Void)? = nil

    enum Tab: String, CaseIterable {
        case monitor = "监控"
        case fan = "风扇"
        case battery = "电池"
        case lighting = "灯光"
        case hardware = "硬件"
        case settings = "设置"
        var icon: String {
            switch self {
            case .monitor:  return "chart.bar.fill"
            case .fan:      return "fan.fill"
            case .battery:  return "battery.100.bolt"
            case .lighting: return "lightbulb.fill"
            case .hardware: return "pcdisplay"
            case .settings: return "gearshape"
            }
        }
        var title: String { L(rawValue) }
    }

    var body: some View {
        HStack(spacing: 0) {
            navRail
            VStack(spacing: 0) {
                if model.helper.helperOutdated {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("特权助手版本过旧"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Text(L("点「设置 ▸ 安装/重装」更新"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                }
                header
                Divider()
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            switch tab {
                            case .monitor:  MonitorView()
                            case .fan:      FanView()
                            case .battery:  BatteryView()
                            case .lighting: LightingView()
                            case .hardware: HardwareView()
                            case .settings: SettingsView()
                            }
                        }
                        .padding(16)
                    }
                    rightRail
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 整窗铺页面底色：内容不足时不再露出系统窗口白底（右下角那块「凸出来」的白板）
        .background(Brand.canvas, ignoresSafeAreaEdges: .all)
        .tint(Brand.primary)
        .environmentObject(model)
        // EFI 相关确认框挂在根视图：安装入口分布在「设置」和「风扇」页，
        // 若挂在 SettingsView，从风扇页点「去安装」时确认框不会出现（兼容修复）。
        .alert("配置系统前置", isPresented: $model.helper.bootArgPromptPending) {
            Button("现在添加") { model.helper.previewBootArg() }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("风扇/灯光控制需要 OC 的 boot-args 加 AMFI 放行参数（amfi_get_out_of_my_way=0x1 amfi=0x80）+ csr-active-config=430A0000，睿频开关另需 debug=0x144。是否现在自动添加？会先列出将要修改的所有 OpenCore 配置供你确认，每份先备份 config.plist 再写入，修改后需重启生效。")
        }
        .alert("确认修改以下 EFI 配置", isPresented: $model.helper.bootArgConfirmPending) {
            Button("确认添加") { model.helper.ensureBootArg() }
            Button("取消", role: .cancel) {
                model.helper.ocBootArgStatus = .missing
                model.helper.ocBootArgMessage = "已取消，EFI 未被改动。需要时点「检测并配置…」或重新「安装 / 重装」即可再次预览并确认。"
            }
        } message: {
            Text(model.helper.bootArgPreviewText)
        }
    }

    // MARK: 左侧图标导航栏

    private var navRail: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 22)).foregroundStyle(Brand.primary)
                Text("GHelper")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.top, 16).padding(.bottom, 10)

            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 18))
                        Text(t.title).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(tab == t ? Brand.primary : .secondary)
                    .background(tab == t ? Brand.primary.opacity(0.12)
                                           : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // 语言切换（中 / EN）
            Picker("", selection: $model.language) {
                Text("中").tag(Lang.zh)
                Text("EN").tag(Lang.en)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()
            .padding(.bottom, 14)
        }
        .frame(width: 78)
        .padding(.horizontal, 6)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 18, weight: .semibold))
                Text(Machine.model)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            UpdateBadge()
            if showWindowAction != nil {
                Button { showWindowAction?() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless)
                    .help(L("展开到独立窗口"))
            }
            Circle()
                .fill(model.helper.isInstalled ? Brand.primary : Brand.amber)
                .frame(width: 7, height: 7)
            Text(model.helper.isInstalled ? L("助手在线") : L("未接管"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 右侧快捷栏

    private var boostBinding: Binding<Bool> {
        Binding(get: { model.boostEnabled },
                set: { model.setBoost(enabled: $0) })
    }

    private var rightRail: some View {
        VStack(spacing: 12) {
            DashCard(L("系统状态")) {
                HStack(spacing: 6) {
                    Circle().fill(model.helper.isInstalled ? Brand.primary : Brand.amber)
                        .frame(width: 8, height: 8)
                    Text(model.helper.isInstalled ? L("助手在线") : L("未接管"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(model.battery.present ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(model.battery.present
                         ? (model.battery.isCharging ? L("充电中") : L("已接电源"))
                         : L("未检测到电池"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            DashCard(L("快捷")) {
                Toggle(L("睿频跑满"), isOn: boostBinding).toggleStyle(.switch)
                Toggle(L("电池养护"), isOn: Binding(
                    get: { model.chargeLimit80 },
                    set: { model.setChargeLimit(enabled: $0) }))
                    .toggleStyle(.switch)
            }

            DashCard(L("活动")) {
                Text(model.lastApplyMessage.isEmpty ? "—" : model.lastApplyMessage)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.probingMessage.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text(model.probingMessage)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 250)
        .background(Brand.primary.opacity(0.035))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }
}

// MARK: - 通用小组件

private struct StatRow: View {
    let label: String
    let value: String
    var accent: Color = .primary

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
    }
}

private func tempLevel(_ t: Double) -> StatusPill.Level {
    if t >= 90 { return .danger }
    if t >= 80 { return .warn }
    return .ok
}
private func tempColor(_ t: Double) -> Color {
    switch tempLevel(t) {
    case .danger: return Brand.danger
    case .warn:   return Brand.amber
    default:      return Brand.accent
    }
}
private func legend(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 3) {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
        Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

// MARK: - 监控

struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    private var boostBinding: Binding<Bool> {
        Binding(get: { model.boostEnabled },
                set: { model.setBoost(enabled: $0) })
    }

    var body: some View {
        VStack(spacing: 12) {
            KPIStrip()
            HStack(spacing: 12) {
                tempCard.frame(maxWidth: .infinity)
                cpuCard.frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                fanCard.frame(maxWidth: .infinity)
                memCard.frame(maxWidth: .infinity)
            }
            coreCard
            windowServerCard
            HStack(spacing: 12) {
                gpuCard.frame(maxWidth: .infinity)
                batteryMiniCard.frame(maxWidth: .infinity)
            }
        }
    }

    /// WindowServer：黑苹果没有完整硬件加速时最吃 CPU 的常驻进程
    private var windowServerCard: some View {
        let ws = model.windowServer
        let color: Color = ws.cpuColorLevel == 2 ? Brand.danger
                         : ws.cpuColorLevel == 1 ? Brand.amber : Brand.accent
        return DashCard(L("WindowServer · 窗口合成"), accent: color) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if ws.available {
                        BigStat(value: String(format: "%.0f", ws.cpuPercent), unit: "%",
                                caption: "CPU 瞬时占用", color: color)
                    } else {
                        BigStat(value: "—", unit: "%", caption: "采样中…")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%.0f MB", ws.residentMB))
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        Text("常驻内存").font(.system(size: 10)).foregroundStyle(.secondary)
                        if let pid = ws.pid {
                            Text("PID \(pid)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.windowServerHistory.count > 1 {
                    TrendChart(data: model.smoothedWindowServerHistory,
                               color: color,
                               range: model.windowServerChartRange)
                        .frame(height: 44)
                    Text(L("曲线已平滑 · 单核 100% 口径，多核可超过 100%"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text("正在建立采样基线…")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if ws.pid == nil {
                    Text("未找到 WindowServer 进程")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                } else if ws.cpuColorLevel == 2 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(Brand.danger)
                        Text("占用很高：通常是缺少硬件加速 / 高分辨率缩放导致")
                            .font(.system(size: 10)).foregroundStyle(Brand.danger)
                    }
                }
            }
        }
    }

    private var tempCard: some View {
        DashCard(L("温度 · CPU"), accent: tempColor(model.cpuTemperature ?? 0)) {
            if let t = model.cpuTemperature {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        BigStat(value: String(format: "%.0f", t), unit: "°C",
                                color: tempColor(t))
                        Spacer()
                        StatusPill(text: t >= 90 ? "过热" : t >= 80 ? "偏高" : "正常",
                                   level: tempLevel(t))
                    }
                    TrendChart(data: model.tempHistory, color: tempColor(t),
                               range: 30...100)
                        .frame(height: 56)
                    Text("近 60 秒走势")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text("需装 SMCAMDProcessor 驱动")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var cpuCard: some View {
        DashCard(L("处理器")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    BigStat(value: String(format: "%.0f", model.cpuUsage), unit: "%",
                            caption: "全局负载")
                    Spacer()
                    if let f = model.cpuFrequencyMHz {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.2f", f / 1000))
                                .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                            Text("GHz · 实时频率").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("频率 N/A").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("需 root 助手").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
                MiniBar(value: model.cpuUsage / 100,
                        color: model.cpuUsage > 80 ? Brand.danger
                                : model.cpuUsage > 50 ? Brand.amber : Brand.accent)
                Divider().padding(.vertical, 2)
                Toggle(L("睿频跑满"), isOn: boostBinding).toggleStyle(.switch)
                if !model.boostStatus.isEmpty {
                    Text(model.boostStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(model.boostStatus.hasPrefix("✓") ? Brand.accent : Brand.danger)
                }
            }
        }
    }

    private var fanCard: some View {
        DashCard(L("风扇")) {
            if model.fans.isEmpty {
                Text("未检测到风扇").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    ForEach(model.fans, id: \.index) { fan in
                        VStack(spacing: 6) {
                            RingGauge(value: fan.actualPercent / 100,
                                      title: String(format: "%.0f", fan.actualRPM),
                                      detail: "RPM",
                                      color: fan.isManual ? Brand.amber : Brand.accent2,
                                      size: 78, thickness: 8)
                            Text(model.roleTitle(for: fan.index))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            StatusPill(text: fan.isManual ? "手动" : "自动",
                                       level: fan.isManual ? .warn : .ok)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var coreCard: some View {
        let s = model.coreSummary
        return DashCard(L("CPU 线程占用"), accent: Brand.accent2) {
            VStack(alignment: .leading, spacing: 8) {
                CoreGrid(loads: model.coreLoads,
                         physical: Machine.physicalCores,
                         cell: 19,
                         pairing: model.corePairing,
                         showLabel: true)
                HStack(spacing: 10) {
                    legend(Brand.accent, "低 <55%")
                    legend(Brand.amber, "中 55–85%")
                    legend(Brand.danger, "高 ≥85%")
                    Spacer()
                    Text(model.corePairing.label)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Divider().padding(.vertical, 1)
                HStack(spacing: 14) {
                    Text(String(format: "峰值 %.0f%%", s.peak))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(s.peak >= 85 ? Brand.danger : .primary)
                    Text(String(format: "线程平均 %.0f%%", s.average))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(String(format: "高载 %d/%d 线程", s.busy, s.total))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("线程平均来自逐核采样；上方「总占用」是全局负载，算法不同故数值略有差异。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var memCard: some View {
        DashCard(L("内存")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    BigStat(value: String(format: "%.1f", model.memory.usedGB), unit: "GB",
                            caption: "已用 / \(String(format: "%.1f", model.memory.totalGB)) GB")
                    Spacer()
                    Text(String(format: "%.0f%%", model.memory.pressure * 100))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.memory.pressure > 0.8 ? Brand.danger : .primary)
                }
                MiniBar(value: model.memory.pressure, color: .purple)
            }
        }
    }

    private var gpuCard: some View {
        DashCard(L("显卡")) {
            VStack(alignment: .leading, spacing: 6) {
                if let t = model.gpuTemperature {
                    HStack(alignment: .firstTextBaseline) {
                        BigStat(value: String(format: "%.0f", t), unit: "°C",
                                color: t > 85 ? Brand.danger : t > 75 ? Brand.amber : .primary)
                        Spacer()
                        if let u = model.gpu.utilization {
                            Text(String(format: "%.0f%% 占用", u))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    // NullMoth 额外提供的 GPU 核心/显存占用细分
                    if model.gpu.coreUtil != nil || model.gpu.memUtil != nil {
                        HStack(spacing: 14) {
                            if let c = model.gpu.coreUtil {
                                LabeledBar(label: "核心", value: c, color: Brand.accent2)
                            }
                            if let m = model.gpu.memUtil {
                                LabeledBar(label: "显存", value: m, color: Brand.accent)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        Text("GPU 温度不可用")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                if let f = model.gpu.frequencyMHz {
                    StatRow(label: "频率", value: String(format: "%.0f MHz", f))
                } else {
                    StatRow(label: "频率", value: "不适用", accent: .secondary)
                }
                if model.hardware.gpuVRAM != "—" {
                    StatRow(label: "显存", value: model.hardware.gpuVRAM)
                }
            }
        }
    }

    private var batteryMiniCard: some View {
        DashCard(L("电池")) {
            if !model.battery.present {
                Text("未检测到电池").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                let b = model.battery
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        BigStat(value: String(format: "%.0f", b.chargePercent), unit: "%",
                                caption: b.isCharging ? "充电中"
                                        : b.isACConnected ? "已接电源" : "电池供电")
                        Spacer()
                        Text(String(format: "%.0f%% 健康", b.healthPercent))
                            .font(.system(size: 12))
                            .foregroundStyle(b.healthPercent < 70 ? Brand.amber : .primary)
                    }
                    MiniBar(value: b.chargePercent / 100,
                            color: b.chargePercent < 20 ? Brand.danger : Brand.accent)
                    HStack {
                        Text(String(format: "%d / %d mAh", b.remainingMAh, b.fullChargeMAh))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%d 循环", b.cycleCount))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 风扇控制（每把扇独立）

struct FanView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            // 当前转速总览（环形）
            DashCard(L("转速总览")) {
                if model.fans.isEmpty {
                    Text("未检测到风扇").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 20) {
                        ForEach(model.fans, id: \.index) { fan in
                            VStack(spacing: 6) {
                                RingGauge(value: fan.actualPercent / 100,
                                          title: String(format: "%.0f", fan.actualRPM),
                                          detail: "RPM",
                                          color: fan.isManual ? Brand.amber : Brand.accent2,
                                          size: 96, thickness: 10)
                                Text(model.roleTitle(for: fan.index))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if !model.helper.isInstalled {
                DashCard(L("需要特权助手")) {
                    Text("AppleSMC 不允许普通用户进程写入，风扇控制必须走 root 助手。去「设置」页安装。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L("去安装")) { model.helper.install() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            ForEach(FanRole.allCases) { role in
                FanControlCard(role: role)
            }

            // 双扇同时强冷：两把扇互相等到都稳态，再一起开始 30 秒倒计时
            DashCard(L("双扇强冷")) {
                HStack(spacing: 8) {
                    if model.turboAllActive {
                        Button {
                            model.cancelTurboAll()
                        } label: {
                            if let rem = model.turboRemaining[.cpu], rem > 0 {
                                Label("双扇强冷 \(rem)s · 点击取消", systemImage: "fan.fill")
                            } else {
                                Label("双扇同步中… · 点击取消", systemImage: "fan.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    } else {
                        Button {
                            model.triggerTurboAll()
                        }                         label: {
                            Label(L("双扇强冷 30s"), systemImage: "fan.fill")
                        }
                        .buttonStyle(.bordered).tint(.orange)
                    }
                    Spacer()
                }
                Text("两把扇同时拉满，互相等到都到达各自软件可控顶速（由本机实测满速决定，首次会自动测绘）后，一起保持 30 秒再回落（限速开启时停于限制值）。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if model.anyUsesCPUTemp {
                DashCard(L("CPU 温度校准")) {
                    HStack {
                        Text("偏移").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $model.cpuTempOffset, in: -50...10, step: 1)
                        Text(String(format: "%+.0f ℃", model.cpuTempOffset))
                            .font(.system(size: 12)).monospacedDigit().frame(width: 52)
                    }
                    HStack {
                        Text("传感器原始值").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.cpuTemperatureRaw.map { String(format: "%.1f ℃", $0) } ?? "—")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    Text("SMCAMDProcessor 报的是 Tctl，在本机偏高。进 Windows 用 GHelper / HWiNFO "
                         + "看同一负载下的温度，把差值填进来即可。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            DashCard(L("状态")) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text(model.lastApplyMessage.isEmpty ? "—" : model.lastApplyMessage)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct FanControlCard: View {
    @EnvironmentObject var model: AppModel
    let role: FanRole

    private var control: FanControl { model.controls[role] ?? FanControl() }

    var body: some View {
        DashCard(role.rawValue) {
            Picker("", selection: model.controlBinding(role, \.mode)) {
                ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // 强冷按钮：立即拉满，稳态后保持 30 秒再回落到限速值 / 正常模式
            HStack(spacing: 8) {
                let ramping = model.turboRamping[role] == true
                let remain = model.turboRemaining[role]
                if ramping || remain != nil {
                    Button {
                        // 双扇强冷进行中时，单扇卡片的取消也走双扇统一取消，避免半取消导致协调态错乱
                        if model.turboAllActive { model.cancelTurboAll() } else { model.cancelTurbo(role) }
                    } label: {
                        if model.turboAllActive {
                            Label(ramping ? "双扇同步中…" : "双扇强冷 \(remain!)s", systemImage: "fan.fill")
                        } else {
                            Label(ramping ? "拉满中…" : "强冷 \(remain!)s", systemImage: "fan.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                } else {
                    Button {
                        model.triggerTurbo(role)
                    }                     label: {
                        Label(L("强冷 30s"), systemImage: "fan.fill")
                    }
                    .buttonStyle(.bordered).tint(.orange)
                }
                Text("立即冲到各自软件可控顶速（取本机实测满速，首次自动测绘），到达顶速后保持 30 秒再回落到限速值 / 正常模式")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if control.mode != .auto {
                Picker("温度来源", selection: model.controlBinding(role, \.tempSource)) {
                    ForEach(TempSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Text(control.tempSource.hint)
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                HStack {
                    Text("当前读数").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if let t = model.temperature(for: control.tempSource) {
                        Text(String(format: "%.0f %@", t, control.tempSource.unit))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    } else {
                        Text("不可用").foregroundStyle(.red).font(.system(size: 12))
                    }
                }
            }

            if control.mode == .manual {
                HStack {
                    Slider(value: model.controlBinding(role, \.manualPercent), in: 20...100, step: 5)
                    Text(String(format: "%.0f%%", control.manualPercent))
                        .font(.system(size: 12)).monospacedDigit().frame(width: 38)
                }
            }

            if control.mode == .curve {
                CurveEditor(role: role)
            }

            if control.mode != .auto {
                Divider().padding(.vertical, 4)
                HStack {
                    Toggle(L("限制最高转速"), isOn: Binding(
                        get: { model.controls[role]?.rpmLimitEnabled ?? false },
                        set: { on in
                            var c = model.controls[role] ?? FanControl()
                            if on, c.rpmLimit == 0 { c.rpmLimit = model.defaultRpmLimit(for: role) }
                            c.rpmLimitEnabled = on
                            model.controls[role] = c
                        }))
                        .toggleStyle(.switch).font(.system(size: 12))
                    Spacer()
                    if control.rpmLimitEnabled {
                        TextField("", value: model.controlBinding(role, \.rpmLimit), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72).monospacedDigit()
                        Text("RPM").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if control.rpmLimitEnabled {
                    let lim = control.rpmLimit > 0 ? control.rpmLimit : model.defaultRpmLimit(for: role)
                    let maxRPM = model.fans.first { FanRole.from(index: $0.index) == role }?.maxRPM ?? 0
                    Text(String(format: "封顶 %.0f RPM（额定 %.0f）", lim, maxRPM))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CurveEditor: View {
    @EnvironmentObject var model: AppModel
    let role: FanRole

    private var curve: FanCurve { model.controls[role]?.curve ?? .default(for: .gpu) }
    private var source: TempSource { model.controls[role]?.tempSource ?? .gpu }

    var body: some View {
        DashCard("曲线 · 温度 → 转速") {
            VStack(spacing: 6) {
                ForEach(Array(curve.points.enumerated()), id: \.element.id) { i, point in
                    HStack(spacing: 8) {
                        Text("\(Int(point.temperature))\(source.unit)")
                            .font(.system(size: 11)).monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        Slider(value: model.curvePointBinding(role, index: i), in: 0...100, step: 1)
                        Text("\(Int(point.percent))%")
                            .font(.system(size: 11)).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("转速下限 \(Int(curve.floorPercent))%")
                        .font(.system(size: 11))
                    Text("防过冷保护，低于此值会被抬回")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Slider(value: model.curveFloorBinding(role), in: 10...60, step: 5)
                    .frame(width: 100)
            }

            Button {
                model.resetCurve(role)
            } label: {
                Label(L("恢复默认曲线"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered).font(.system(size: 11))

            Text(AsusFanLimits.note)
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

enum AsusFanLimits {
    static let note =
        "风扇曲线经 WMNB/EC 直连下发（CPU=0x00110024 / GPU=0x00110025），两把扇都可接管；"
        + "GHRGB kext 未加载或 rgbctl 缺失时自动退回 SMC 通道。"
        + "曲线 8 点打包为 asus-wmi 格式，占空比按固件风扇曲线约定 0–100 百分比"
        + "（实测出厂曲线占空比即 1–90%；切忌按 0–255 写，会被固件夹到满速）。"
        + "实测最高转速由本机首次自动测绘得到（各机型额定/满速不同），可在「设置 ▸ 重新测绘风扇」刷新。"
        + "风扇爬升很慢，改完设定要等约 30–45 秒才到稳态，别以为没生效。"
        + "拿不到有效温度读数时一律交回固件自动，绝不把风扇停在低转速。"
        + "「限制最高转速」开关可把转速压在额定以下（默认值取自本机实测满速，可在「设置」重新测绘）。"
        + "「强冷」按钮（每把扇各一个，另有「双扇强冷」一键双扇）会让风扇冲到各自软件可控顶速"
        + "（取本机实测满速），到达满速后再保持 30 秒才回落，限速开启时停于限制值（默认实测满速）。"
}

// MARK: - 电池

struct BatteryView: View {
    @EnvironmentObject var model: AppModel
    private var b: BatteryInfo { model.battery }

    var body: some View {
        VStack(spacing: 12) {
            if !b.present {
                DashCard(L("电池")) {
                    Text(L("未检测到电池")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    DashCard(L("电量")) {
                        VStack(spacing: 8) {
                            RingGauge(value: b.chargePercent / 100,
                                      title: String(format: "%.0f", b.chargePercent),
                                      detail: "%",
                                      color: b.chargePercent < 20 ? Brand.danger : Brand.accent,
                                      size: 120, thickness: 12)
                            HStack {
                                if b.isCharging {
                                    Label("充电中", systemImage: "bolt.fill")
                                        .font(.system(size: 11)).foregroundStyle(Brand.accent)
                                } else if b.isACConnected {
                                    Label("已接电源", systemImage: "powerplug")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                } else {
                                    Label("电池供电", systemImage: "battery.100")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(b.remainingMAh) / \(b.fullChargeMAh) mAh")
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 12) {
                        DashCard(L("健康")) {
                            StatRow(label: "健康度",
                                    value: String(format: "%.1f%%", b.healthPercent),
                                    accent: b.healthPercent < 70 ? Brand.amber : .primary)
                            MiniBar(value: b.healthPercent / 100,
                                    color: b.healthPercent < 70 ? Brand.amber : Brand.accent)
                            StatRow(label: "设计容量", value: "\(b.designMAh) mAh")
                            StatRow(label: "循环次数", value: "\(b.cycleCount) 次")
                        }
                        DashCard(L("实时")) {
                            StatRow(label: "电压", value: String(format: "%.2f V", b.voltage))
                            StatRow(label: "电流", value: String(format: "%d mA", b.amperage),
                                    accent: b.amperage < 0 ? Brand.amber : Brand.accent)
                            StatRow(label: "温度", value: String(format: "%.1f °C", b.temperature))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                DashCard(L("电池养护 · 充电上限 80%")) {
                    Toggle(L("开启电池养护（钉 80% 上限）"), isOn: Binding(
                        get: { model.chargeLimit80 },
                        set: { model.setChargeLimit(enabled: $0) }))
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    if !model.chargeLimitStatus.isEmpty {
                        Text(model.chargeLimitStatus)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("经 root 助手写 ACPI WMNB（devid 0x00120057）。EC 冷启动会复位，助手开机即自动重涂。本机实测只支持 80% 一档，非 60/80/100 三档。")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 键盘灯光（Aura）

struct LightingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            DashCard(L("状态")) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.auraAvailable ? Brand.accent : Brand.amber)
                        .frame(width: 7, height: 7)
                    Text(model.auraStatus)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("重新检测")) { model.refreshAura() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Text("华硕键盘 RGB（GHRGB 驱动 · ACPI WMNB 通道）。经 root 助手下发，需先装好特权助手。颜色 + 亮度已真机验证；呼吸/彩虹等特效按协议下发，本机未逐一验证。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard(L("模式")) {
                Picker("模式", selection: $model.auraMode) {
                    ForEach(AuraMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            DashCard(L("颜色")) {
                ColorPicker("主色", selection: $model.auraColor)
                if model.auraMode == .breathing {
                    ColorPicker("次色", selection: $model.auraColor2)
                }
                Text("本机驱动仅支持全局单色：静态/彩虹用主色，呼吸用主色+次色。分区控制暂未实现。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard(L("亮度与速度")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("亮度").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.auraBrightness)")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(model.auraBrightness) },
                        set: { model.auraBrightness = Int($0) }),
                           in: 0...3, step: 1)
                    HStack {
                        Text("速度").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.auraSpeed)")
                            .font(.system(size: 11)).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(model.auraSpeed) },
                        set: { model.auraSpeed = Int($0) }),
                           in: 1...3, step: 1)
                }
            }

            HStack(spacing: 8) {
                Button { model.applyLighting() } label: { Text(L("应用")) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.auraAvailable)
                Button { model.turnOffLighting() } label: { Text(L("关闭")) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.auraAvailable)
                Spacer()
            }
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var efiFixPending = false

    var body: some View {
        VStack(spacing: 12) {
            DashCard(L("版本与更新")) {
                HStack {
                    Text("当前版本").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(UpdateChecker.currentVersion)")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                updateStatus
                HStack(spacing: 6) {
                    Button(updater.isChecking ? L("检查中…") : L("检查更新")) { updater.check() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(updater.isChecking || installer.isWorking)

                    if let rel = updater.updateAvailable {
                        Button(installer.isWorking ? L("更新中…") : L("下载并更新")) {
                            installer.installUpdate(rel)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(installer.isWorking)
                        if let k = rel.kextsDownloadURL {
                            Link("下载驱动", destination: k).font(.system(size: 11))
                        }
                    }
                    Spacer()
                }
                if !installer.statusText.isEmpty {
                    Text(installer.statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(installer.isWorking ? Color.gray : Brand.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("更新会检测→下载→以 root 替换旧安装（弹一次密码框）→装新版→重启。旧安装自动备份，可恢复。驱动如有变化再点「安装/重装」助手。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            DashCard(L("特权助手")) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.helper.isInstalled ? Brand.accent : Brand.amber)
                        .frame(width: 7, height: 7)
                    Text(model.helper.statusText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("风扇控制需要 root。助手以 LaunchDaemon 常驻，带看门狗——App 失联 15 秒会自动把风扇交回固件。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button(L("安装 / 重装")) { model.helper.install() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .tint(model.helper.helperOutdated ? .red : nil)
                    Button(L("卸载")) { model.helper.uninstall() }
                        .controlSize(.small)
                    Button(L("刷新")) { model.helper.refreshStatus() }
                        .controlSize(.small)
                    Button(model.isProbingFans ? L("测绘中…") : L("重新测绘风扇")) { model.probeFans() }
                        .controlSize(.small)
                        .disabled(model.isProbingFans || !model.helper.isInstalled)
                }
                if model.helper.helperOutdated {
                    Text("助手版本过旧（已装 \(model.helper.helperVersion)，当前 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")）：点「安装 / 重装」更新后即可自动生效。")
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !model.probingMessage.isEmpty {
                    Text(model.probingMessage)
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let km = model.helper.installMessage {
                    Text(km).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }

            DashCard(L("系统前置（风扇/灯光 + 睿频必需）")) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ocDotColor).frame(width: 7, height: 7)
                    Text(ocStatusText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("检测并配置…")) { model.helper.bootArgPromptPending = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.helper.ocBootArgStatus == .present
                                  || model.helper.ocBootArgStatus == .configured)
                }
                if !model.helper.ocBootArgMessage.isEmpty {
                    Text(model.helper.ocBootArgMessage)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("风扇写（WMNB/EC）与灯光写（GHRGB kext）都依赖 root 助手，而 macOS 15 严格 SIP/AMFI 会拒绝加载 ad-hoc 签名的助手，导致「能读不能控」。安装时会先扫描所有 OpenCore 配置（含 U 盘）并列出将要改动的文件，你点「确认添加」后才会写入三件套：debug=0x144（睿频开关）+ AMFI 放行 + csr-active-config=430A0000，重启后生效。未确认前 EFI 不会被改动；取消也没关系，随时可在这里补配。每份改动前自动备份到 ~/Library/Application Support/GHelper/efi-backups/。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            DashCard(L("驱动与 EFI 管理")) {
                // EFI 分区
                HStack {
                    Text("EFI 分区").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.helper.efiWorking ? L("扫描中…") : L("重新扫描")) { model.helper.scanEFI() }
                        .controlSize(.small)
                        .disabled(model.helper.efiWorking)
                }
                if model.helper.efiPartitions.isEmpty {
                    Text("点「重新扫描」列出 EFI 分区并检测驱动。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.helper.efiPartitions) { p in
                        HStack(spacing: 6) {
                            Circle().fill(p.isMounted ? Color.green : Color.gray)
                                .frame(width: 7, height: 7)
                            Text(p.id).font(.system(size: 12))
                            if !p.volumeName.isEmpty {
                                Text("(\(p.volumeName))").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.hasOC {
                                Text("含 OC").font(.system(size: 9)).foregroundStyle(Brand.accent)
                            }
                            if p.isMounted {
                                Text("已挂载").font(.system(size: 10)).foregroundStyle(.secondary)
                            } else {
                                Button("挂载") { model.helper.mountEFI(disk: p.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Divider()

                // 核心驱动
                HStack {
                    Text("核心驱动（EFI 内）").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                if model.helper.driverStatuses.isEmpty {
                    Text("挂载含 OC 的 EFI 后点「重新扫描」检测。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.helper.driverStatuses) { s in
                        HStack(spacing: 6) {
                            Circle().fill(s.dotColor).frame(width: 7, height: 7)
                            Text(s.name.replacingOccurrences(of: ".kext", with: ""))
                                .font(.system(size: 12))
                            Spacer()
                            Text(s.statusText).font(.system(size: 10)).foregroundStyle(s.dotColor)
                        }
                    }
                }

                Divider()

                Button(L("一键补齐缺失驱动")) { efiFixPending = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.helper.efiWorking || model.helper.driverStatuses.isEmpty)

                if !model.helper.efiMessage.isEmpty {
                    Text(model.helper.efiMessage)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("自动检测 EFI 挂载情况；未挂载的分区可点「挂载」手动选择。缺失的核心驱动（Lilu/VirtualSMC/AMDRyzen/SMCAMDProcessor/AsusFanSMC）一键补齐，不再需要手动拖拽。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            DashCard(L("开机启动")) {
                Toggle(L("登录时自动启动"), isOn: $launchAtLogin)
                    .font(.system(size: 12))
                    .onChange(of: launchAtLogin) { new in
                        model.helper.setLaunchAtLogin(new)
                    }
            }

            DashCard(L("界面")) {
                Toggle(L("在程序坞显示图标"), isOn: $model.showInDock)
                    .font(.system(size: 12))
                    .onChange(of: model.showInDock) { _ in model.applyActivationPolicy() }
                Text("默认关：纯菜单栏运行（同 Clash Verge），程序坞不留图标。打开后才会显示 Dock 图标，方便用程序坞切换或退出。修改即时生效，无需重启。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard(L("监控显示")) {
                Toggle(L("菜单栏显示 WindowServer 占用"),
                       isOn: $model.showWindowServerInMenuBar)
                    .font(.system(size: 12))
                Text("默认关：菜单栏继续显示 GPU/CPU 温度。打开后改为显示 WindowServer 的瞬时 CPU 占用（黑苹果无硬件加速时它常是 CPU 大户）。监控页与菜单栏弹层始终显示该项。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard(L("硬件")) {
                StatRow(label: L("机型"), value: Machine.model)
                StatRow(label: L("处理器"), value: Machine.cpu)
                StatRow(label: L("内存"), value: String(format: "%.0f GB",
                                                   Double(Machine.memoryBytes) / 1073741824))
                StatRow(label: L("SMC 键"), value: "\(Machine.smcKeyCount) 个")
                StatRow(label: L("CPU 温度源"), value: model.cpuTempKey ?? L("缺失"),
                        accent: model.cpuTempKey == nil ? .orange : Brand.accent)
            }

            DashCard(L("致谢 / Credits")) {
                Text("这个 App 能存在，首先要感谢 NullMoth（@nullmoth）：他逆向了 NVIDIA 驱动，让我的华硕 FA607（RTX 4060）能在 macOS 下用上独显——也正因为他的工作，我才有了做这个 App 的念头。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Link("NullMoth · NVIDIA macOS 驱动（逆向成果）", destination: URL(string: "https://github.com/nullmoth/nvidia-macos-driver")!)
                        .font(.system(size: 11))
                    Link("1401 · 在 Windows 上安装 macOS / 装 NVIDIA 驱动的安装器", destination: URL(string: "https://github.com/nullmoth/1401")!)
                        .font(.system(size: 11))
                    Link("1401 Mac 版安装器下载（Releases）", destination: URL(string: "https://github.com/nullmoth/nvidia-macos-driver/releases")!)
                        .font(.system(size: 11))
                }
                Divider()
                Text("同时感谢所有驱动作者与社区：Acidanthera（VirtualSMC / Lilu）、Shaneee / wtf.spinach（SMCAMDProcessor / AMDRyzenCPUPowerManagement）、AsusFanSMC 社区、NullMoth 团队，以及整个 OpenCore / Hackintosh 社区。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = model.helper.lastError {
                DashCard(L("提示")) {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
        .onAppear { model.helper.checkOCBootArg() }
        // EFI 确认框已提到 RootView（见文件开头），此处只保留驱动补齐的确认框
        .alert("补齐缺失驱动", isPresented: $efiFixPending) {
            Button("现在补齐") { model.helper.installMissingKexts() }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("会把缺失的核心驱动拷贝到 EFI/OC/Kexts 并在 config 里启用（处理好依赖顺序）。改动前自动备份 config.plist，修改后需重启生效。")
        }
    }

    private var ocStatusText: String {
        switch model.helper.ocBootArgStatus {
        case .unknown:   return "检测中…"
        case .noOC:      return "未检测到已挂载的 OC EFI"
        case .present, .configured: return "已配置 ✓"
        case .missing:   return "未配置（缺 AMFI/SIP 放行或 debug=0x144）"
        }
    }

    private var ocDotColor: Color {
        switch model.helper.ocBootArgStatus {
        case .present, .configured: return Brand.accent
        case .missing:              return Brand.amber
        default:                    return .gray
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle:
            Text(L("尚未检查。")).font(.system(size: 10)).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(L("正在向 GitHub 检查…")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .upToDate:
            Label(L("已是最新版本"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.accent)
        case .available(let rel):
            VStack(alignment: .leading, spacing: 3) {
                Label(L("发现新版本") + " \(rel.tagName)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.amber)
                if let body = rel.body, !body.isEmpty {
                    Text(body).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(6)
                }
                if let page = rel.pageURL {
                    Link(L("查看发布说明"), destination: page).font(.system(size: 10))
                }
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(Brand.amber)
        }
    }
}

// MARK: - 菜单栏「有新版」角标

struct UpdateBadge: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        if let rel = updater.updateAvailable, let u = rel.appDownloadURL {
            Link(destination: u) {
                Text(rel.tagName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Brand.amber.opacity(0.22), in: Capsule())
                    .foregroundStyle(Brand.amber)
            }
            .buttonStyle(.plain)
            .help("有新版本 \(rel.tagName)，点击下载")
        }
    }
}

// MARK: - 菜单栏弹层（紧凑仪表盘）

struct PopoverDashboard: View {
    @EnvironmentObject var model: AppModel
    var showWindowAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            header
            Divider()
            VStack(spacing: 8) {
                // CPU 综合：温度 + 走势 + 占用 + 频率（放一起）
                DashCard("CPU", accent: tempColor(model.cpuTemperature ?? 0)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Machine.cpu)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(alignment: .top, spacing: 12) {
                        // 左：温度 + 状态 + 走势
                        VStack(alignment: .leading, spacing: 4) {
                            if let t = model.cpuTemperature {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    BigStat(value: String(format: "%.0f", t), unit: "°C",
                                            color: tempColor(t))
                                    StatusPill(text: L(t >= 90 ? "过热" : t >= 80 ? "偏高" : "正常"),
                                               level: tempLevel(t))
                                }
                                TrendChart(data: model.tempHistory, color: tempColor(t),
                                           range: 30...100).frame(height: 26)
                            } else {
                                Text(L("无温度数据")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // 右：占用 + 频率（弹层窄，用紧凑字号，避免两个 30pt 大数字挤在一起）
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(String(format: "%.0f", model.cpuUsage))
                                    .font(.system(size: 22, weight: .light)).monospacedDigit()
                                Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text(L("全局负载")).font(.system(size: 9)).foregroundStyle(.secondary)
                            if let f = model.cpuFrequencyMHz {
                                Text(String(format: "%.2f GHz", f / 1000))
                                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                            }
                            MiniBar(value: model.cpuUsage / 100,
                                    color: model.cpuUsage > 80 ? Brand.danger
                                            : model.cpuUsage > 50 ? Brand.amber : Brand.accent)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    }
                }

                // 核心占用（格子小，不显示线程号；tooltip 仍可看具体线程）
                DashCard("\(L("线程占用")) · \(Machine.physicalCores)C/\(Machine.logicalCores)T",
                         accent: Brand.accent2) {
                    let s = model.coreSummary
                    VStack(alignment: .leading, spacing: 6) {
                        CoreGrid(loads: model.coreLoads,
                                 physical: Machine.physicalCores,
                                 cell: 12,
                                 pairing: model.corePairing)
                        HStack(spacing: 8) {
                            Text(L("峰值") + String(format: " %.0f%%", s.peak))
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(s.peak >= 85 ? Brand.danger : .secondary)
                            Text(L("高载") + String(format: " %d/%d", s.busy, s.total))
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(model.corePairing.label)
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                }

                // WindowServer：紧凑一行，菜单栏里随手能看到
                DashCard("WindowServer", accent: Brand.accent2) {
                    let ws = model.windowServer
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ws.available ? String(format: "%.0f", ws.cpuPercent) : "—")
                            .font(.system(size: 20, weight: .light)).monospacedDigit()
                            .foregroundStyle(ws.cpuColorLevel == 2 ? Brand.danger
                                            : ws.cpuColorLevel == 1 ? Brand.amber : .primary)
                        Text("% CPU").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f MB", ws.residentMB))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if model.windowServerHistory.count > 1 {
                        TrendChart(data: model.smoothedWindowServerHistory,
                                   color: Brand.accent2,
                                   range: model.windowServerChartRange)
                            .frame(height: 24)
                    }
                }

                // 风扇环形（等宽居中，避免偏左留白）
                DashCard(L("风扇")) {
                    if model.fans.isEmpty {
                        Text(L("未检测到")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 0) {
                            ForEach(model.fans, id: \.index) { fan in
                                VStack(spacing: 4) {
                                    RingGauge(value: fan.actualPercent / 100,
                                              title: String(format: "%.0f", fan.actualRPM),
                                              detail: "RPM",
                                              color: fan.isManual ? Brand.amber : Brand.accent2,
                                              size: 66, thickness: 7)
                                    Text(model.roleTitle(for: fan.index))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                // 显卡（与主窗口保持一致：温度 + 占用 + 核心/显存细分 + 显存）
                gpuMiniCard
            }
            .padding(12)

            // 安装触发的 EFI 二次确认框挂在主窗口 RootView（弹层是独立视图树看不到）。
            // 菜单栏用户若此时有待确认项，给一条明确提示 + 一键打开主窗口，避免「点了没反应」。
            if model.helper.bootArgConfirmPending || model.helper.bootArgPromptPending {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Text(L("有 EFI 启动参数配置等待你确认（尚未写入任何 EFI 文件）"))
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showWindowAction != nil {
                        Button(L("打开主窗口确认")) { showWindowAction?() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .cornerRadius(8)
                .padding(.horizontal, 12)
            }

            if showWindowAction != nil {
                HStack(spacing: 8) {
                    Button { showWindowAction?() } label: {
                        Label(L("展开到独立窗口"), systemImage: "macwindow")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button { model.quit() } label: {
                        Label(L("退出 GHelper"), systemImage: "power")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 320)
        // 确认框统一由主窗口 RootView 承载（同一状态挂两处会双弹）。
        // 弹层只负责提示 + 一键打开主窗口，打开后 RootView 的确认框即会出现。
    }

    private var gpuMiniCard: some View {
        DashCard(L("显卡")) {
            if let t = model.gpuTemperature {
                HStack(alignment: .firstTextBaseline) {
                    BigStat(value: String(format: "%.0f", t), unit: "°C",
                            color: t > 85 ? Brand.danger : t > 75 ? Brand.amber : .primary)
                    Spacer()
                    if let u = model.gpu.utilization {
                        Text(String(format: "%.0f%% ", u) + L("占用"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if model.gpu.coreUtil != nil || model.gpu.memUtil != nil {
                    HStack(spacing: 14) {
                        if let c = model.gpu.coreUtil {
                            LabeledBar(label: L("核心"), value: c, color: Brand.accent2)
                        }
                        if let m = model.gpu.memUtil {
                            LabeledBar(label: L("显存"), value: m, color: Brand.accent)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text(L("GPU 温度不可用"))
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if model.hardware.gpuVRAM != "—" {
                StatRow(label: L("显存"), value: model.hardware.gpuVRAM)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            Text("GHelper").font(.system(size: 13, weight: .semibold))
            Spacer()
            UpdateBadge()
            // 语言切换：菜单栏模式默认无主窗口，入口必须在浮层里也能点到
            Button {
                model.language = (model.language == .zh) ? .en : .zh
            } label: {
                Text(model.language == .zh ? "中" : "EN")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 18)
                    .background(Brand.primary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("语言"))
            Circle()
                .fill(model.helper.isInstalled ? Brand.accent : Brand.amber)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }
}

// MARK: - 机器信息

enum Machine {
    static let model: String = {
        let s = Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"]) ?? ""
        return s.isEmpty ? "Mac" : s
    }()

    /// CPU 品牌串。
    /// ⚠️ 不用 `Shell.run`（spawn 子进程 + 管道读取）：曾在 SwiftUI body 里首次求值时触发
    /// libdispatch 递归锁崩溃。sysctlbyname 是纯 C 调用，无子进程、无锁、微秒级。
    static let cpu: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "未知"
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else {
            return "未知"
        }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static let memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// 逻辑核数（含超线程）= 本机 32
    static let logicalCores: Int = ProcessInfo.processInfo.processorCount

    /// 物理核数（不含超线程）= 本机 16
    static let physicalCores: Int = {
        var pc: Int32 = 0
        var sz: Int = MemoryLayout<Int32>.size
        sysctlbyname("hw.physicalcpu", &pc, &sz, nil, 0)
        return pc > 0 ? Int(pc) : ProcessInfo.processInfo.processorCount
    }()

    private static let _keys = SMC.shared.allKeys()
    static let smcKeyCount: Int = _keys.count
}

// MARK: - 硬件详情

struct HardwareView: View {
    @EnvironmentObject var model: AppModel
    private var h: HardwareInfo { model.hardware }

    var body: some View {
        VStack(spacing: 12) {
            DashCard("系统与机型") {
                StatRow(label: "macOS", value: "\(h.osVersion)  (\(h.osBuild))")
                if !h.kernelVersion.isEmpty && h.kernelVersion != "—" {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内核").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(h.kernelVersion)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).lineLimit(4)
                    }
                }
                StatRow(label: "SIP", value: h.sipStatus)
                StatRow(label: "SMBIOS", value: h.smbios)
                StatRow(label: "产品名", value: h.productName)
                StatRow(label: "序列号", value: h.serialMasked)
            }

            DashCard("处理器") {
                Text(h.cpuBrand)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatRow(label: "物理核心", value: h.cpuCoresPhysical > 0 ? "\(h.cpuCoresPhysical)" : "—")
                    Spacer().frame(width: 12)
                    StatRow(label: "逻辑核心", value: h.cpuCoresLogical > 0 ? "\(h.cpuCoresLogical)" : "—")
                }
                StatRow(label: "厂商", value: h.cpuVendor)
            }

            DashCard("内存") {
                StatRow(label: "总容量", value: String(format: "%.1f GB", h.memoryTotalGB))
                if h.memoryModules.isEmpty {
                    Text("无模块明细（system_profiler 未返回）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(h.memoryModules) { m in
                        StatRow(label: m.size,
                                value: [m.type, m.speed].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
            }

            DashCard("显卡") {
                if h.gpus.isEmpty {
                    Text("未检测到显示控制器")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(h.gpus) { g in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.name).font(.system(size: 12))
                                Text("\(g.vendor)\(g.deviceID.isEmpty ? "" : "  \(g.deviceID)")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                if h.gpuVRAM != "—" {
                                    Text("显存 \(h.gpuVRAM)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                Text("GPU 频率：有官方驱动（如 Intel 核显、部分 AMD 独显）可读取；NVIDIA 在 macOS 下无官方驱动，无法读取频率，只能显示型号与显存。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard("引导") {
                StatRow(label: "OpenCore", value: h.openCoreVersion)
                StatRow(label: "启动卷", value: h.bootVolume)
                StatRow(label: "平台", value: h.isHackintosh ? "黑苹果 (Hackintosh)" : "原生 Mac",
                        accent: h.isHackintosh ? Brand.amber : Brand.accent)
            }

            DashCard("SMC") {
                StatRow(label: "后端", value: h.smcBackend)
                StatRow(label: "键数量", value: "\(h.smcKeyCount) 个")
            }

            DashCard("驱动 / 补丁 kext") {
                if h.kexts.count == 1 && !h.kexts[0].installed && !h.kexts[0].isLoaded {
                    Text(h.kexts[0].name).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(h.kexts) { k in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(k.statusColor == "green" ? Color.green :
                                      k.statusColor == "orange" ? Color.orange : Color.gray)
                                .frame(width: 7, height: 7)
                            Text(k.name).font(.system(size: 12))
                            Spacer()
                            Text(k.category).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(k.version).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(k.statusText).font(.system(size: 10))
                                .foregroundStyle(k.statusColor == "green" ? .green :
                                                k.statusColor == "orange" ? .orange : .secondary)
                        }
                    }
                }
            }
        }
    }
}
