//
//  AppModel.swift — 全局状态与轮询
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {

    /// 全局单例：菜单栏代理与主程序共用同一个实例
    @MainActor static let shared = AppModel()

    // 传感器
    @Published var cpuUsage: Double = 0
    @Published var memory = MemoryStats()
    @Published var gpu = GPUStats()
    @Published var battery = BatteryInfo()
    @Published var fans: [FanState] = []
    @Published var hardware = HardwareInfo()

    // 频率（CPU 实时频率来自 root 助手跑 powermetrics；GPU 频率无驱动时为 nil）
    @Published var cpuFrequencyMHz: Double?

    // 温度
    @Published var cpuTemperature: Double?       // 校准后
    @Published var cpuTemperatureRaw: Double?    // 传感器原始值
    @Published var gpuTemperature: Double?
    @Published var cpuTempKey: String?        // 命中的 CPU 温度 SMC 键，nil 表示没有

    // 风扇控制（每把扇独立：CPU 风扇 / GPU 风扇 各自一份）
    @Published var controls: [FanRole: FanControl] = [
        .cpu: FanControl(mode: .auto, tempSource: .cpuSMC, manualPercent: 55,
                        curve: .default(for: .cpuSMC)),
        .gpu: FanControl(mode: .auto, tempSource: .gpu,    manualPercent: 55,
                        curve: .default(for: .gpu)),
    ] {
        didSet { save(); applyNow() }
    }
    /// CPU 温度校准偏移（℃）。默认 0（中性，通用）。
    ///
    /// 不同机器 / 驱动读数基准不同，这里不放机器专属默认值。
    /// 若发现 macOS 读数整体偏高或偏低，在「设置」页按自己 Windows 或 HWiNFO
    /// 同负载下的温度把差值填进来即可（滑块范围 -50…+10）。
    @Published var cpuTempOffset: Double = 0 {
        didSet { save(); applyNow() }
    }
    @Published var lastApplyMessage: String = ""

    // 睿频模式：true=跑满（放开上限），false=锁默认频率（降温）。持久化，默认开启。
    @Published var boostEnabled: Bool = true {
        didSet { UserDefaults.standard.set(boostEnabled, forKey: Key.boost) }
    }

    /// 睿频开关的即时反馈（成功/失败都显示，解决「点了没反应」看不到结果的问题）
    @Published var boostStatus: String = ""

    // MARK: 每把扇独立控制（绑定辅助）

    /// 按角色的通用字段绑定（模式 / 温度来源 / 手动转速）
    func controlBinding<T>(_ role: FanRole, _ kp: WritableKeyPath<FanControl, T>) -> Binding<T> {
        Binding(
            get: { self.controls[role]?[keyPath: kp] ?? FanControl()[keyPath: kp] },
            set: { v in
                var c = self.controls[role] ?? FanControl()
                c[keyPath: kp] = v
                self.controls[role] = c
            }
        )
    }

    /// 曲线某个温度点对应的转速百分比绑定
    func curvePointBinding(_ role: FanRole, index: Int) -> Binding<Double> {
        Binding(
            get: { self.controls[role]?.curve.points[index].percent ?? 0 },
            set: { v in
                var c = self.controls[role] ?? FanControl()
                guard c.curve.points.indices.contains(index) else { return }
                c.curve.points[index].percent = v
                self.controls[role] = c
            }
        )
    }

    /// 曲线转速下限绑定
    func curveFloorBinding(_ role: FanRole) -> Binding<Double> {
        Binding(
            get: { self.controls[role]?.curve.floorPercent ?? 25 },
            set: { v in
                var c = self.controls[role] ?? FanControl()
                c.curve.floorPercent = v
                self.controls[role] = c
            }
        )
    }

    /// 物理风扇索引 → 角色标题（给监控页等展示用）
    func roleTitle(for index: Int) -> String { FanRole.from(index: index).rawValue }

    var helper = HelperClient()
    private let smc = SMC.shared
    private let cpuMonitor = CPUMonitor()
    private var pollTimer: Timer?
    private var fanTimer: Timer?
    private var freqTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// SMCAMDProcessor 装好后可能出现的 CPU 温度键
    private static let cpuTempKeys = ["TC0P", "TC1P", "TC0D", "TC0E", "TC0F",
                                      "TC0J", "TCTL", "TCPU", "TC0C"]

    init() {
        load()
        do { try smc.open() } catch { NSLog("SMC 打开失败: \(error)") }
        detectCPUTempKey()
        refresh()
        helper.refreshStatus()
        loadHardware()

        // helper 的 @Published 变化转发给 model，驱动 UI 立即刷新（状态点/睿频前置等）
        helper.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        fanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyNow() }
        }
        freqTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFrequency() }
        }

        // 启动后按已存偏好重涂睿频模式（助手装好才生效）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.applyBoostOnLaunch()
        }
    }

    // MARK: 睿频模式

    /// 用户在 UI 切换睿频开关
    func setBoost(enabled: Bool) {
        boostEnabled = enabled
        applyBoostNow()
    }

    /// 启动时按已存偏好重涂（不打扰用户）
    func applyBoostOnLaunch() {
        guard helper.isInstalled else { return }
        applyBoostNow()
    }

    private func applyBoostNow() {
        guard helper.isInstalled else {
            boostStatus = "需先安装特权助手"
            lastApplyMessage = "睿频开关需先安装特权助手"
            return
        }
        boostStatus = "应用中…"
        helper.setBoostMode(enabled: boostEnabled) { [weak self] ok, msg in
            Task { @MainActor in
                guard let self = self else { return }
                self.lastApplyMessage = "睿频：\(msg)"
                self.boostStatus = ok ? "✓ \(msg)" : "✗ \(msg)"
            }
        }
    }

    /// 菜单栏标题：优先 GPU 温度，没有就退化成 CPU 占用
    var menuBarTitle: String {
        if let t = gpuTemperature { return String(format: "%.0f°", t) }
        if let t = cpuTemperature { return String(format: "%.0f°", t) }
        return String(format: "%.0f%%", cpuUsage)
    }

    // MARK: 硬件信息（后台探测一次）

    func loadHardware() {
        let model = self
        DispatchQueue.global(qos: .utility).async {
            let info = collectHardware()
            DispatchQueue.main.async { model.hardware = info }
        }
    }

    // MARK: 采集

    func refresh() {
        cpuUsage = cpuMonitor.sample()
        memory = readMemoryStats()
        gpu = readGPUStats()
        gpuTemperature = gpu.temperature
        battery = readBatteryInfo(smc: smc)
        fans = readFans(smc: smc)

        if let key = cpuTempKey, let v = smc.readDouble(key), v > 0 {
            cpuTemperatureRaw = v
            cpuTemperature = max(0, v + cpuTempOffset)
        } else {
            cpuTemperatureRaw = nil
            cpuTemperature = nil
        }
    }

    /// CPU 实时频率：走 root 助手（powermetrics 需要 root）。读不到时为 nil。
    func refreshFrequency() {
        guard helper.isInstalled else { cpuFrequencyMHz = nil; return }
        helper.readFrequency { [weak self] mhz, _ in
            Task { @MainActor in
                self?.cpuFrequencyMHz = mhz > 0 ? mhz : nil
            }
        }
    }

    /// 每次启动探测一次；驱动装上重启后就会自动出现
    func detectCPUTempKey() {
        for k in Self.cpuTempKeys where smc.exists(k) {
            cpuTempKey = k
            return
        }
        cpuTempKey = nil
    }

    // MARK: 温度选择

    /// 按某种温度来源解析出当前读数（供各把扇独立使用）
    func temperature(for source: TempSource) -> Double? {
        switch source {
        case .cpuSMC:  return cpuTemperature ?? gpuTemperature
        case .gpu:     return gpuTemperature
        case .battery: return battery.temperature > 0 ? battery.temperature : gpuTemperature
        case .cpuLoad: return cpuUsage
        }
    }

    /// 是否至少有一把扇在用 CPU(SMC) 温度——决定校准卡是否显示
    var anyUsesCPUTemp: Bool {
        controls.values.contains { $0.tempSource == .cpuSMC }
    }

    // MARK: 风扇指令下发

    /// 上一次每把扇真正下发的「是否手动」状态，避免重复指令
    private var lastManualState: [Int: Bool] = [:]

    func applyNow() {
        guard helper.isInstalled else {
            lastApplyMessage = "需要先安装特权助手"
            return
        }
        guard !fans.isEmpty else { return }

        var msgs: [String] = []
        for fan in fans {
            let role = FanRole.from(index: fan.index)
            let ctrl = controls[role] ?? FanControl()
            let temp = temperature(for: ctrl.tempSource)

            // 驱动限制：本机 AsusFanSMC 下 fan1（GPU 风扇）一旦切到手动/曲线
            // （Md=1）就停转，只能固件自动（Md=0）。强行接管会让 GPU 风扇停掉、
            // 散热失控，所以这里强制交回固件并提示，避免误选导致停转。
            if role == .gpu && ctrl.mode != .auto {
                if lastManualState[fan.index] != false {
                    helper.setFanManual(fan.index, manual: false) { _, _ in }
                }
                lastManualState[fan.index] = false
                msgs.append("\(role.rawValue)：驱动不支持手动，已交回固件自动")
                continue
            }

            switch ctrl.mode {
            case .auto:
                if lastManualState[fan.index] != false {
                    helper.setFanManual(fan.index, manual: false) { _, _ in }
                }
                lastManualState[fan.index] = false
                msgs.append("\(role.rawValue)：固件自动")

            case .curve:
                guard let t = temp, t > 0 else {
                    // 没有有效温度 → 不接管，交回固件
                    if lastManualState[fan.index] != false {
                        helper.setFanManual(fan.index, manual: false) { _, _ in }
                    }
                    lastManualState[fan.index] = false
                    msgs.append("\(role.rawValue)：无温度→交回固件")
                    continue
                }
                let pct = ctrl.curve.percent(at: t)
                let rpm = fan.maxRPM * pct / 100
                helper.setFanTargetRPM(fan.index, rpm: rpm) { _, _ in }
                lastManualState[fan.index] = true
                msgs.append(String(format: "%@：曲线 %.0f%@→%.0f%%",
                                   role.rawValue, t, ctrl.tempSource.unit, pct))

            case .manual:
                let rpm = fan.maxRPM * ctrl.manualPercent / 100
                helper.setFanTargetRPM(fan.index, rpm: rpm) { _, _ in }
                lastManualState[fan.index] = true
                msgs.append(String(format: "%@：固定 %.0f%%", role.rawValue, ctrl.manualPercent))
            }
        }
        lastApplyMessage = msgs.joined(separator: "   ·   ")
    }

    func releaseFans() {
        for f in fans {
            helper.setFanManual(f.index, manual: false) { _, _ in }
            lastManualState[f.index] = false
        }
        lastApplyMessage = "已交回固件自动控制"
    }

    // MARK: 持久化

    private enum Key {
        static let controls = "fanControls"
        static let offset = "cpuTempOffset"
        static let boost = "boostEnabled"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(cpuTempOffset, forKey: Key.offset)
        // 字典（枚举键）手动转成 [String: FanControl] 再编码
        var dict: [String: FanControl] = [:]
        for (role, c) in controls { dict[role.rawValue] = c }
        if let data = try? JSONEncoder().encode(dict) {
            d.set(data, forKey: Key.controls)
        }
    }

    private func load() {
        let d = UserDefaults.standard

        // 先处理风扇配置（controls），再处理 offset：
        // 否则先动 cpuTempOffset 触发的 save() 会用「还没赋值的默认 controls」覆盖刚读到的配置。
        // 新格式：每把扇独立配置
        if let data = d.data(forKey: Key.controls),
           let dict = try? JSONDecoder().decode([String: FanControl].self, from: data) {
            var c: [FanRole: FanControl] = [:]
            for (k, v) in dict where FanRole(rawValue: k) != nil {
                c[FanRole(rawValue: k)!] = v
            }
            if c.count == FanRole.allCases.count { controls = c }
        }

        // 旧格式迁移：曾经是「全局一套」配置，平分给两把扇
        if controls.isEmpty,
           let m = d.string(forKey: "fanMode").flatMap({ FanMode(rawValue: $0) }) {
            let src = d.string(forKey: "tempSource").flatMap { TempSource(rawValue: $0) } ?? .gpu
            let mp = d.double(forKey: "manualPercent")
            let ctrl = FanControl(mode: m, tempSource: src, manualPercent: mp > 0 ? mp : 55,
                                 curve: .default(for: src))
            controls = [.cpu: ctrl, .gpu: ctrl]
        }

        // 只有用户确实设过才覆盖默认值（UserDefaults 没值时 double 返回 0，会误伤已存的 -13）
        if d.object(forKey: Key.offset) != nil { cpuTempOffset = d.double(forKey: Key.offset) }

        // 睿频模式：默认开启（跑满），仅当用户显式设过才覆盖
        if d.object(forKey: Key.boost) != nil { boostEnabled = d.bool(forKey: Key.boost) }
    }

    func resetCurve(_ role: FanRole) {
        var c = controls[role] ?? FanControl()
        c.resetCurveToDefault()
        controls[role] = c
    }
}
