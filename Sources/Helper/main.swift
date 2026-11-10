//
//  特权助手（LaunchDaemon，root）——所有 SMC 写操作都在这里执行
//
//  安全设计：看门狗。手动控扇是有风险的——万一 App 崩了，风扇会永远卡在某个转速上。
//  所以每条指令都刷新心跳，超过 kWatchdogSeconds 没动静就自动把风扇交回固件。
//

import Foundation
import SystemConfiguration
import IOKit

/// 与 GHRGB kext 常驻一个 IOUserClient 连接（不再每条命令都 spawn rgbctl 去开关连接）。
/// 之前每次命令都开/关一次连接，频繁改灯 + 风扇 WMNB 叠加时会把 EC 信箱冲挂
/// （IOServiceOpen e00002c7，2026-11-09 真机）。常驻连接 + 单锁串行化，彻底消除该 churn。
final class GHRGBClient {
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var poisoned = false

    /// 取可用连接；失败则关闭并重建一次（kext 被重载等情况）
    private func withConnection<T>(_ body: (io_connect_t) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        if conn == 0 || poisoned {
            if conn != 0 { IOServiceClose(conn); conn = 0 }
            let svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("GHRGB"))
            guard svc != 0 else { return nil }
            let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
            IOObjectRelease(svc)
            guard kr == KERN_SUCCESS, conn != 0 else { conn = 0; return nil }
            poisoned = false
        }
        return body(conn)
    }

    func setRGB(mode: UInt8, r: UInt8, g: UInt8, b: UInt8, speed: UInt8) -> Bool {
        guard let c = withConnection({ $0 }) else { return false }
        var inArr = [UInt64(mode), UInt64(r), UInt64(g), UInt64(b), UInt64(speed)]
        var out: UInt64 = 0; var outCnt: UInt32 = 0
        let kr = IOConnectCallScalarMethod(c, 0, &inArr, 5, &out, &outCnt)
        if kr != KERN_SUCCESS { poisoned = true; return false }
        return true
    }

    func setBrightness(_ level: UInt8) -> Bool {
        guard let c = withConnection({ $0 }) else { return false }
        var inArr = [UInt64(UInt32(level) & 0x0F)]
        var out: UInt64 = 0; var outCnt: UInt32 = 0
        let kr = IOConnectCallScalarMethod(c, 1, &inArr, 1, &out, &outCnt)
        if kr != KERN_SUCCESS { poisoned = true; return false }
        return true
    }

    /// 通用 WMNB。输出最多 16 字节。返回 (成功, 输出字节)
    func callWMNB(sig: UInt32, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32) -> (Bool, [UInt8]) {
        guard let c = withConnection({ $0 }) else { return (false, []) }
        var inArr = [UInt64(sig), UInt64(devid), UInt64(a1), UInt64(a2), UInt64(a3), UInt64(a4)]
        var outBuf = [UInt8](repeating: 0, count: 16)
        var outCnt: Int = outBuf.count
        let kr = IOConnectCallStructMethod(c, 4, &inArr, MemoryLayout<UInt64>.stride * 6, &outBuf, &outCnt)
        if kr != KERN_SUCCESS { poisoned = true; return (false, []) }
        if outCnt < 16 { outBuf.removeSubrange(outCnt..<16) }
        return (true, outBuf)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if conn != 0 { IOServiceClose(conn); conn = 0 }
    }
}

private let kWatchdogSeconds: TimeInterval = 15

final class HelperService: NSObject, HelperProtocol {

    private let smc = SMC.shared
    /// GHRGB kext 常驻连接（键盘灯 + 风扇曲线共用，单锁串行化，避免冲挂 EC 信箱）
    private let gh = GHRGBClient()
    private var lastCommand = Date()
    private var watchdogTimer: Timer?
    private var manualFans: Set<Int> = []

    // WMNB 风扇曲线接管状态（独立于 SMC 手动模式）
    private var wmnbFans: Set<Int> = []
    private var wmnbFactory: [Int: (devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32)] = [:]

    // 电池养护（充电上限 80%）偏好：助手以 root 持久化，供开机/唤醒重涂（App 不在时也能生效）
    private let kChargeLimitPath = "/Library/Application Support/GHelper/chargeLimitEnabled"

    override init() {
        super.init()
        do {
            try smc.open()
            NSLog("[GHelper Helper] SMC 已打开")
        } catch {
            NSLog("[GHelper Helper] SMC 打开失败: \(error)")
        }
        startWatchdog()
        // EC 每次冷启动会复位成 100%，开机即按存储偏好重涂（kext 未起则静默跳过，App 启动时会再补）
        if storedChargeLimit() {
            let (ok, _) = gh.callWMNB(sig: 0x53564544, devid: 0x00120057, a1: 80, a2: 0, a3: 0, a4: 0)
            NSLog("[GHelper Helper] 开机重涂电池养护 ok=\(ok)")
        }
    }

    // MARK: 电池养护（充电上限 80%）

    private func persistChargeLimit(_ on: Bool) {
        let dir = (kChargeLimitPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(on ? 1 : 0)".write(toFile: kChargeLimitPath, atomically: true, encoding: .utf8)
    }

    private func storedChargeLimit() -> Bool {
        (try? String(contentsOfFile: kChargeLimitPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func setChargeLimit(enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        touch()
        persistChargeLimit(enabled)
        // DSDT: arg1<=0x50 写 BH30=0x50（钉 80%）；arg1>0x50 清上限
        let a1: UInt32 = enabled ? 80 : 100
        let (ok, _) = gh.callWMNB(sig: 0x53564544, devid: 0x00120057, a1: a1, a2: 0, a3: 0, a4: 0)
        if ok {
            reply(true, enabled ? "已开启电池养护（充电上限 80%）" : "已关闭电池养护（解除 80% 上限）")
        } else {
            reply(false, "写入充电上限失败（GHRGB 未加载或连接异常）")
        }
    }

    // MARK: 看门狗

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkWatchdog()
            }
        }
    }

    private func checkWatchdog() {
        if !manualFans.isEmpty,
           Date().timeIntervalSince(lastCommand) > kWatchdogSeconds {
            NSLog("[GHelper Helper] 心跳超时 \(kWatchdogSeconds)s，SMC 风扇交回固件")
            releaseAll()
        }
        if !wmnbFans.isEmpty,
           Date().timeIntervalSince(lastCommand) > kWatchdogSeconds {
            NSLog("[GHelper Helper] 心跳超时 \(kWatchdogSeconds)s，WMNB 风扇交回出厂曲线")
            releaseAllWMNB()
        }
    }

    private func releaseAll() {
        for i in manualFans {
            do {
                try smc.writeUInt8("F\(i)Md", 0)
                NSLog("[GHelper Helper] fan\(i) 恢复自动")
            } catch {
                NSLog("[GHelper Helper] fan\(i) 恢复自动失败: \(error)")
            }
        }
        manualFans.removeAll()
    }

    // MARK: WMNB 风扇曲线

    /// 把 WMNB DSTS 返回的 16 字节解析为 4 个 uint32（小端）——与写入打包格式一致
    private func parseCurveBytes(_ bytes: [UInt8]) -> (UInt32, UInt32, UInt32, UInt32)? {
        guard bytes.count >= 16 else { return nil }
        let b = Array(bytes.suffix(16))
        let u32: (Int) -> UInt32 = { i in
            UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
        }
        return (u32(0), u32(4), u32(8), u32(12))
    }

    private func releaseAllWMNB() {
        for i in wmnbFans {
            if let fac = wmnbFactory[i] {
                let (ok, _) = gh.callWMNB(sig: 0x53564544, devid: fac.devid,
                                          a1: fac.a1, a2: fac.a2, a3: fac.a3, a4: fac.a4)
                NSLog("[GHelper Helper] fan\(i) 写回出厂曲线 ok=\(ok)")
            } else {
                // 没缓存出厂曲线：退回 SMC 交回
                do { try smc.writeUInt8("F\(i)Md", 0) } catch {}
                NSLog("[GHelper Helper] fan\(i) 无出厂缓存，退回 SMC 交回")
            }
        }
        wmnbFans.removeAll()
    }

    func callWMNB(sig: UInt32, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                  reply: @escaping (Bool, String) -> Void) {
        touch()
        let (ok, out) = gh.callWMNB(sig: sig, devid: devid, a1: a1, a2: a2, a3: a3, a4: a4)
        let msg = out.map { String(format: "%02x", $0) }.joined(separator: " ")
        reply(ok, ok ? msg : "WMNB 调用失败（GHRGB 未加载或连接异常）")
    }

    func setFanCurve(_ index: Int, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                     reply: @escaping (Bool, String) -> Void) {
        touch()
        // 1) 首次接管该扇：先读出厂曲线缓存，供看门狗/交回写回
        if wmnbFactory[index] == nil {
            let (okRead, out) = gh.callWMNB(sig: 0x53545344, devid: devid, a1: 0, a2: 0, a3: 0, a4: 0)
            if okRead, let fac = parseCurveBytes(out) {
                wmnbFactory[index] = (devid, fac.0, fac.1, fac.2, fac.3)
                NSLog("[GHelper Helper] fan\(index) 缓存出厂曲线 devid=0x\(String(format: "%x", devid))")
            } else {
                NSLog("[GHelper Helper] fan\(index) 读取出厂曲线失败")
            }
        }
        // 2) 写自定义曲线接管
        let (ok, _) = gh.callWMNB(sig: 0x53564544, devid: devid, a1: a1, a2: a2, a3: a3, a4: a4)
        if ok {
            wmnbFans.insert(index)
            reply(true, "已接管风扇曲线（devid=0x\(String(format: "%x", devid))）")
        } else {
            reply(false, "写入风扇曲线失败（GHRGB 未加载或连接异常）")
        }
    }

    func releaseFanCurve(_ index: Int, reply: @escaping (Bool, String) -> Void) {
        touch()
        if let fac = wmnbFactory[index] {
            let (ok, _) = gh.callWMNB(sig: 0x53564544, devid: fac.devid,
                                      a1: fac.a1, a2: fac.a2, a3: fac.a3, a4: fac.a4)
            wmnbFans.remove(index)
            reply(ok, ok ? "已交回出厂曲线" : "交回出厂曲线失败（GHRGB 未加载或连接异常）")
        } else {
            do {
                try smc.writeUInt8("F\(index)Md", 0)
                reply(true, "未缓存出厂曲线，已退回 SMC 交回")
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func keepFanAlive(_ index: Int, reply: @escaping (Bool, String) -> Void) {
        touch()
        reply(true, "")
    }

    private func touch() { lastCommand = Date() }

    // MARK: HelperProtocol

    func ping(reply: @escaping (String) -> Void) {
        touch()
        let euid = geteuid()
        let count = Int(smc.readDouble("FNum") ?? 0)
        reply("助手运行中 · euid=\(euid) · 风扇 \(count) 把")
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        let path = "/Library/PrivilegedHelperTools/.ghelper-helper-version"
        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
            reply(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            reply("0")
        }
    }

    func setFanManual(_ index: Int, manual: Bool, reply: @escaping (Bool, String) -> Void) {
        touch()
        do {
            try smc.writeUInt8("F\(index)Md", manual ? 1 : 0)
            if manual { manualFans.insert(index) } else { manualFans.remove(index) }
            reply(true, "F\(index)Md = \(manual ? 1 : 0)")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func setFanTargetRPM(_ index: Int, rpm: Double, reply: @escaping (Bool, String) -> Void) {
        touch()
        do {
            // 先确保处于手动模式，否则写目标转速没意义
            if !manualFans.contains(index) {
                try smc.writeUInt8("F\(index)Md", 1)
                manualFans.insert(index)
            }
            try smc.writeFPE2("F\(index)Tg", rpm)
            reply(true, "F\(index)Tg = \(Int(rpm)) RPM")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func readFrequency(reply: @escaping (Double, String) -> Void) {
        touch()
        let task = Process()
        task.launchPath = "/usr/bin/powermetrics"
        task.arguments = ["-n1", "-i100", "--samplers", "cpu_power"]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            reply(0, "powermetrics 启动失败: \(error.localizedDescription)")
            return
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8), !out.isEmpty else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
            reply(0, "powermetrics 无输出: \(err.trimmingCharacters(in: .whitespaces))")
            return
        }
        let mhz = Self.parseFrequencyMHz(out)
        if mhz > 0 {
            reply(mhz, "实时")
        } else {
            reply(0, "未能从 powermetrics 解析出频率")
        }
    }

    /// 从 powermetrics 输出里取所有 "… frequency as fraction of nominal: X% (Y Mhz)"
    /// 中的 Y，返回最大值（即当前最高核频），单位 MHz。
    private static func parseFrequencyMHz(_ text: String) -> Double {
        let ns = text as NSString
        let pattern = #"frequency as fraction of nominal:\s*[\d.]+%\s*\(\s*([\d.]+)\s*[Mm]hz\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return 0
        }
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        var maxMHz: Double = 0
        for m in matches where m.numberOfRanges > 1 {
            let s = ns.substring(with: m.range(at: 1))
            if let v = Double(s), v > maxMHz { maxMHz = v }
        }
        return maxMHz
    }

    // MARK: - 睿频模式（zenmaster / SMU）

    /// 候选的 python3 解释器（用于调 zenmaster）。
    /// 顺序不重要——zenmasterPython() 会逐个真正 `import zenmaster` 验证后再选，
    /// 避免选到没有 zenmaster 的系统 python（如 /usr/bin/python3 3.9.6）。
    private let zenmasterPythonCandidates = [
        "/Library/PrivilegedHelperTools/zenmaster-venv/bin/python3",
        "/usr/bin/python3",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
        "/Users/anoxia-m/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
    ]

    /// 返回第一个能真正 `import zenmaster` 的 python 解释器路径（LaunchDaemon 环境无用户 PATH，必须实测）。
    private func zenmasterPython() -> String? {
        for p in zenmasterPythonCandidates where FileManager.default.isExecutableFile(atPath: p) {
            let t = Process()
            t.launchPath = p
            t.arguments = ["-c", "import zenmaster"]
            t.standardError = Pipe()   // 丢弃输出，只看退出码
            try? t.run(); t.waitUntilExit()
            if t.terminationStatus == 0 { return p }
        }
        // 退回 PATH 查找（仅当上面都失败时）
        let t = Process()
        t.launchPath = "/usr/bin/which"
        t.arguments = ["python3"]
        let pipe = Pipe()
        t.standardOutput = pipe
        try? t.run(); t.waitUntilExit()
        if let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
            return out
        }
        return nil
    }

    /// 跑一次 zenmaster，返回 (退出码, 标准输出, 错误输出)
    private func runZenmaster(_ py: String, _ args: [String]) -> (Int, String, String) {
        let task = Process()
        task.launchPath = py
        task.arguments = ["-m", "zenmaster"] + args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try? task.run()
        task.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (Int(task.terminationStatus), o, e)
    }

    /// 读基础频率（MHz）：sysctl hw.cpufrequency 返回 Hz，转 MHz。通用，不依赖型号。
    private static func sysctlBaseMHz() -> Double {
        let task = Process()
        task.launchPath = "/usr/sbin/sysctl"
        task.arguments = ["-n", "hw.cpufrequency"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        guard let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let hz = Double(s) else { return 0 }
        return hz / 1_000_000.0
    }

    /// 读取 CPU 最大睿频（MHz），用 zenmaster 自带探测，通用。后端未就绪时返回 nil。
    private func queryMaxMHz(_ py: String) -> Double? {
        let (code, o, e) = runZenmaster(py, ["--iopci", "--get-max-cpu-clk"])
        let text = o + e
        guard let re = try? NSRegularExpression(pattern: #"(\d{2,5}(?:\.\d+)?)"#) else { return nil }
        let ns = text as NSString
        let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in ms where m.numberOfRanges > 1 {
            let s = ns.substring(with: m.range(at: 1))
            guard let v = Double(s) else { continue }
            // 容错：有的 SMU 返回 GHz 小数（如 5.2），换算成 MHz
            let mhz = v < 1000 ? v * 1000 : v
            if mhz >= 1000 { return mhz }
        }
        return code == 0 ? nil : nil
    }

    private var boostReapplyTimer: Timer?
    private var boostTargetMHz: Double = 0

    func setBoostMode(enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        touch()
        guard let py = zenmasterPython() else {
            reply(false, "未找到 python3 / zenmaster：请在设置页重装助手，或手动 pip install zenmaster")
            return
        }
        let base = Self.sysctlBaseMHz()
        guard base > 0 else {
            reply(false, "无法读取基础频率 (sysctl hw.cpufrequency)")
            return
        }

        if enabled {
            // 开：放开睿频上限到 CPU 最大睿频（跑满）
            guard let max = queryMaxMHz(py) else {
                reply(false, "无法读取最大睿频：zenmaster 后端未就绪。请确认 boot-args 含 debug=0x144，或已加载 DirectHW.kext 后重试。")
                return
            }
            let (code, o, e) = runZenmaster(py, ["--iopci", "--set-boost-limit-frequency=\(Int(max))"])
            if code != 0 {
                let msg = (e.isEmpty ? o : e).trimmingCharacters(in: .whitespaces)
                reply(false, "开启睿频失败：\(String(msg.prefix(200)))")
                return
            }
            boostTargetMHz = max
            startBoostReapply(py: py)
            reply(true, "睿频已开启，上限 \(Int(max)) MHz（跑满）")
        } else {
            // 关：把睿频上限钉到基础频率（不睿频·降温）
            let (code, o, e) = runZenmaster(py, ["--iopci", "--set-boost-limit-frequency=\(Int(base))"])
            if code != 0 {
                // 兜底：用 oc-clk 硬锁基础频率
                let (c2, o2, e2) = runZenmaster(py, ["--iopci", "--oc-clk=\(Int(base))"])
                if c2 != 0 {
                    let msg = (e2.isEmpty ? o2 : e2).trimmingCharacters(in: .whitespaces)
                    reply(false, "锁定默认频率失败：\(String(msg.prefix(200)))")
                    return
                }
            }
            boostTargetMHz = base
            startBoostReapply(py: py)
            reply(true, "已锁定默认频率 \(Int(base)) MHz（不睿频·降温）")
        }
    }

    /// 每 30s 重涂一次，防止 macOS 热管理把睿频上限覆盖回去
    private func startBoostReapply(py: String) {
        boostReapplyTimer?.invalidate()
        boostReapplyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.boostTargetMHz > 0 else { return }
            _ = self.runZenmaster(py, ["--iopci", "--set-boost-limit-frequency=\(Int(self.boostTargetMHz))"])
        }
    }

    func readKey(_ key: String, reply: @escaping (NSNumber?, String) -> Void) {
        touch()
        if let v = smc.readDouble(key) {
            reply(NSNumber(value: v), "OK")
        } else {
            reply(nil, "读取 \(key) 失败或键不存在")
        }
    }

    func writeKey(_ key: String, value: Double, reply: @escaping (Bool, String) -> Void) {
        touch()
        guard let info = try? smc.keyInfo(key) else {
            reply(false, "键 \(key) 不存在")
            return
        }
        do {
            switch info.type {
            case "ui8 ":
                try smc.writeUInt8(key, UInt8(max(0, min(255, value))))
            case "fpe2":
                try smc.writeFPE2(key, value)
            default:
                reply(false, "暂不支持写入 \(info.type) 类型")
                return
            }
            reply(true, "已写入 \(key) = \(value)")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 键盘 RGB（GHRGB kext，经常驻 IOUserClient 下发，需 root）

    func applyKeyboardLighting(r: Int, g: Int, b: Int, mode: Int,
                              brightness: Int, speed: Int,
                              reply: @escaping (Bool, String) -> Void) {
        touch()
        let rr = min(max(r, 0), 255)
        let gg = min(max(g, 0), 255)
        let bb = min(max(b, 0), 255)
        let mm = min(max(mode, 0), 255)
        let sp = min(max(speed, 0), 255)
        let lvl = min(max(brightness, 0), 15)

        let okSet = gh.setRGB(mode: UInt8(mm), r: UInt8(rr), g: UInt8(gg), b: UInt8(bb), speed: UInt8(sp))
        guard okSet else {
            reply(false, "键盘灯光写 RGB 失败（GHRGB 未加载或连接异常）")
            return
        }
        let okBright = gh.setBrightness(UInt8(lvl))
        let ok = okSet && okBright
        let detail = "颜色(\(rr),\(gg),\(bb)) 亮度\(lvl)（\(ok ? "成功" : "失败")）"
        reply(ok, detail)
    }

    func uninstall(reply: @escaping (Bool, String) -> Void) {
        boostReapplyTimer?.invalidate()
        boostReapplyTimer = nil
        releaseAll()
        releaseAllWMNB()
        let script = """
        launchctl bootout system/\(kHelperMachServiceName) 2>/dev/null || \
        launchctl unload -w \(kHelperPlistPath) 2>/dev/null; \
        rm -f '\(kHelperPlistPath)' '\(kHelperInstallPath)'; \
        echo done
        """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        task.launch()
        task.waitUntilExit()

        // 给自己留点时间把 reply 发回去再退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(true, "已卸载助手")
            exit(0)
        }
    }
}

// MARK: - 连接校验

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    /// 当前登录到图形界面的用户 uid；只接受来自该用户（或 root）的连接
    private func consoleUID() -> uid_t {
        var uid: uid_t = 0
        if let uname = SCDynamicStoreCopyConsoleUser(nil, &uid, nil),
           let name = uname as String?, !name.isEmpty, name != "loginwindow" {
            return uid
        }
        return 501
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let euid = newConnection.effectiveUserIdentifier
        let allowed = (euid == 0) || (euid == consoleUID())
        if !allowed {
            NSLog("[GHelper Helper] 拒绝来自 euid=\(euid) 的连接")
            return false
        }

        NSLog("[GHelper Helper] 接受连接 pid=\(newConnection.processIdentifier) euid=\(euid)")

        let exported = HelperService()
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = exported
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.resume()

        // 连接断开时释放该连接持有的手动风扇
        newConnection.interruptionHandler = { NSLog("[GHelper Helper] 连接中断") }
        newConnection.invalidationHandler = { NSLog("[GHelper Helper] 连接失效") }
        return true
    }
}

// MARK: - 入口

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()

NSLog("[GHelper Helper] 已启动，监听 \(kHelperMachServiceName)")

RunLoop.main.run()
