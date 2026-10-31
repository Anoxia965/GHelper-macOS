//
//  Views.swift — 界面
//

import SwiftUI

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .monitor

    /// popover 版传入「展开到独立窗口」回调；主窗口版传 nil
    var showWindowAction: (() -> Void)? = nil

    enum Tab: String, CaseIterable {
        case monitor = "监控"
        case fan = "风扇"
        case battery = "电池"
        case hardware = "硬件"
        case settings = "设置"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 12) {
                switch tab {
                case .monitor:  MonitorView()
                case .fan:      FanView()
                case .battery:  BatteryView()
                case .hardware: HardwareView()
                case .settings: SettingsView()
                }
                }
                .padding(12)
            }
        }
        .environmentObject(model)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("GHelper").font(.system(size: 13, weight: .semibold))
                Text(Machine.model).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            UpdateBadge()
            if showWindowAction != nil {
                Button { showWindowAction?() } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("展开到独立窗口")
            }
            Circle()
                .fill(model.helper.isInstalled ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(model.helper.isInstalled ? "助手在线" : "未接管")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 通用组件

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

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

private struct Bar: View {
    var value: Double      // 0...1
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
                Capsule().fill(tint)
                    .frame(width: max(3, geo.size.width * min(1, max(0, value))), height: 6)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 监控

struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    /// 睿频开关绑定：开=跑满，关=锁默认频率（降温）
    private var boostBinding: Binding<Bool> {
        Binding(get: { model.boostEnabled },
                set: { model.setBoost(enabled: $0) })
    }

    var body: some View {
        VStack(spacing: 12) {
            Card(title: "处理器") {
                StatRow(label: "占用率", value: String(format: "%.0f%%", model.cpuUsage))
                Bar(value: model.cpuUsage / 100,
                    tint: model.cpuUsage > 80 ? .red : (model.cpuUsage > 50 ? .orange : .blue))
                if let f = model.cpuFrequencyMHz {
                    StatRow(label: "频率",
                            value: String(format: "%.2f GHz", f / 1000),
                            accent: f >= 4000 ? .green : (f >= 2500 ? .primary : .orange))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        Text("频率需重装特权助手（root 读取）").font(.system(size: 10))
                    }
                    .foregroundStyle(.orange)
                }
                if let t = model.cpuTemperature {
                    StatRow(label: "CPU 温度", value: String(format: "%.0f °C", t),
                            accent: t > 90 ? .red : (t > 80 ? .orange : .primary))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                        Text("需装 SMCAMDProcessor 驱动").font(.system(size: 10))
                    }
                    .foregroundStyle(.orange)
                }

                Divider().padding(.vertical, 4)
                Toggle("睿频模式（跑满）", isOn: boostBinding)
                Text(model.boostEnabled
                     ? "已开启：CPU 可睿频到上限"
                     : "已关闭：锁定默认频率（不睿频 · 降温）")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                if !model.boostStatus.isEmpty {
                    Text(model.boostStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(model.boostStatus.hasPrefix("✓") ? .green : .red)
                }
            }

            Card(title: "显卡 · \(model.hardware.gpus.first?.name ?? model.gpu.name)") {
                if let t = model.gpuTemperature {
                    StatRow(label: "温度", value: String(format: "%.0f °C", t),
                            accent: t > 85 ? .red : (t > 75 ? .orange : .primary))
                    Bar(value: t / 100, tint: t > 85 ? .red : (t > 75 ? .orange : .green))
                }
                if let u = model.gpu.utilization {
                    StatRow(label: "占用率", value: String(format: "%.0f%%", u))
                }
                // GPU 频率：有驱动的核显/独显能读到；NVIDIA 在 macOS 无驱动时为 nil
                if let f = model.gpu.frequencyMHz {
                    StatRow(label: "频率", value: String(format: "%.0f MHz", f))
                } else {
                    StatRow(label: "频率", value: "不适用（无 macOS 驱动）",
                            accent: .secondary)
                }
                if model.hardware.gpuVRAM != "—" {
                    StatRow(label: "显存", value: model.hardware.gpuVRAM)
                }
                Text("NVIDIA 在 macOS 无官方驱动，故频率无法读取；占用/温度亦非官方驱动数据，此处仅可靠显示型号与显存。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "内存") {
                StatRow(label: "已用 / 总量",
                        value: String(format: "%.1f / %.1f GB",
                                      model.memory.usedGB, model.memory.totalGB))
                Bar(value: model.memory.pressure, tint: .purple)
            }

            Card(title: "风扇") {
                if model.fans.isEmpty {
                    Text("未检测到风扇").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.fans, id: \.index) { fan in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.roleTitle(for: fan.index))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                if fan.isManual {
                                    Text("手动").font(.system(size: 9))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(String(format: "%.0f RPM", fan.actualRPM))
                                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            }
                            Bar(value: fan.actualPercent / 100, tint: .teal)
                        }
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
            if !model.helper.isInstalled {
                Card(title: "需要特权助手") {
                    Text("AppleSMC 不允许普通用户进程写入，风扇控制必须走 root 助手。去「设置」页安装。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("去安装") { model.helper.install() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            // 每把扇一张独立卡片
            ForEach(FanRole.allCases) { role in
                FanControlCard(role: role)
            }

            // CPU 温度校准（任一扇用到 CPU(SMC) 温度时才显示）
            if model.anyUsesCPUTemp {
                Card(title: "CPU 温度校准") {
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
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "状态") {
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

/// 单把扇的控制卡片：模式 / 温度来源 / 手动转速 / 曲线，全部独立
struct FanControlCard: View {
    @EnvironmentObject var model: AppModel
    let role: FanRole

    private var control: FanControl { model.controls[role] ?? FanControl() }

    var body: some View {
        Card(title: role.rawValue) {
            if role == .gpu {
                // GPU 风扇（fan1）在本机 AsusFanSMC 下手动/曲线接管即停转，
                // 只能固件自动。详见 AppModel.applyNow 的保护逻辑。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.system(size: 11))
                        Text("本机 AsusFanSMC 对 GPU 风扇的手动/曲线控制不生效——切到手动即停转，只能固件自动。")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("模式").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text("固件自动（仅此有效）").font(.system(size: 12))
                    }
                    Text("如需 GPU 风扇也能手动控速，需要换支持 fan1 手动的 AsusFanSMC 版本。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Picker("", selection: model.controlBinding(role, \.mode)) {
                    ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if control.mode != .auto {
                    Picker("温度来源", selection: model.controlBinding(role, \.tempSource)) {
                        ForEach(TempSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Text(control.tempSource.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

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
        Card(title: "曲线 · 温度 → 转速") {
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

            Button("恢复该来源的默认曲线") { model.resetCurve(role) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

            Text(AsusFanLimits.note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 风扇驱动限制

/// 前几轮结论全错，原因是风扇爬升很慢——只等 8-9 秒读到的是爬升中途的值。
/// 以下都是跑到稳态实测出来的（每档 40 秒、全程续心跳）。
///
/// 实测表（占空比 → fan0 / fan1 稳态 RPM，仅 fan0 手动可靠）：
///    5% → 3900 / 2400
///   15% → 3900 / 2800
///   30% → 3900 / 3700
///   50% → 4800 / 4700
///   75% → 6100 /  ——（fan1 手动接管即停转，此项对 GPU 风扇不可靠）
/// fan0 在 30% 以下有 3900 RPM 的地板（kext 的「不低于原厂曲线」规则）。
/// ⚠️ 关键坑：fan1（GPU 风扇）在本机 AsusFanSMC 下手动/曲线接管即停转，只能固件自动。
///    fan0（CPU 风扇）手动/曲线完全正常。两把同时手动且 ≥80% 触发固件 Turbo，
///    原生可到 7000+，由固件按温度调度。
enum AsusFanLimits {
    static let note =
        "实测稳态：5%→3900/2400，30%→3900/3700，50%→4800/4700，75%→6100 RPM（仅 CPU 风扇可靠）。"
        + "占空比封顶 75%，但 75% 已能到 6100 转，够覆盖 6000 的目标。"
        + "风扇爬升很慢，改完设定要等约 30 秒才到稳态，别以为没生效。"
        + "fan0 在 30% 以下有 3900 转的地板，再调低也降不下去。"
        + "注意：GPU 风扇（fan1）在本机驱动下手动控制不生效，只能固件自动。"
}

// MARK: - 电池

struct BatteryView: View {
    @EnvironmentObject var model: AppModel
    private var b: BatteryInfo { model.battery }

    var body: some View {
        VStack(spacing: 12) {
            if !b.present {
                Card(title: "电池") {
                    Text("未检测到电池").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Card(title: "电量") {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", b.chargePercent))
                            .font(.system(size: 30, weight: .light)).monospacedDigit()
                        Text("%").font(.system(size: 14)).foregroundStyle(.secondary)
                        Spacer()
                        if b.isCharging {
                            Label("充电中", systemImage: "bolt.fill")
                                .font(.system(size: 11)).foregroundStyle(.green)
                        } else if b.isACConnected {
                            Label("已接电源", systemImage: "powerplug")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Bar(value: b.chargePercent / 100,
                        tint: b.chargePercent < 20 ? .red : .green)
                    StatRow(label: "剩余 / 满充",
                            value: "\(b.remainingMAh) / \(b.fullChargeMAh) mAh")
                }

                Card(title: "健康") {
                    StatRow(label: "健康度",
                            value: String(format: "%.1f%%", b.healthPercent),
                            accent: b.healthPercent < 70 ? .orange : .primary)
                    Bar(value: b.healthPercent / 100,
                        tint: b.healthPercent < 70 ? .orange : .green)
                    StatRow(label: "设计容量", value: "\(b.designMAh) mAh")
                    StatRow(label: "循环次数", value: "\(b.cycleCount) 次")
                }

                Card(title: "实时") {
                    StatRow(label: "电压", value: String(format: "%.2f V", b.voltage))
                    StatRow(label: "电流",
                            value: String(format: "%d mA", b.amperage),
                            accent: b.amperage < 0 ? .orange : .green)
                    StatRow(label: "温度", value: String(format: "%.1f °C", b.temperature))
                }
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

    var body: some View {
        VStack(spacing: 12) {
            Card(title: "版本与更新") {
                HStack {
                    Text("当前版本").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(UpdateChecker.currentVersion)")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                updateStatus
                HStack(spacing: 6) {
                    Button(updater.isChecking ? "检查中…" : "检查更新") { updater.check() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(updater.isChecking || installer.isWorking)

                    if let rel = updater.updateAvailable {
                        Button(installer.isWorking ? "更新中…" : "下载并更新") {
                            installer.installUpdate(rel)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
                        .foregroundStyle(installer.isWorking ? Color.gray : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("更新会检测→下载→删掉旧安装（移废纸篓）→装新版→重启。驱动如有变化再点「安装/重装」助手。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Card(title: "特权助手") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.helper.isInstalled ? .green : .orange)
                        .frame(width: 7, height: 7)
                    Text(model.helper.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("风扇控制需要 root。助手以 LaunchDaemon 常驻，带看门狗——App 失联 15 秒会自动把风扇交回固件。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("安装 / 重装") { model.helper.install() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("卸载") { model.helper.uninstall() }
                        .controlSize(.small)
                    Button("刷新") { model.helper.refreshStatus() }
                        .controlSize(.small)
                }
            }

            Card(title: "睿频开关前置（debug=0x144）") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ocDotColor)
                        .frame(width: 7, height: 7)
                    Text(ocStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("检测并配置…") { model.helper.bootArgPromptPending = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.helper.ocBootArgStatus == .present
                                  || model.helper.ocBootArgStatus == .configured)
                }
                if !model.helper.ocBootArgMessage.isEmpty {
                    Text(model.helper.ocBootArgMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("debug=0x144 让 zenmaster 能直连 AMD SMU，睿频开关才生效。改动前会自动备份 config.plist 到 ~/Library/Application Support/GHelper/efi-backups/，且需重启才会生效。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Card(title: "开机启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .font(.system(size: 12))
                    .onChange(of: launchAtLogin) { _, new in
                        model.helper.setLaunchAtLogin(new)
                    }
            }

            Card(title: "硬件") {
                StatRow(label: "机型", value: Machine.model)
                StatRow(label: "处理器", value: Machine.cpu)
                StatRow(label: "内存", value: String(format: "%.0f GB",
                                                   Double(Machine.memoryBytes) / 1073741824))
                StatRow(label: "SMC 键", value: "\(Machine.smcKeyCount) 个")
                StatRow(label: "CPU 温度源",
                        value: model.cpuTempKey ?? "缺失",
                        accent: model.cpuTempKey == nil ? .orange : .green)
            }

            if let err = model.helper.lastError {
                Card(title: "提示") {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
        .onAppear { model.helper.checkOCBootArg() }
        .alert("配置睿频前置", isPresented: $model.helper.bootArgPromptPending) {
            Button("现在添加") { model.helper.ensureBootArg() }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("睿频开关需要 OC 的 boot-args 加 debug=0x144。是否现在自动添加？会先备份 config.plist，修改后需重启生效。")
        }
    }

    private var ocStatusText: String {
        switch model.helper.ocBootArgStatus {
        case .unknown:   return "检测中…"
        case .noOC:      return "未检测到已挂载的 OC EFI"
        case .present, .configured: return "已配置 ✓"
        case .missing:   return "未配置（OC 已挂载）"
        }
    }

    private var ocDotColor: Color {
        switch model.helper.ocBootArgStatus {
        case .present, .configured: return .green
        case .missing:              return .orange
        default:                    return .gray
        }
    }

    /// 更新检查状态行
    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle:
            Text("尚未检查。").font(.system(size: 10)).foregroundStyle(.secondary)

        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在向 GitHub 检查…").font(.system(size: 10)).foregroundStyle(.secondary)
            }

        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)

        case .available(let rel):
            VStack(alignment: .leading, spacing: 3) {
                Label("发现新版本 \(rel.tagName)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                if let body = rel.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                }
                if let page = rel.pageURL {
                    Link("查看发布说明", destination: page).font(.system(size: 10))
                }
            }

        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(.orange)
        }
    }
}

// MARK: - 菜单栏「有新版」角标

/// 独立小视图持有 @ObservedObject，避免给 RootView 加存储属性（它在别的文件里被构造）
struct UpdateBadge: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        if let rel = updater.updateAvailable, let u = rel.appDownloadURL {
            Link(destination: u) {
                Text(rel.tagName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.22), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("有新版本 \(rel.tagName)，点击下载")
        }
    }
}

// MARK: - 机器信息

enum Machine {
    static let model: String = {
        let s = Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"]) ?? ""
        return s.isEmpty ? "Mac" : s
    }()

    static let cpu: String = {
        Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]) ?? "未知"
    }()

    static let memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    private static let _keys = SMC.shared.allKeys()
    static let smcKeyCount: Int = _keys.count
}

// MARK: - 硬件详情

struct HardwareView: View {
    @EnvironmentObject var model: AppModel
    private var h: HardwareInfo { model.hardware }

    var body: some View {
        VStack(spacing: 12) {
            Card(title: "系统与机型") {
                StatRow(label: "macOS", value: "\(h.osVersion)  (\(h.osBuild))")
                if !h.kernelVersion.isEmpty && h.kernelVersion != "—" {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内核").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(h.kernelVersion)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(4)
                    }
                }
                StatRow(label: "SIP", value: h.sipStatus)
                StatRow(label: "SMBIOS", value: h.smbios)
                StatRow(label: "产品名", value: h.productName)
                StatRow(label: "序列号", value: h.serialMasked)
            }

            Card(title: "处理器") {
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

            Card(title: "内存") {
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

            Card(title: "显卡") {
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

            Card(title: "引导") {
                StatRow(label: "OpenCore", value: h.openCoreVersion)
                StatRow(label: "启动卷", value: h.bootVolume)
                StatRow(label: "平台", value: h.isHackintosh ? "黑苹果 (Hackintosh)" : "原生 Mac",
                        accent: h.isHackintosh ? .orange : .green)
            }

            Card(title: "SMC") {
                StatRow(label: "后端", value: h.smcBackend)
                StatRow(label: "键数量", value: "\(h.smcKeyCount) 个")
            }

            Card(title: "驱动 / 补丁 kext") {
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
