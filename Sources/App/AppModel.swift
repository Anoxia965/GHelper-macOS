//
//  AppModel.swift — 全局状态与轮询
//

import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - 风扇能力档案（首次测绘后持久化，用于限速/稳态判定，避免写死本机转速）
/// 不同 AMD 黑苹果额定/实测满速各不相同，故首次安装后自动测绘并保存，
/// 之后限速默认值、强冷稳态判定、UI 显示都基于实测值，而不是硬编码 7300/7500 等。
struct FanProfile: Codable {
    var idleRPM: Double = 0          // 固件自动、低温下的空闲转速
    var measuredMaxRPM: Double = 0   // 拉满 WMNB 100% 后的稳态实测满速（真正可控上限）
    var ratedMaxRPM: Double = 0      // SMC F{i}Mx 额定（测绘时记录，仅供参考）
    var probedAt: Date = Date()
}

@MainActor
final class AppModel: ObservableObject, RGBBackend {

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

    // 温度走势（近 60 个采样，供监控页迷你折线）
    @Published var tempHistory: [Double] = []

    // CPU 每逻辑核心（线程）占用（0…100），长度 = 逻辑核数
    @Published var coreLoads: [Double] = []

    // WindowServer 瞬时占用（黑苹果无硬件加速时的 CPU 大户）
    @Published var windowServer = WindowServerStats()
    /// 近 60 次采样的 CPU% 走势，供监控页迷你折线
    @Published var windowServerHistory: [Double] = []
    /// 菜单栏是否改显示 WindowServer 占用（默认关，保持原有温度显示）
    @Published var showWindowServerInMenuBar: Bool = false {
        didSet { UserDefaults.standard.set(showWindowServerInMenuBar,
                                           forKey: Key.showWSInMenuBar) }
    }

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

    /// 强冷倒计时（秒）：某把扇已进入「稳态保持」阶段时，键为该角色、值为剩余秒数；未进入稳态（仍在拉满爬升）时该键不存在。
    @Published var turboRemaining: [FanRole: Int] = [:]
    /// 强冷爬升中标记：某把扇已触发强冷、但转速尚未到达稳态（仍在拉满爬升）时为 true。
    @Published var turboRamping: [FanRole: Bool] = [:]

    // 睿频模式：true=跑满（放开上限），false=锁默认频率（降温）。持久化，默认开启。
    @Published var boostEnabled: Bool = true {
        didSet { UserDefaults.standard.set(boostEnabled, forKey: Key.boost) }
    }

    /// 睿频开关的即时反馈（成功/失败都显示，解决「点了没反应」看不到结果的问题）
    @Published var boostStatus: String = ""

    /// 风扇能力档案（按物理索引）。首次测绘后填入，用于限速默认值与强冷稳态判定。
    @Published var fanProfiles: [Int: FanProfile] = [:] {
        didSet { saveProfiles() }
    }
    @Published var isProbingFans: Bool = false
    @Published var probingMessage: String = ""
    private var idleSnapshot: [Int: Double] = [:]

    // MARK: 键盘灯光（Aura USB）

    let aura = AuraController()
    @Published var auraAvailable: Bool = false
    @Published var auraStatus: String = "未检测"

    @Published var auraMode: AuraMode = .staticColor {
        didSet { saveLighting(); applyLighting() }
    }
    @Published var auraColor = Color(rgb: 0x1D9E75) {
        didSet { saveLighting(); applyLighting() }
    }
    @Published var auraColor2 = Color(rgb: 0x5DCAA5) {
        didSet { saveLighting(); applyLighting() }
    }
    /// 四区颜色（FA607 为四区 RGB 键盘）
    @Published var auraZones: [Color] = [
        Color(rgb: 0x1D9E75), Color(rgb: 0x5DCAA5),
        Color(rgb: 0xE0A23A), Color(rgb: 0xD9544B)
    ] {
        didSet { saveLighting(); applyLighting() }
    }
    @Published var auraBrightness: Int = 2 {
        didSet { saveLighting(); applyLighting() }
    }
    @Published var auraSpeed: Int = 2 {
        didSet { saveLighting(); applyLighting() }
    }
    @Published var auraPerZone: Bool = false {
        didSet { saveLighting(); applyLighting() }
    }

    /// Color → RRGGBB 整数（持久化用）
    private func hex(of color: Color) -> UInt32 {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
        let r = UInt32(min(1, max(0, ns.redComponent)) * 255)
        let g = UInt32(min(1, max(0, ns.greenComponent)) * 255)
        let b = UInt32(min(1, max(0, ns.blueComponent)) * 255)
        return (r << 16) | (g << 8) | b
    }
    private func rgbTuple(_ color: Color) -> RGB {
        let h = hex(of: color)
        return RGB(r: UInt8((h >> 16) & 0xFF), g: UInt8((h >> 8) & 0xFF), b: UInt8(h & 0xFF))
    }

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
    private let coreMonitor = CoreMonitor()
    /// WindowServer 采样在监控类内部走后台串行队列，不卡主线程
    private let windowServerMonitor = WindowServerMonitor()
    private var pollTimer: Timer?
    private var fanTimer: Timer?
    private var freqTimer: Timer?
    private var turboTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// SMCAMDProcessor 装好后可能出现的 CPU 温度键
    private static let cpuTempKeys = ["TC0P", "TC1P", "TC0D", "TC0E", "TC0F",
                                      "TC0J", "TCTL", "TCPU", "TC0C"]

    init() {
        // 必须在调用任何 self 方法之前给 let 赋值
        corePairing = CorePairing.detect(from: Machine.cpu)
        load()
        do { try smc.open() } catch { NSLog("SMC 打开失败: \(error)") }
        detectCPUTempKey()
        refresh()
        helper.refreshStatus()
        loadHardware()
        aura.backend = self
        refreshAura()

        // helper 的 @Published 变化转发给 model，驱动 UI 立即刷新（状态点/睿频前置等）
        helper.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // helper.isInstalled 是异步 ping 回来的；它变 true 后刷新灯光可用性，
        // 否则 auraAvailable 一直是 false → 灯光按钮灰掉、点不动（“控制没反应”）。
        helper.$isInstalled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAura()
                self?.scheduleProbeIfNeeded()
            }
            .store(in: &cancellables)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
            self?.sampleWindowServer()
        }
        // 立刻采一次基线，这样第二个 1.5s 周期就能出瞬时值
        sampleWindowServer()
        fanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyNow() }
        }
        freqTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFrequency() }
        }
        // 强冷：每秒检测转速是否到达稳态；稳态后保持 30 秒再回落
        turboTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let now = Date()
                var anyExpired = false
                var remaining: [FanRole: Int] = [:]
                var ramping: [FanRole: Bool] = [:]

                // ── 双扇强冷协调：两把扇互相等到都稳态，再统一一起开始 30 秒倒计时 ──
                if self.turboAllActive {
                    for r in FanRole.allCases { self.tickTurboRamp(r, now: now) }
                    let cpuSteady = self.turboSteadyAt[.cpu] != nil
                    let gpuSteady = self.turboSteadyAt[.gpu] != nil
                    // 互等等待保护：两扇都已拉满爬升超 70s（某扇物理上爬不到真正满速），
                    // 强制认定都到顶，一起进入保持阶段，避免一扇先到、另一扇慢而干等过久。
                    let cpuOver = (now.timeIntervalSince(self.turboStartAt[.cpu] ?? now) > 70)
                    let gpuOver  = (now.timeIntervalSince(self.turboStartAt[.gpu] ?? now) > 70)
                    if cpuSteady && gpuSteady {
                        if self.turboAllSteadyAt == nil { self.turboAllSteadyAt = now }
                    } else if cpuOver && gpuOver {
                        if self.turboSteadyAt[.cpu] == nil { self.turboSteadyAt[.cpu] = now }
                        if self.turboSteadyAt[.gpu] == nil { self.turboSteadyAt[.gpu] = now }
                        if self.turboAllSteadyAt == nil { self.turboAllSteadyAt = now }
                    }
                    if let allSteadyAt = self.turboAllSteadyAt {
                        let dropAt = allSteadyAt.addingTimeInterval(30)
                        if now >= dropAt {
                            for r in FanRole.allCases { self.clearTurbo(r) }
                            self.turboAllActive = false
                            self.turboAllSteadyAt = nil
                            anyExpired = true
                        } else {
                            let rem = Int(ceil(dropAt.timeIntervalSinceNow))
                            for r in FanRole.allCases { remaining[r] = rem; ramping[r] = false }
                        }
                    } else {
                        // 还没都稳态：两扇都显示「互等等待中」
                        for r in FanRole.allCases { ramping[r] = true }
                    }
                    self.turboRemaining = remaining
                    self.turboRamping = ramping
                    if anyExpired { self.applyNow() }
                    return
                }

                // ── 单扇强冷：各自判定稳态、各自 30 秒倒计时 ──
                for role in FanRole.allCases {
                    guard self.isTurboActive(role) else { continue }
                    self.tickTurboRamp(role, now: now)

                    if let steadyAt = self.turboSteadyAt[role] {
                        let dropAt = steadyAt.addingTimeInterval(30)
                        if now >= dropAt {
                            self.clearTurbo(role)
                            anyExpired = true
                        } else {
                            remaining[role] = Int(ceil(dropAt.timeIntervalSinceNow))
                        }
                    } else {
                        ramping[role] = true
                    }
                }
                self.turboRemaining = remaining
                self.turboRamping = ramping
                if anyExpired { self.applyNow() }
            }
        }

        // 启动后按已存偏好重涂睿频模式（助手装好才生效）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.applyBoostOnLaunch()
        }
        loadProfiles()
        // 首次启动（无档案）且助手就绪时，自动测绘一次风扇能力，用于后续限速/稳态判定。
        // 用 scheduleProbeIfNeeded：条件未就绪会自动重试，避免一次性竞态导致永久跳过。
        scheduleProbeIfNeeded()
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

    // MARK: 键盘灯光

    /// 重新检测 Aura 控制器（实际 = root 助手是否就位，kext 由 rgbctl 在应用时校验）
    func refreshAura() {
        aura.backend = self
        aura.refresh()                 // 设 aura.available = (backend != nil) → true，否则 applyLighting 的 guard 直接 return
        auraAvailable = helper.isInstalled
        auraStatus = aura.statusMessage
    }

    /// 把当前偏好下发到键盘（控制器不可用则跳过）
    func applyLighting() {
        guard aura.available else {
            auraStatus = aura.statusMessage
            return
        }
        aura.apply(mode: auraMode, color: rgbTuple(auraColor), color2: rgbTuple(auraColor2),
                   brightness: auraBrightness, speed: auraSpeed, perZone: auraPerZone,
                   zones: auraZones.map { rgbTuple($0) })
        auraAvailable = aura.available
        auraStatus = aura.lastApplied
    }

    /// 关闭键盘灯
    func turnOffLighting() {
        aura.turnOff()
        auraAvailable = aura.available
        auraStatus = aura.lastApplied
    }

    // MARK: RGBBackend（灯光经 root 助手下发）

    func rgbSet(r: UInt8, g: UInt8, b: UInt8, mode: UInt8, brightness: Int, speed: Int) {
        guard helper.isInstalled else {
            auraStatus = "需先安装特权助手"
            return
        }
        helper.applyKeyboardLighting(r: Int(r), g: Int(g), b: Int(b),
                                    mode: Int(mode), brightness: brightness, speed: speed) {
            [weak self] ok, msg in
            Task { @MainActor in
                guard let self else { return }
                self.auraStatus = ok ? "✓ \(msg)" : "✗ \(msg)"
            }
        }
    }

    func rgbTurnOff() {
        guard helper.isInstalled else {
            auraStatus = "需先安装特权助手"
            return
        }
        helper.applyKeyboardLighting(r: 0, g: 0, b: 0, mode: 0, brightness: 0, speed: 0) {
            [weak self] ok, msg in
            Task { @MainActor in
                guard let self else { return }
                self.auraStatus = ok ? "✓ \(msg)" : "✗ \(msg)"
            }
        }
    }

    /// 菜单栏标题：优先 GPU 温度，没有就退化成 CPU 占用
    var menuBarTitle: String {
        // 可选：直接在菜单栏看 WindowServer 占用（无读数时退回温度）
        if showWindowServerInMenuBar, windowServer.available {
            return String(format: "WS %.0f%%", windowServer.cpuPercent)
        }
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
        coreLoads = coreMonitor.sample()
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

        // 温度走势缓冲（近 60 点）
        if let t = cpuTemperature {
            tempHistory.append(t)
        } else if let last = tempHistory.last {
            tempHistory.append(last)
        }
        if tempHistory.count > 60 { tempHistory.removeFirst() }
    }

    /// 当前主温度（优先 CPU，其次 GPU），走势图/状态共用
    var primaryTemperature: Double? { cpuTemperature ?? gpuTemperature }

    /// 逻辑线程网格的配对方式（Intel HT 交错 / AMD SMT 分半）。
    /// ⚠️ 必须在 init 里算好存成常量：曾在视图 body 里实时计算（读 lazily 初始化的
    /// `Machine.cpu`，其内部 spawn 进程），AttributeGraph 持锁期间触发
    /// libdispatch 「trying to lock recursively」→ SIGILL 崩溃（2026-11-09 抓到）。
    let corePairing: CorePairing

    /// 核心网格摘要：峰值、平均、高载线程数
    var coreSummary: (peak: Double, average: Double, busy: Int, total: Int) {
        let loads = coreLoads
        guard !loads.isEmpty else { return (0, 0, 0, 0) }
        return (loads.max() ?? 0,
                loads.reduce(0, +) / Double(loads.count),
                loads.filter { $0 >= 55 }.count,
                loads.count)
    }

    /// WindowServer 瞬时 CPU / 内存采样（后台执行，结果回主线程更新）
    private func sampleWindowServer() {
        windowServerMonitor.sampleAsync { [weak self] stats in
            Task { @MainActor in
                guard let self else { return }
                self.windowServer = stats
                if stats.available {
                    self.windowServerHistory.append(stats.cpuPercent)
                    if self.windowServerHistory.count > 60 {
                        self.windowServerHistory.removeFirst()
                    }
                }
            }
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
    /// 上一次已上传到固件的曲线哈希（仅变化时才重新下发，避免每 3s 刷 EC）
    private var lastCurveHash: [Int: Int] = [:]
    /// WMNB 通道是否可用。首次探测失败后置 false，之后曲线/手动模式直接走 SMC 兜底，
    /// 不再反复尝试 WMNB（也避免刷失败日志）。App 重启（如重启后）会重新探测。
    private var wmnbAvailable: Bool = true

    /// 强冷状态（按角色）：
    /// - turboRampingState 为 true 表示已触发、转速正在拉满爬升（尚未稳态）；
    /// - turboSteadyAt 非空表示已到达稳态，从此时刻起再保持 30 秒后回落；
    /// - turboSteadyCount / turboLastRPM 用于稳态判定（转速连续若干采样基本不变即视为稳态）；
    /// - turboStartAt 用于安全上限（爬升超 120s 仍未判定稳态则强制进入保持阶段）。
    private var turboRampingState: [FanRole: Bool] = [:]
    private var turboSteadyAt: [FanRole: Date] = [:]
    private var turboSteadyCount: [FanRole: Int] = [:]
    private var turboLastRPM: [FanRole: Double] = [:]
    private var turboStartAt: [FanRole: Date] = [:]
    /// 双扇强冷协调：两把扇互相等到都稳态后，再统一一起开始 30 秒倒计时
    @Published var turboAllActive: Bool = false
    private var turboAllSteadyAt: Date? = nil
    /// 该扇强冷是否走 SMC 目标转速通道。⚠️ 已弃用：现两扇强冷都走 WMNB 100% 平曲线（SMC 目标通道 F0 实测只到 7300 且会连带停转另一扇），此字段恒为 false。
    /// 退出强冷时需据此把 SMC 手动标志清回固件自动。
    private var turboSMC: [FanRole: Bool] = [:]

    // WMNB 风扇曲线 devid：0x00110024=CPU 风扇 / 0x00110025=GPU 风扇（asus-wmi 同款）
    private static let wmnbDevidCPU: UInt32 = 0x00110024
    private static let wmnbDevidGPU: UInt32 = 0x00110025

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
            let devid: UInt32 = (role == .cpu) ? Self.wmnbDevidCPU : Self.wmnbDevidGPU
            let temp = temperature(for: ctrl.tempSource)

            // ── 强冷模式：两把扇都走 WMNB 100% 平曲线冲满速（额定上限 F0Mx=7800 / F1Mx=7600），
            //    到达满速后保持 30 秒，期间绕过限速；时间到自动回落 ──
            // ⚠️ 绝不能用 SMC 手动（setFanManual + 目标转速）：本机实测 F0 走 SMC 目标 7800 只会稳到 7300，
            //    且任一扇设为 SMC 手动都会连带把另一把扇搞停（F1 掉到 0）。WMNB 曲线通道两扇都能安全冲到额定附近。
            if isTurboActive(role) {
                let flat = flatCurve(100, base: ctrl.curve)
                let packed = packCurve(flat)
                if lastCurveHash[fan.index] != packed.hash {
                    if wmnbAvailable {
                        helper.setFanCurve(fan.index, devid: devid,
                                           a1: packed.a1, a2: packed.a2,
                                           a3: packed.a3, a4: packed.a4) { [weak self] ok, _ in
                            guard let self else { return }
                            if !ok { self.wmnbAvailable = false }
                        }
                    }
                    // WMNB 通道不可用时不做兜底强冷（避免退回 SMC 手动把另一把扇搞停），静默降级。
                    lastCurveHash[fan.index] = packed.hash
                }
                turboSMC[role] = false
                helper.keepFanAlive(fan.index) { _, _ in }
                lastManualState[fan.index] = true
                // 回落倒计时：已进入稳态则按「稳态时刻 + 30s」算剩余；仍在拉满爬升则标「拉满中」
                if let steadyAt = turboSteadyAt[role] {
                    let remain = max(0, Int(ceil(steadyAt.addingTimeInterval(30).timeIntervalSinceNow)))
                    turboRemaining[role] = remain
                    msgs.append(String(format: "%@：强冷中 (满速 %d秒)", role.rawValue, remain))
                } else {
                    msgs.append(String(format: "%@：强冷中 (拉满爬升)", role.rawValue))
                }
                continue
            }

            switch ctrl.mode {
            case .auto:
                if lastManualState[fan.index] != false {
                    helper.releaseFanCurve(fan.index) { _, _ in }
                }
                lastManualState[fan.index] = false
                lastCurveHash[fan.index] = nil
                msgs.append("\(role.rawValue)：固件自动")

            case .curve:
                guard let t = temp, t > 0 else {
                    // 没有有效温度 → 不接管，交回固件（安全底线）
                    if lastManualState[fan.index] != false {
                        helper.releaseFanCurve(fan.index) { _, _ in }
                    }
                    lastManualState[fan.index] = false
                    msgs.append("\(role.rawValue)：无温度→交回固件")
                    continue
                }
                // 限制最高转速：把整条曲线（含当前温点插值）按 SMC 额定 maxRPM 换算的占空比封顶
                let (capDuty, limitRPM) = rpmCap(for: ctrl, role: role, maxRPM: fan.maxRPM)
                var sendCurve = ctrl.curve
                var pctAtTemp = ctrl.curve.percent(at: t)
                if let cap = capDuty {
                    sendCurve.points = sendCurve.points.map { p in
                        var q = p; q.percent = min(q.percent, cap); return q
                    }
                    pctAtTemp = min(pctAtTemp, cap)
                }
                let packed = packCurve(sendCurve)
                if lastCurveHash[fan.index] != packed.hash {
                    if wmnbAvailable {
                        helper.setFanCurve(fan.index, devid: devid,
                                           a1: packed.a1, a2: packed.a2,
                                           a3: packed.a3, a4: packed.a4) { [weak self] ok, _ in
                            guard let self else { return }
                            if ok {
                                self.wmnbAvailable = true
                            } else {
                                // WMNB 不可用（驱动未加载/工具缺失）→ 退回 SMC 单点目标转速
                                self.wmnbAvailable = false
                                self.helper.setFanManual(fan.index, manual: true) { _, _ in }
                                self.helper.setFanTargetRPM(fan.index,
                                    rpm: fan.maxRPM * pctAtTemp / 100) { _, _ in }
                            }
                        }
                    } else {
                        // 已知 WMNB 通道不可用：直接走 SMC，不再反复探测
                        helper.setFanManual(fan.index, manual: true) { _, _ in }
                        helper.setFanTargetRPM(fan.index,
                            rpm: fan.maxRPM * pctAtTemp / 100) { _, _ in }
                    }
                    lastCurveHash[fan.index] = packed.hash
                }
                lastManualState[fan.index] = true
                helper.keepFanAlive(fan.index) { _, _ in }
                if let lim = limitRPM {
                    msgs.append(String(format: "%@：曲线接管 (%.0f%% ≤%.0fRPM)",
                                       role.rawValue, pctAtTemp, lim))
                } else {
                    msgs.append(String(format: "%@：曲线接管 (%.0f%@ 约 %.0f%%)",
                                       role.rawValue, t, ctrl.tempSource.unit, ctrl.curve.percent(at: t)))
                }

            case .manual:
                // 固定转速：做成「全平曲线」走 WMNB（与曲线模式统一通道）
                let (capDuty, limitRPM) = rpmCap(for: ctrl, role: role, maxRPM: fan.maxRPM)
                let target: Double = (capDuty != nil) ? min(ctrl.manualPercent, capDuty!) : ctrl.manualPercent
                let flat = flatCurve(target, base: ctrl.curve)
                let packed = packCurve(flat)
                if lastCurveHash[fan.index] != packed.hash {
                    if wmnbAvailable {
                        helper.setFanCurve(fan.index, devid: devid,
                                           a1: packed.a1, a2: packed.a2,
                                           a3: packed.a3, a4: packed.a4) { [weak self] ok, _ in
                            guard let self else { return }
                            if ok {
                                self.wmnbAvailable = true
                            } else {
                                self.wmnbAvailable = false
                                self.helper.setFanManual(fan.index, manual: true) { _, _ in }
                                self.helper.setFanTargetRPM(fan.index,
                                    rpm: fan.maxRPM * target / 100) { _, _ in }
                            }
                        }
                    } else {
                        // 已知 WMNB 通道不可用：直接走 SMC，不再反复探测
                        helper.setFanManual(fan.index, manual: true) { _, _ in }
                        helper.setFanTargetRPM(fan.index,
                            rpm: fan.maxRPM * target / 100) { _, _ in }
                    }
                    lastCurveHash[fan.index] = packed.hash
                }
                lastManualState[fan.index] = true
                helper.keepFanAlive(fan.index) { _, _ in }
                if let lim = limitRPM {
                    msgs.append(String(format: "%@：固定 %.0f%% (≤%.0fRPM)", role.rawValue, target, lim))
                } else {
                    msgs.append(String(format: "%@：固定 %.0f%%", role.rawValue, ctrl.manualPercent))
                }
            }
        }
        lastApplyMessage = msgs.joined(separator: "   ·   ")
    }

    /// 把 8 点曲线打包成 asus-wmi 的 4 个 DWORD（温度 / 占空比各 4 字节）。
    /// 占空比按固件原生 0–255 缩放：byte = round(percent * 255 / 100)（与华硕 PWM 接口一致）。
    private struct PackedCurve { let a1, a2, a3, a4: UInt32; let hash: Int }

    private func packCurve(_ curve: FanCurve) -> PackedCurve {
        let sorted = curve.points.sorted { $0.temperature < $1.temperature }
        var temps: [UInt8] = [], duties: [UInt8] = []
        for p in sorted.prefix(8) {
            // 温度按 °C 直接取整（0–255 字节足够）
            let t = UInt8(min(255, max(0, Int(p.temperature.rounded()))))
            // ⚠️ 占空比是固件风扇曲线约定：0–100 百分比，不是 0–255（与华硕原始 PWM 不同）。
            // 实测本机出厂曲线占空比即 [1…90]%，写 255 制会被固件夹到满速。
            let d = UInt8(min(100, max(0, Int(p.percent.rounded()))))
            temps.append(t); duties.append(d)
        }
        while temps.count < 8 { temps.append(0); duties.append(0) }
        let pack: (UInt8, UInt8, UInt8, UInt8) -> UInt32 = { b0, b1, b2, b3 in
            UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
        }
        let a1 = pack(temps[0], temps[1], temps[2], temps[3])
        let a2 = pack(temps[4], temps[5], temps[6], temps[7])
        let a3 = pack(duties[0], duties[1], duties[2], duties[3])
        let a4 = pack(duties[4], duties[5], duties[6], duties[7])
        let hash = Int(a1) ^ (Int(a2) &* 31) ^ (Int(a3) &* 17) ^ (Int(a4) &* 7)
        return PackedCurve(a1: a1, a2: a2, a3: a3, a4: a4, hash: hash)
    }

    /// 用 base 曲线的温度点、平铺成固定占空比的曲线（固定转速模式走 WMNB）
    private func flatCurve(_ percent: Double, base: FanCurve) -> FanCurve {
        var c = base
        c.points = base.points.map { CurvePoint(temperature: $0.temperature, percent: percent) }
        c.floorPercent = percent
        return c
    }

    /// 限制最高转速：开启时按 SMC 额定 maxRPM(F{i}Mx) 把 RPM 上限换算成占空比封顶。
    /// 返回 (占空比上限?, 转速上限?)；未开启或拿不到 maxRPM 时返回 (nil, nil)。
    /// 限速默认值（用户开了「限制最高转速」但未手填）：优先本机实测满速；
    /// 读不到实测则退回额定 80%，再不行用通用兜底 7500/7000。
    func defaultRpmLimit(for role: FanRole) -> Double {
        let idx = role == .cpu ? 0 : 1
        if let p = fanProfiles[idx], p.measuredMaxRPM > 0 {
            return p.measuredMaxRPM            // 实测满速即真正上限，封顶≈不限制（与原 7500 语义一致）
        }
        let maxRPM = fans.first { FanRole.from(index: $0.index) == role }?.maxRPM ?? 0
        return maxRPM > 0 ? maxRPM * 0.8 : (role == .cpu ? 7500 : 7000)
    }

    /// 限制最高转速：开启时把实际转速压在 rpmLimit 以下（按 SMC 额定 maxRPM 换算成占空比封顶）。
    /// 返回 (占空比上限?, 转速上限?)；未开启或拿不到 maxRPM 时返回 (nil, nil)。
    private func rpmCap(for ctrl: FanControl, role: FanRole, maxRPM: Double) -> (Double?, Double?) {
        guard ctrl.rpmLimitEnabled, maxRPM > 0 else { return (nil, nil) }
        let limit = ctrl.rpmLimit > 0 ? ctrl.rpmLimit : defaultRpmLimit(for: role)
        let duty = min(100, max(0, limit / maxRPM * 100 * 0.97))
        return (duty, limit)
    }

    // MARK: 风扇能力测绘（首次自动，结果持久化用于限速/稳态判定）

    /// 自动触发：助手已装且版本匹配、无档案、有风扇时测绘一次。
    /// 首次测绘的可靠触发：条件（助手就绪 + 风扇列表已填充）满足才跑，
    /// 否则每 5 秒重试（最多 12 次 ≈ 60s），避免一次性 4s 竞态导致永久跳过。
    private var probeRetryCount = 0
    func scheduleProbeIfNeeded() {
        guard fanProfiles.isEmpty, !isProbingFans else { return }
        maybeAutoProbe()
        if fanProfiles.isEmpty, probeRetryCount < 12 {
            probeRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.scheduleProbeIfNeeded()
            }
        }
    }

    func maybeAutoProbe() {
        guard fanProfiles.isEmpty else { return }
        guard helper.isInstalled, !helper.helperOutdated else { return }
        guard !fans.isEmpty else { return }
        probeFans()
    }

    /// 测绘每台风扇：先交回固件自动采集空闲转速，再拉满 WMNB 100% 直到稳态，
    /// 记录实测满速与额定，持久化。测绘后交回固件自动（看门狗兜底）。
    /// 兼容性：部分机型（如本机 GPU 风扇）手动/曲线接管即停转，命令 100% 却读到 0；
    /// 此时提前释放该扇并兜底用额定值，既不让风扇长时间停转，也给限速一个合理上限。
    func probeFans() {
        guard helper.isInstalled, !fans.isEmpty else { return }
        guard !isProbingFans else { return }
        isProbingFans = true
        probingMessage = "正在测绘风扇转速…"
        Task {
            // 1) 交回固件自动，采集真实空闲转速
            for f in fans { helper.releaseFanCurve(f.index) { _, _ in } }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let idleNow = readFans(smc: smc)
            var idle: [Int: Double] = [:]
            for f in idleNow { idle[f.index] = f.actualRPM }

            // 2) 双扇同时拉满
            for f in fans {
                let devid: UInt32 = (FanRole.from(index: f.index) == .cpu) ? Self.wmnbDevidCPU : Self.wmnbDevidGPU
                let packed = self.packCurve(self.flatCurve(100, base: .default(for: .gpu)))
                helper.setFanCurve(f.index, devid: devid,
                                  a1: packed.a1, a2: packed.a2, a3: packed.a3, a4: packed.a4) { _, _ in }
                helper.keepFanAlive(f.index) { _, _ in }
            }

            // 3) 轮询稳态（每扇独立判定；停转的扇提前释放并记额定值）
            var stableCount: [Int: Int] = [:]
            var lastRPM: [Int: Double] = [:]
            var zeroCount: [Int: Int] = [:]
            var released: Set<Int> = []
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = readFans(smc: smc)
                var allStable = true
                for f in fans {
                    if released.contains(f.index) { continue }
                    let rpm = now.first(where: { $0.index == f.index })?.actualRPM ?? 0
                    // 命令 100% 却读到 ~0：判定为「手动接管即停转」，提前释放并记额定值
                    if rpm == 0 || rpm <= (idle[f.index] ?? 0) * 0.5 {
                        zeroCount[f.index] = (zeroCount[f.index] ?? 0) + 1
                        if (zeroCount[f.index] ?? 0) >= 3 {
                            helper.releaseFanCurve(f.index) { _, _ in }
                            released.insert(f.index)
                            lastRPM[f.index] = f.maxRPM > 0 ? f.maxRPM : (idle[f.index] ?? 0)
                            continue
                        }
                    } else {
                        zeroCount[f.index] = 0
                    }
                    let cap0 = (fanProfiles[f.index]?.measuredMaxRPM ?? 0) > 0
                        ? fanProfiles[f.index]!.measuredMaxRPM : (f.maxRPM > 0 ? f.maxRPM : rpm)
                    let line = max(8.0, 0.003 * cap0)
                    if let last = lastRPM[f.index], abs(rpm - last) > line {
                        stableCount[f.index] = 0
                        allStable = false
                    } else {
                        stableCount[f.index] = (stableCount[f.index] ?? 0) + 1
                    }
                    lastRPM[f.index] = rpm
                    if (stableCount[f.index] ?? 0) < 5 { allStable = false }
                }
                self.probingMessage = "正在测绘风扇转速… 已稳定 \(stableCount.values.min() ?? 0)/5"
                if allStable { break }
            }

            // 4) 记录档案并交回固件自动
            var profiles = self.fanProfiles
            let final = readFans(smc: smc)
            for f in fans {
                let measured = lastRPM[f.index]
                    ?? (final.first(where: { $0.index == f.index })?.actualRPM ?? 0)
                // 实测值不可信（≤空闲）时兜底用额定值，保证限速上限合理
                let safe = (measured > (idle[f.index] ?? 0)) ? measured
                    : (f.maxRPM > 0 ? f.maxRPM : (idle[f.index] ?? 0))
                profiles[f.index] = FanProfile(
                    idleRPM: idle[f.index] ?? 0,
                    measuredMaxRPM: safe,
                    ratedMaxRPM: f.maxRPM,
                    probedAt: Date())
                if !released.contains(f.index) {
                    helper.releaseFanCurve(f.index) { _, _ in }
                }
            }
            self.fanProfiles = profiles
            self.isProbingFans = false
            let cpu = profiles[0].map { "CPU 满速 \(Int($0.measuredMaxRPM))" } ?? ""
            let gpu = profiles[1].map { "GPU 满速 \(Int($0.measuredMaxRPM))" } ?? ""
            self.probingMessage = "风扇测绘完成（\(cpu) · \(gpu) RPM）已用于限速与强冷判定"
        }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "fanProfiles"),
              let d = try? JSONDecoder().decode([String: FanProfile].self, from: data) else { return }
        var m: [Int: FanProfile] = [:]
        for (k, v) in d { if let i = Int(k) { m[i] = v } }
        fanProfiles = m
    }

    private func saveProfiles() {
        let d = fanProfiles.reduce(into: [String: FanProfile]()) { $0[String($1.key)] = $1.value }
        if let data = try? JSONEncoder().encode(d) {
            UserDefaults.standard.set(data, forKey: "fanProfiles")
        }
    }

    func releaseFans() {
        for f in fans {
            helper.releaseFanCurve(f.index) { _, _ in }
            lastManualState[f.index] = false
            lastCurveHash[f.index] = nil
        }
        lastApplyMessage = "已交回固件自动控制"
    }

    // MARK: 强冷（强制满速 → 稳态后保持 30 秒）

    /// 某把扇是否处于强冷进行中（拉满爬升中，或稳态保持倒计时中）
    private func isTurboActive(_ role: FanRole) -> Bool {
        if turboRampingState[role] == true { return true }
        if let steadyAt = turboSteadyAt[role] {
            return Date() < steadyAt.addingTimeInterval(30)
        }
        return false
    }

    /// 清除某把扇的强冷状态（内部）。若该扇强冷走的是 SMC 目标转速通道（CPU），
    /// 退出时把 SMC 手动标志清回固件自动，避免风扇卡在手动目标转速。
    private func clearTurbo(_ role: FanRole) {
        if turboSMC[role] == true {
            if let fan = fans.first(where: { FanRole.from(index: $0.index) == role }) {
                helper.setFanManual(fan.index, manual: false) { _, _ in }
            }
        }
        turboRampingState.removeValue(forKey: role)
        turboSteadyAt.removeValue(forKey: role)
        turboSteadyCount.removeValue(forKey: role)
        turboLastRPM.removeValue(forKey: role)
        turboSMC.removeValue(forKey: role)
    }

    /// 对单扇做一次稳态检测（每秒定时器调用）。仅在「仍在拉满爬升」的扇上生效：
    /// 判定「到达满转速」＝已接近额定顶速（≥85%）且基本不再爬升。
    /// 关键：只达到某百分比、但仍在明显爬升时绝不算稳态——否则会在半路提前开始 30s 倒计时，
    ///       风扇还没冲到顶速（CPU 实测约 7300 / GPU 实测约 7500，均经 WMNB 100% 占空比）就回落，表现为「上不去满速」。
    /// 风扇冲到顶后会自然停爬，那一刻才判稳态，30s 保持阶段整段都钉在满速。
    /// 连续 3 次采样即判定稳态；maxRPM>0 守卫（额定读不到时绝不退化成 actual>0 即判定）。
    /// 安全上限 90s：爬升超 90s 仍未判定稳态，强制进入保持阶段。
    private func tickTurboRamp(_ role: FanRole, now: Date) {
        guard turboRampingState[role] == true else { return }
        let fan = fans.first { FanRole.from(index: $0.index) == role }
        let actual = fan?.actualRPM ?? 0
        let ratedMax = fan?.maxRPM ?? 0
        // 稳态判定优先用「本机实测满速」（档案）：本机 CPU 额定 7800 但实测仅 ~7300，
        // 用额定会提前误判满速；读不到实测才退回额定。
        let measured = fan.flatMap { fanProfiles[$0.index]?.measuredMaxRPM } ?? 0
        let cap = measured > 0 ? measured : ratedMax
        let last = turboLastRPM[role] ?? 0
        // 爬升判定线：本扇转速仍在明显上涨（超过该线）即视为「还在爬升」，绝不能算稳态。
        // 取绝对 8 RPM 与相对 0.3% 上限二者的较大值，把慢速爬升（每秒仍涨几十 RPM）排除在稳态之外。
        let climbLine = max(8.0, 0.003 * (cap > 0 ? cap : ratedMax))
        let stillClimbing = actual > last + climbLine
        // 稳态 = 已接近顶速（≥85%）且基本不再爬升。只达到百分比但仍在明显爬升时绝不算稳态。
        // 风扇冲到各自顶速（取本机实测满速）后会自然停爬，那一刻才判稳态。
        let steady = cap > 0 && actual >= 0.85 * cap && !stillClimbing
        if steady {
            turboSteadyCount[role] = (turboSteadyCount[role] ?? 0) + 1
        } else {
            turboSteadyCount[role] = 0
        }
        turboLastRPM[role] = actual
        if (turboSteadyCount[role] ?? 0) >= 3 {
            turboSteadyAt[role] = now
            turboRampingState[role] = false
        } else if now.timeIntervalSince(turboStartAt[role] ?? now) > 90 {
            turboSteadyAt[role] = now
            turboRampingState[role] = false
        }
    }

    /// 触发强冷：立即把该扇拉到各自软件可控顶速（两扇均经 WMNB 100% 占空比冲满：CPU 实测约 7300 / GPU 实测约 7500，额定分别为 7800 / 7600），
    /// 待转速到达满速（或物理顶速）后保持 30 秒再回落。
    /// 回落时若该扇开启「限制最高转速」则停在限制值，否则回到其当前模式（固件自动 / 曲线 / 固定）。
    func triggerTurbo(_ role: FanRole) {
        turboRampingState[role] = true
        turboSteadyAt.removeValue(forKey: role)
        turboSteadyCount[role] = 0
        turboLastRPM[role] = 0
        turboStartAt[role] = Date()
        turboRamping[role] = true
        turboRemaining.removeValue(forKey: role)
        turboSMC.removeValue(forKey: role)
        applyNow()
    }

    /// 双扇同时强冷：两把扇同时拉满，互相等到都到达稳态（或都尽力到顶）后，再统一一起保持 30 秒。
    func triggerTurboAll() {
        turboAllActive = true
        turboAllSteadyAt = nil
        for role in FanRole.allCases { triggerTurbo(role) }
    }

    /// 取消某把扇未结束的强冷（立即回落到正常模式）
    func cancelTurbo(_ role: FanRole) {
        clearTurbo(role)
        turboRamping.removeValue(forKey: role)
        turboRemaining.removeValue(forKey: role)
        // 单扇取消时也退出双扇协调态（若正处于双扇强冷）
        if turboAllActive {
            turboAllActive = false
            turboAllSteadyAt = nil
        }
        applyNow()
    }

    /// 取消全部强冷（双扇按钮用）
    func cancelTurboAll() {
        for role in FanRole.allCases { clearTurbo(role) }
        turboRamping.removeValue(forKey: .cpu)
        turboRamping.removeValue(forKey: .gpu)
        turboRemaining.removeValue(forKey: .cpu)
        turboRemaining.removeValue(forKey: .gpu)
        turboAllActive = false
        turboAllSteadyAt = nil
        applyNow()
    }

    // MARK: 持久化

    private enum Key {
        static let controls = "fanControls"
        static let offset = "cpuTempOffset"
        static let boost = "boostEnabled"
        static let auraMode = "auraMode"
        static let auraColor = "auraColor"
        static let auraColor2 = "auraColor2"
        static let auraZones = "auraZones"
        static let auraBrightness = "auraBrightness"
        static let auraSpeed = "auraSpeed"
        static let auraPerZone = "auraPerZone"
        static let showWSInMenuBar = "showWindowServerInMenuBar"
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
        saveLighting()
    }

    private func saveLighting() {
        let d = UserDefaults.standard
        d.set(auraMode.rawValue, forKey: Key.auraMode)
        d.set(Int(hex(of: auraColor)), forKey: Key.auraColor)
        d.set(Int(hex(of: auraColor2)), forKey: Key.auraColor2)
        let z = auraZones.prefix(4).map { Int(hex(of: $0)) }
        d.set(z, forKey: Key.auraZones)
        d.set(auraBrightness, forKey: Key.auraBrightness)
        d.set(auraSpeed, forKey: Key.auraSpeed)
        d.set(auraPerZone, forKey: Key.auraPerZone)
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

        // 菜单栏显示 WindowServer：默认关闭，仅用户显式设过才覆盖
        if d.object(forKey: Key.showWSInMenuBar) != nil {
            showWindowServerInMenuBar = d.bool(forKey: Key.showWSInMenuBar)
        }

        // 键盘灯光：仅当用户确实设过才覆盖默认值
        if let m = d.string(forKey: Key.auraMode), let am = AuraMode(rawValue: m) { auraMode = am }
        if d.object(forKey: Key.auraColor) != nil {
            auraColor = Color(rgb: UInt32(d.integer(forKey: Key.auraColor)))
        }
        if d.object(forKey: Key.auraColor2) != nil {
            auraColor2 = Color(rgb: UInt32(d.integer(forKey: Key.auraColor2)))
        }
        if let z = d.array(forKey: Key.auraZones) as? [Int], z.count == 4 {
            auraZones = z.map { Color(rgb: UInt32($0)) }
        }
        if d.object(forKey: Key.auraBrightness) != nil {
            auraBrightness = min(max(d.integer(forKey: Key.auraBrightness), 0), 3)
        }
        if d.object(forKey: Key.auraSpeed) != nil {
            auraSpeed = min(max(d.integer(forKey: Key.auraSpeed), 1), 3)
        }
        if d.object(forKey: Key.auraPerZone) != nil { auraPerZone = d.bool(forKey: Key.auraPerZone) }
    }

    func resetCurve(_ role: FanRole) {
        var c = controls[role] ?? FanControl()
        c.resetCurveToDefault()
        controls[role] = c
    }
}
