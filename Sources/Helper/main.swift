//
//  特权助手（LaunchDaemon，root）——所有 SMC 写操作都在这里执行
//
//  安全设计：看门狗。手动控扇是有风险的——万一 App 崩了，风扇会永远卡在某个转速上。
//  所以每条指令都刷新心跳，超过 kWatchdogSeconds 没动静就自动把风扇交回固件。
//

import Foundation
import SystemConfiguration

private let kWatchdogSeconds: TimeInterval = 15

final class HelperService: NSObject, HelperProtocol {

    private let smc = SMC.shared
    private var lastCommand = Date()
    private var watchdogTimer: Timer?
    private var manualFans: Set<Int> = []

    override init() {
        super.init()
        do {
            try smc.open()
            NSLog("[GHelper Helper] SMC 已打开")
        } catch {
            NSLog("[GHelper Helper] SMC 打开失败: \(error)")
        }
        startWatchdog()
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
        guard !manualFans.isEmpty else { return }
        guard Date().timeIntervalSince(lastCommand) > kWatchdogSeconds else { return }
        NSLog("[GHelper Helper] 心跳超时 \(kWatchdogSeconds)s，风扇交回固件")
        releaseAll()
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

    private func touch() { lastCommand = Date() }

    // MARK: HelperProtocol

    func ping(reply: @escaping (String) -> Void) {
        touch()
        let euid = geteuid()
        let count = Int(smc.readDouble("FNum") ?? 0)
        reply("助手运行中 · euid=\(euid) · 风扇 \(count) 把")
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

    func uninstall(reply: @escaping (Bool, String) -> Void) {
        boostReapplyTimer?.invalidate()
        boostReapplyTimer = nil
        releaseAll()
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
