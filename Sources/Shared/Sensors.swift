//
//  Sensors.swift — 各类传感器采集
//
//  温度来源的优先级是这里最关键的设计：
//  这台机器（Ryzen 9 7940HX 黑苹果）目前 SMC 里一个 CPU 热感键都没有，
//  所以 CPU 温度要等装了 SMCAMDProcessor 才有；在那之前用 GPU 温度当热载荷代理。
//

import Foundation
import IOKit

// MARK: - 温度来源

enum TempSource: String, CaseIterable, Identifiable, Codable {
    case cpuSMC   = "CPU（SMC）"
    case gpu      = "GPU"
    case battery  = "电池"
    case cpuLoad  = "CPU 占用率"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .cpuSMC:  return "需要 AMDRyzenCPUPowerManagement + SMCAMDProcessor 驱动，读 TC0P"
        case .gpu:     return "走 IOAccelerator 的 PerformanceStatistics，开箱可用"
        case .battery: return "SMC 键 B0CT，只能当粗略参考"
        case .cpuLoad: return "无温度可用时的兜底：按 CPU 占用百分比当横轴"
        }
    }

    /// 该来源横轴的单位
    var unit: String { self == .cpuLoad ? "%" : "°C" }
}

// MARK: - CPU 占用率

final class CPUMonitor {
    private var prevTotal: Double = 0
    private var prevIdle: Double = 0

    func sample() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &numCpus, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        var total: Double = 0
        var idle: Double = 0
        for i in 0..<Int(numCpus) {
            let base = Int(CPU_STATE_MAX) * i
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idleT = Double(info[base + Int(CPU_STATE_IDLE)])
            total += user + system + nice + idleT
            idle += idleT
        }

        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)

        let dTotal = total - prevTotal
        let dIdle = idle - prevIdle
        prevTotal = total
        prevIdle = idle

        guard dTotal > 0 else { return 0 }
        return max(0, min(100, (1 - dIdle / dTotal) * 100))
    }
}

// MARK: - GPU

struct GPUStats {
    var temperature: Double?
    var utilization: Double?
    var name: String = "未知"
}

func readGPUStats() -> GPUStats {
    var stats = GPUStats()
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"), &iter)
    guard kr == KERN_SUCCESS else { return stats }
    defer { IOObjectRelease(iter) }

    while true {
        let svc = IOIteratorNext(iter)
        guard svc != IO_OBJECT_NULL else { break }
        defer { IOObjectRelease(svc) }

        guard let props = IORegistryEntryCreateCFProperty(
                svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { continue }
        guard let dict = props.takeRetainedValue() as? [String: Any] else { continue }

        if let t = dict["Temperature(C)"] as? Double, t > 0 {
            stats.temperature = t
            stats.utilization = dict["Device Utilization %"] as? Double

            // 尽量拿到设备名
            var name = "GPU"
            var parent: io_registry_entry_t = svc
            for _ in 0..<4 {
                var parentOut: io_registry_entry_t = 0
                let r = IORegistryEntryGetParentEntry(parent, kIOServicePlane, &parentOut)
                if r != KERN_SUCCESS { break }
                if let m = IORegistryEntryCreateCFProperty(parentOut, "model" as CFString,
                                                           kCFAllocatorDefault, 0) {
                    if let d = m.takeRetainedValue() as? Data,
                       let s = String(data: d, encoding: .ascii) {
                        name = s.trimmingCharacters(in: .controlCharacters)
                        IOObjectRelease(parentOut)
                        break
                    }
                }
                parent = parentOut
            }
            stats.name = name
            break
        }
    }
    return stats
}

// MARK: - 内存

struct MemoryStats {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var pressure: Double = 0      // 0...1

    var usedGB: Double { Double(used) / 1_073_741_824 }
    var totalGB: Double { Double(total) / 1_073_741_824 }
}

func readMemoryStats() -> MemoryStats {
    var stats = MemoryStats()
    stats.total = ProcessInfo.processInfo.physicalMemory

    var vmStats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vmStats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return stats }

    let pageSize = Double(vm_kernel_page_size)
    let active = Double(vmStats.active_count)
    let wired = Double(vmStats.wire_count)
    let compressed = Double(vmStats.compressor_page_count)
    let inactive = Double(vmStats.inactive_count)
    let freePages = Double(vmStats.free_count)

    stats.used = UInt64((active + wired + compressed) * pageSize)
    stats.pressure = (active + wired + compressed) / max(1, active + wired + compressed + inactive + freePages)
    return stats
}

// MARK: - 电池

struct BatteryInfo {
    var present = false
    var chargePercent = 0.0
    var remainingMAh = 0
    var fullChargeMAh = 0
    var designMAh = 0
    var voltage = 0.0          // V
    var amperage = 0           // mA，负=放电
    var temperature = 0.0      // °C
    var cycleCount = 0
    var isCharging = false
    var isACConnected = false
    var timeRemainingMin: Int?

    /// 健康度 = 当前满充容量 / 设计容量
    var healthPercent: Double {
        guard designMAh > 0 else { return 0 }
        return Double(fullChargeMAh) / Double(designMAh) * 100
    }
}

func readBatteryInfo(smc: SMC) -> BatteryInfo {
    var b = BatteryInfo()

    guard let bbIN = smc.readDouble("BBIN"), bbIN > 0 else { return b }
    b.present = true

    if let full = smc.readDouble("B0FC") { b.fullChargeMAh = Int(full) }
    if let remain = smc.readDouble("B0RM") { b.remainingMAh = Int(remain) }
    if let volt = smc.readDouble("B0AV") { b.voltage = volt / 1000.0 }
    if let amp = smc.readDouble("B0AC") { b.amperage = Int(amp) }
    if let temp = smc.readDouble("B0CT") { b.temperature = temp / 10.0 }
    if let acin = smc.readDouble("ACIN") { b.isACConnected = acin > 0 }

    if b.fullChargeMAh > 0 {
        b.chargePercent = Double(b.remainingMAh) / Double(b.fullChargeMAh) * 100
    }

    // 设计容量与循环次数只有 IORegistry 里有
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
    if service != IO_OBJECT_NULL {
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any] {
            if let d = dict["DesignCapacity"] as? Int { b.designMAh = d }
            if let c = dict["CycleCount"] as? Int { b.cycleCount = c }
            if let bd = dict["BatteryData"] as? [String: Any],
               let dc = bd["DesignCapacity"] as? Int { b.designMAh = dc }
        }
    }

    b.isCharging = b.isACConnected && b.amperage > 0
    return b
}

// MARK: - 风扇

struct FanState {
    var index: Int
    var actualRPM: Double = 0
    var targetRPM: Double = 0
    var minRPM: Double = 0
    var maxRPM: Double = 0
    var isManual: Bool = false

    /// 实际转速占最大转速的百分比
    var actualPercent: Double {
        guard maxRPM > 0 else { return 0 }
        return actualRPM / maxRPM * 100
    }
}

func readFans(smc: SMC) -> [FanState] {
    guard let count = smc.readDouble("FNum"), count > 0 else { return [] }
    var fans: [FanState] = []
    for i in 0..<Int(count) {
        var f = FanState(index: i)
        f.actualRPM = smc.readDouble("F\(i)Ac") ?? 0
        f.targetRPM = smc.readDouble("F\(i)Tg") ?? 0
        f.minRPM = smc.readDouble("F\(i)Mn") ?? 0
        f.maxRPM = smc.readDouble("F\(i)Mx") ?? 0
        f.isManual = (smc.readDouble("F\(i)Md") ?? 0) > 0
        fans.append(f)
    }
    return fans
}
