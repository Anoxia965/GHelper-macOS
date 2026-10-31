//
//  Hardware.swift — 硬件与系统信息探测
//
//  设计目标：自动探测、优雅降级（拿不到显示"—"），不硬编码任何单台机器，
//  这样同一份 App 给别人（白苹果 / 不同配置的黑苹果）也能跑、能显示。
//  所有探测都是只读命令 + IORegistry 枚举，普通用户即可执行，无需 root。
//

import Foundation
import IOKit

// MARK: - 数据结构

struct GPUDevice: Identifiable {
    let id = UUID()
    let name: String
    let vendor: String
    let deviceID: String
}

struct MemoryModule: Identifiable {
    let id = UUID()
    let size: String
    let type: String
    let speed: String
}

struct KextInfo: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let version: String
    let isLoaded: Bool
    let installed: Bool

    var statusText: String {
        if isLoaded { return "已加载" }
        if installed { return "已安装·未加载" }
        return "未安装"
    }
    var statusColor: String {   // 仅用于视图判断，返回语义色名
        if isLoaded { return "green" }
        if installed { return "orange" }
        return "gray"
    }
}

struct HardwareInfo {
    // 系统
    var osVersion = "—"
    var osBuild = "—"
    var kernelVersion = "—"
    var sipStatus = "—"
    var bootMode = "—"
    // 机型
    var smbios = "—"
    var productName = "—"
    var serialMasked = "—"
    // CPU
    var cpuBrand = "—"
    var cpuCoresPhysical = 0
    var cpuCoresLogical = 0
    var cpuVendor = "—"
    // 内存
    var memoryTotalGB = 0.0
    var memoryModules: [MemoryModule] = []
    // 显卡
    var gpus: [GPUDevice] = []
    var gpuVRAM = "—"
    // 引导
    var openCoreVersion = "—"
    var bootVolume = "—"
    var isHackintosh = false
    // SMC
    var smcBackend = "—"
    var smcKeyCount = 0
    // 驱动
    var kexts: [KextInfo] = []
}

// MARK: - 探测

/// 收集全部硬件信息。设计为可在后台线程调用（只读 + IORegistry 枚举）。
func collectHardware() -> HardwareInfo {
    var info = HardwareInfo()

    info.smcKeyCount = Machine.smcKeyCount

    // —— 系统 ——
    let ov = ProcessInfo.processInfo.operatingSystemVersion
    info.osVersion = "\(ov.majorVersion).\(ov.minorVersion).\(ov.patchVersion)"
    info.osBuild = Shell.run("/usr/bin/sw_vers", ["-buildVersion"]) ?? "—"
    info.kernelVersion = (Shell.run("/usr/bin/uname", ["-v"]) ?? "—")
        .trimmingCharacters(in: .whitespaces)
    if let csr = Shell.run("/usr/bin/csrctl", ["status"]) {
        if csr.lowercased().contains("disabled") { info.sipStatus = "已关闭 (Disabled)" }
        else if csr.lowercased().contains("enabled") { info.sipStatus = "开启 (Enabled)" }
        else { info.sipStatus = csr.components(separatedBy: "\n").first ?? csr }
    }

    // —— 机型 / SMBIOS ——
    info.smbios = Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"]) ?? "—"
    if let pn = readDeviceTreeString("product-name"), !pn.isEmpty { info.productName = pn }
    else { info.productName = info.smbios }
    if let sn = readDeviceTreeString("serial-number"), sn.count >= 4 {
        let head = sn.prefix(2)
        let tail = sn.suffix(3)
        info.serialMasked = "\(head)••••\(tail)"
    }

    // —— CPU ——
    info.cpuBrand = Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]) ?? "—"
    if let p = sysctlInt("hw.physicalcpu") { info.cpuCoresPhysical = p }
    if let l = sysctlInt("hw.logicalcpu")  { info.cpuCoresLogical = l }
    info.cpuVendor = Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.vendor_string"]) ?? "—"

    // —— 内存 ——
    info.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    info.memoryModules = readMemoryModules()

    // —— 显卡（PCI 显示控制器枚举）——
    info.gpus = readPCIDisplays()
    info.gpuVRAM = readGPUVRAM()

    // —— 引导 / OpenCore ——
    info.openCoreVersion = readOpenCoreVersion()
    info.bootVolume = readBootVolume()

    // —— SMC 后端 ——
    let kextstat = Shell.run("/usr/sbin/kextstat", []) ?? ""
    info.isHackintosh = kextstat.contains("VirtualSMC")
    info.smcBackend = info.isHackintosh ? "VirtualSMC（开源）" : "AppleSMC（原生）"

    // —— 驱动 / kext ——
    info.kexts = readKexts(kextstat: kextstat)

    return info
}

// MARK: - 小工具

private func sysctlInt(_ name: String) -> Int? {
    guard let s = Shell.run("/usr/sbin/sysctl", ["-n", name]),
          let v = Int(s) else { return nil }
    return v
}

/// 读 IODeviceTree:/ 下的字符串属性（如 product-name、serial-number）
private func readDeviceTreeString(_ key: String) -> String? {
    let service = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/")
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    guard let prop = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                     kCFAllocatorDefault, 0) else { return nil }
    let v = prop.takeRetainedValue()
    if let s = v as? String { return s.trimmingCharacters(in: .controlCharacters) }
    if let d = v as? Data, let s = String(data: d, encoding: .ascii) {
        return s.trimmingCharacters(in: .controlCharacters)
    }
    return nil
}

private func vendorName(_ id: UInt16) -> String {
    switch id {
    case 0x10DE: return "NVIDIA"
    case 0x1002: return "AMD"
    case 0x1022: return "AMD"
    case 0x8086: return "Intel"
    case 0x106B: return "Apple"
    case 0x1A03: return "ASPEED"
    case 0x1B4B: return "Marvell"
    default:     return String(format: "0x%04X", id)
    }
}

private func readGPUVRAM() -> String {
    guard let out = Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType"]) else { return "—" }
    if let m = matches(of: #"VRAM \(Total\):\s*([^\n]+)"#, in: out).first,
       !m.isEmpty {
        return m.trimmingCharacters(in: .whitespaces)
    }
    return "—"
}

private func readPCIDisplays() -> [GPUDevice] {
    var out: [GPUDevice] = []
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                      IOServiceMatching("IOPCIDevice"), &iter) == KERN_SUCCESS else {
        return out
    }
    defer { IOObjectRelease(iter) }

    while true {
        let svc = IOIteratorNext(iter)
        guard svc != IO_OBJECT_NULL else { break }
        defer { IOObjectRelease(svc) }

        // class-code：仅保留显示控制器 (0x03xxxxxx)
        guard let ccRef = IORegistryEntryCreateCFProperty(svc, "class-code" as CFString,
                                                         kCFAllocatorDefault, 0) else { continue }
        guard let ccData = ccRef.takeRetainedValue() as? Data, ccData.count >= 4 else { continue }
        let cls = UInt32(ccData[0]) | UInt32(ccData[1]) << 8 |
                  UInt32(ccData[2]) << 16 | UInt32(ccData[3]) << 24
        guard (cls & 0xFFFFFF00) == 0x03000000 else { continue }

        var name = "显示控制器"
        if let m = IORegistryEntryCreateCFProperty(svc, "model" as CFString,
                                                   kCFAllocatorDefault, 0),
           let md = m.takeRetainedValue() as? Data,
           let s = String(data: md, encoding: .ascii) {
            name = s.trimmingCharacters(in: .controlCharacters)
        }
        var vendor = "未知"
        if let v = IORegistryEntryCreateCFProperty(svc, "vendor-id" as CFString,
                                                   kCFAllocatorDefault, 0),
           let vd = v.takeRetainedValue() as? Data, vd.count >= 2 {
            vendor = vendorName(UInt16(vd[0]) | UInt16(vd[1]) << 8)
        }
        var deviceID = ""
        if let v = IORegistryEntryCreateCFProperty(svc, "device-id" as CFString,
                                                   kCFAllocatorDefault, 0),
           let vd = v.takeRetainedValue() as? Data, vd.count >= 2 {
            deviceID = String(format: "0x%04X", UInt16(vd[0]) | UInt16(vd[1]) << 8)
        }
        out.append(GPUDevice(name: name, vendor: vendor, deviceID: deviceID))
    }
    return out
}

private func readMemoryModules() -> [MemoryModule] {
    guard let out = Shell.run("/usr/sbin/system_profiler", ["SPMemoryDataType"]) else { return [] }
    // 提取 Size: 行（跳过 Empty）
    let sizeLines = matches(of: #"Size:\s*([^\n]+)"#, in: out)
        .compactMap { $0 }
        .filter { !$0.lowercased().contains("empty") }
    guard !sizeLines.isEmpty else { return [] }

    let type = matches(of: #"Type:\s*([^\n]+)"#, in: out).first ?? ""
    let speed = matches(of: #"Speed:\s*([^\n]+)"#, in: out).first ?? ""
    return sizeLines.map { MemoryModule(size: $0, type: type, speed: speed) }
}

private func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    return regex.matches(in: text, range: range).compactMap { m -> String? in
        guard m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}

private func readOpenCoreVersion() -> String {
    // 优先 NVRAM 里的 opencore-version（普通用户可读，受保护时失败）
    if let nv = Shell.run("/usr/sbin/nvram", ["-p"]) {
        for line in nv.components(separatedBy: "\n") where line.contains("opencore-version") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 {
                let v = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
    }
    // 回退：从已挂载 EFI 的 OpenCore.efi 读版本字符串
    if let v = ocisVersionFromEFI() { return v }
    return "未检测"
}

private func ocisVersionFromEFI() -> String? {
    let candidates = [
        "/Volumes/EFI/EFI/OC/OpenCore.efi",
        "/System/Volumes/EFI/EFI/OC/OpenCore.efi",
    ]
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { continue }
        if let str = String(data: data, encoding: .ascii) {
            let range = NSRange(location: 0, length: str.utf16.count)
            if let m = try? NSRegularExpression(pattern: #"OpenCore[-\s]?(\d+\.\d+\.\d+)"#)
                .firstMatch(in: str, range: range),
               m.numberOfRanges > 1 {
                let v = (str as NSString).substring(with: m.range(at: 1))
                return "OpenCore \(v)"
            }
        }
    }
    return nil
}

private func readBootVolume() -> String {
    if let b = Shell.run("/usr/sbin/bless", ["--info"]) {
        for line in b.components(separatedBy: "\n") where line.contains("Boot Volume") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
    }
    return "未检测"
}

// MARK: - kext 扫描

/// 已知的黑苹果 / 补丁类 kext 清单。
/// 注意：不同机器 / 不同年代的打包，bundle id 前缀五花八门
/// （如 AsusFanSMC 可能是 com.hieplpvip.* / org.acidanthera.* / local.hackintosh.*）。
/// 所以这里只用**稳定关键字**匹配 kextstat 里实际加载的 bundle id，
/// 不再硬编码完整 id —— 这样同一份 App 换台机器也不会误报。
private let knownKexts: [(name: String, category: String, keywords: [String])] = [
    ("VirtualSMC",               "核心(SMC)",      ["VirtualSMC"]),
    ("Lilu",                     "补丁框架",       ["Lilu"]),
    ("WhateverGreen",            "显卡",           ["WhateverGreen"]),
    ("AppleALC",                 "声卡",           ["AppleALC"]),
    ("AMDRyzenCPUPowerManagement","AMD CPU",       ["AMDRyzenCPUPowerManagement"]),
    ("SMCAMDProcessor",          "AMD 传感器",     ["SMCAMDProcessor"]),
    ("AsusFanSMC",               "华硕风扇",       ["AsusFanSMC"]),
    ("SMCBatteryManager",        "电池",           ["SMCBatteryManager"]),
    ("ECEnabler",                "嵌入式控制器",   ["ECEnabler"]),
    ("NVMeFix",                  "NVMe",           ["NVMeFix"]),
    ("CpuFriend",                "CPU 变频",       ["CpuFriend"]),
    ("RestrictEvents",           "事件屏蔽",       ["RestrictEvents"]),
    ("BlueToolFixup",            "蓝牙",           ["BlueToolFixup"]),
    ("IntelMausi",               "网卡",           ["IntelMausi"]),
]

/// kextstat 第 6 列就是 bundle id；逐行解析出所有已加载的 id。
private func loadedBundleIDs(from kextstat: String) -> [String] {
    var ids: [String] = []
    for line in kextstat.components(separatedBy: "\n") {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if f.count >= 6 { ids.append(String(f[5])) }
    }
    return ids
}

private func readKexts(kextstat: String) -> [KextInfo] {
    let loadedIDs = loadedBundleIDs(from: kextstat)
    var result: [KextInfo] = []
    for kext in knownKexts {
        let loaded = loadedIDs.contains { id in
            kext.keywords.contains { kw in id.range(of: kw, options: .caseInsensitive) != nil }
        }
        let version = kextVersion(kext.name)
        let installed = version != nil
        if loaded || installed {
            result.append(KextInfo(name: kext.name, category: kext.category,
                                  version: version ?? "—",
                                  isLoaded: loaded, installed: installed))
        }
    }
    if result.isEmpty {
        result.append(KextInfo(name: "未检测到常见补丁驱动", category: "",
                              version: "", isLoaded: false, installed: false))
    }
    return result
}

/// 在常见 kext 目录里读 CFBundleVersion
private func kextVersion(_ name: String) -> String? {
    let dirs = ["/Library/Extensions",
                "/System/Library/Extensions",
                "/Volumes/EFI/EFI/OC/Kexts"]
    for dir in dirs {
        let plist = "\(dir)/\(name).kext/Contents/Info.plist"
        if let v = Shell.run("/usr/bin/defaults", ["read", plist, "CFBundleVersion"]) {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}
