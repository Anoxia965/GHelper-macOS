//
//  WindowServerMonitor.swift — WindowServer 瞬时 CPU 占用 / 内存
//
//  黑苹果没有完整硬件加速时，WindowServer 常是 CPU 头号大户（活动监视器里
//  那个 90%+ 的常驻进程）。把它做进 GHelper，方便随时看它有没有飙上去。
//
//  为什么不用 ps 的 %CPU：那是「进程启动至今的累计平均」，长时间运行后几乎
//  不动，看不出瞬时波动。这里改用 cputime（累计 CPU 时间）两次采样求差：
//      瞬时 CPU% = Δcputime / Δ墙钟时间 × 100
//  单核 100% 口径，多核可超过 100%（与 top 一致）。
//
//  为什么不用 proc_pidinfo：WindowServer 属于 _windowserver 用户，普通用户
//  进程读它会得到 EPERM(errno 1)。ps 走内核导出的基本信息，不需要 root，
//  也不需要每 1.5 秒 fork 一次慢吞吞的 top。一次 ps -ax 约 50ms。
//

import Foundation

struct WindowServerStats {
    /// 瞬时 CPU 占用，单核 100% 口径（多核可 > 100）
    var cpuPercent: Double = 0
    /// 常驻内存（MB）
    var residentMB: Double = 0
    /// 进程 PID；nil 表示当前没找到 WindowServer
    var pid: Int32?
    /// 读数是否有效（首次采样或进程刚重启时 false，下一次起为 true）
    var available: Bool = false

    var cpuColorLevel: Int {
        if cpuPercent >= 150 { return 2 }   // 危险
        if cpuPercent >= 80  { return 1 }   // 偏高
        return 0
    }
}

final class WindowServerMonitor {

    /// 采样要 fork 一次 ps（约 50ms），放后台串行队列避免卡 UI；
    /// 串行也保证了「上次采样」状态不会被并发踩到。
    private let queue = DispatchQueue(label: "cn.anoxia.GHelper.windowServer", qos: .utility)

    /// 异步采样，结果回主线程。AppModel 用这个，避免在 @MainActor 上跑 ps。
    func sampleAsync(_ completion: @escaping (WindowServerStats) -> Void) {
        queue.async {
            let stats = self.sample()
            DispatchQueue.main.async { completion(stats) }
        }
    }

    private struct Sample {
        let pid: Int32
        let cpuSeconds: Double
        let wallClock: TimeInterval
        let residentMB: Double
    }

    private var previous: Sample?

    /// 采样一次。建议在后台串行队列调用（内部不做线程同步）。
    func sample() -> WindowServerStats {
        guard let out = Shell.run("/bin/ps", ["-ax", "-o", "pid=,cputime=,rss=,comm="]) else {
            previous = nil
            return WindowServerStats()
        }

        var found: Sample?
        for line in out.split(separator: "\n") {
            let text = String(line)
            // comm 是全路径；只认真正的 WindowServer 守护进程，排除
            // distnoted / grep / 其它名字里带 WindowServer 的旁支
            guard text.contains("/WindowServer"),
                  !text.contains("distnoted"),
                  !text.contains("-daemon") else { continue }
            let cols = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3,
                  let pid = Int32(cols[0]),
                  let cpu = Self.parseCPUTime(String(cols[1])),
                  let rssKB = Double(cols[2]) else { continue }
            found = Sample(pid: pid,
                           cpuSeconds: cpu,
                           wallClock: Date().timeIntervalSinceReferenceDate,
                           residentMB: rssKB / 1024.0)
            break
        }

        guard let cur = found else {
            previous = nil
            return WindowServerStats()
        }

        var stats = WindowServerStats(residentMB: cur.residentMB, pid: cur.pid)

        if let prev = previous,
           prev.pid == cur.pid,                       // PID 变了 = 进程重启，重新取基线
           cur.wallClock - prev.wallClock > 0.2,      // 间隔太短会放大误差
           cur.cpuSeconds >= prev.cpuSeconds {        // 累计时间倒退 = 异常
            let dt = cur.wallClock - prev.wallClock
            let du = cur.cpuSeconds - prev.cpuSeconds
            // 上限保护：多核机器理论上限 = 逻辑核数 × 100，留一点余量
            let cap = Double(ProcessInfo.processInfo.processorCount) * 100.0 * 1.1
            stats.cpuPercent = min(cap, max(0, (du / dt) * 100.0))
            stats.available = true
        }
        // 首次采样只存基线，返回 available=false（UI 显示「采样中…」）

        previous = cur
        return stats
    }

    /// 解析 ps 的 cputime：mm:ss.ss / hh:mm:ss.ss / dd-hh:mm:ss.ss
    static func parseCPUTime(_ raw: String) -> Double? {
        var days = 0.0
        var rest = raw
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard let sec = Double(parts.last ?? "") else { return nil }
        var total = sec + days * 86400
        if parts.count >= 2 { total += (Double(parts[parts.count - 2]) ?? 0) * 60 }
        if parts.count >= 3 { total += (Double(parts[parts.count - 3]) ?? 0) * 3600 }
        return total
    }
}
