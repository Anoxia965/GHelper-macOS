//
//  PeripheralMonitor.swift — ROG 外设 HID 探测（只枚举，不写设备）
//
//  目的：本机无 ROG 外设实物，无法验证具体控制命令。先做一版「探测 + 诊断」
//  发给用户测试，把 VID 0x0B05 (ASUSTek) 的 HID 接口、PID、usage 等信息导出，
//  再按型号从上游 GHelper 的 Peripherals 模块移植协议。
//
//  ⚠️ 安全约束：本文件只调用 IOHIDManagerCopyDevices / IOHIDDeviceGetProperty，
//  绝不 IOHIDDeviceSetReport / IOHIDDeviceGetReport（不读写 report），
//  不打开独占、不写板载内存、不触发任何设备固件操作。
//
//  上游实现参考：seerge/g-helper 用 HidSharp 枚举 VID 0x0B05，
//  对每个型号发私有 64 字节 HID 命令。协议本身跨平台，macOS 用户态可做。
//

import Foundation
import IOKit.hid

// MARK: - 设备信息

struct ASUSPeripheral: Identifiable, Hashable {
    let id: String
    let vendorID: Int
    let productID: Int
    let productName: String
    let manufacturer: String
    let serialNumber: String
    let primaryUsagePage: Int
    let primaryUsage: Int
    let locationID: Int
    let reportDescriptorBytes: Int

    var vidHex: String { String(format: "0x%04X", vendorID) }
    var pidHex: String { String(format: "0x%04X", productID) }

    /// Omni 是华硕 2.4G 多设备接收器：键鼠都挂在同一个 PID 下，
    /// 靠不同 collection（col01/col02/col03）区分，上游 GHelper 有专门处理。
    var isOmniReceiver: Bool { productID == 0x1ACE }

    var category: String {
        if primaryUsagePage == 1 {           // Generic Desktop
            switch primaryUsage {
            case 2:  return L("鼠标")
            case 6:  return L("键盘")
            default: return L("桌面设备")
            }
        }
        if primaryUsagePage == 12 { return L("多媒体") }   // Consumer
        if primaryUsagePage == 13 { return L("游戏设备") } // Game
        return "\(L("其他")) 0x\(String(format: "%02X", primaryUsagePage))"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - 底层扫描（非隔离，可在后台队列跑）

/// 枚举 VID 0x0B05 的全部 HID 接口，只读属性。
private func scanASUSHIDDevices() -> (devices: [ASUSPeripheral], error: String?) {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let match: [String: Any] = [kIOHIDVendorIDKey: 0x0B05]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    let openError = openResult == kIOReturnSuccess
        ? nil : "IOHIDManagerOpen returned \(openResult)"

    guard let set = IOHIDManagerCopyDevices(manager) else {
        return ([], openError ?? "IOHIDManagerCopyDevices returned nil")
    }

    let count = CFSetGetCount(set)
    guard count > 0 else { return ([], openError) }

    var raw = [UnsafeRawPointer?](repeating: nil, count: count)
    CFSetGetValues(set, &raw)

    var result: [ASUSPeripheral] = []
    for pointer in raw {
        guard let pointer else { continue }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()

        let vid = hidInt(device, kIOHIDVendorIDKey) ?? 0
        let pid = hidInt(device, kIOHIDProductIDKey) ?? 0
        let usagePage = hidInt(device, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = hidInt(device, kIOHIDPrimaryUsageKey) ?? 0
        let location = hidInt(device, kIOHIDLocationIDKey) ?? 0
        let name = hidString(device, kIOHIDProductKey) ?? "Unknown"
        let maker = hidString(device, kIOHIDManufacturerKey) ?? "—"
        let serial = hidString(device, kIOHIDSerialNumberKey) ?? "—"

        var descriptorBytes = 0
        if let data = IOHIDDeviceGetProperty(device,
                                             kIOHIDReportDescriptorKey as CFString) as? Data {
            descriptorBytes = data.count
        }

        let id = String(format: "%08X-%04X-%02X-%02X",
                        location, pid, usagePage, usage)
        result.append(ASUSPeripheral(id: id,
                                     vendorID: vid, productID: pid,
                                     productName: name, manufacturer: maker,
                                     serialNumber: serial,
                                     primaryUsagePage: usagePage, primaryUsage: usage,
                                     locationID: location,
                                     reportDescriptorBytes: descriptorBytes))
    }
    result.sort { ($0.vendorID, $0.productID, $0.id) < ($1.vendorID, $1.productID, $1.id) }
    return (result, openError)
}

private func hidInt(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return (value as? NSNumber)?.intValue
}

private func hidString(_ device: IOHIDDevice, _ key: String) -> String? {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return value as? String
}

// MARK: - 可观察状态

@MainActor
final class PeripheralMonitor: ObservableObject {
    @Published private(set) var devices: [ASUSPeripheral] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "cn.anoxia.GHelper.peripheral", qos: .utility)

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        queue.async { [weak self] in
            let result = scanASUSHIDDevices()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.devices = result.devices
                self.lastError = result.error
                self.lastScan = Date()
                self.isScanning = false
            }
        }
    }

    /// 用户可复制发给开发者的诊断文本。只含设备标识，不含隐私数据。
    var diagnosticText: String {
        var lines: [String] = []
        lines.append("GHelper peripheral diagnostic")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("Scan time: \(lastScan.map { formatter.string(from: $0) } ?? "never")")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Filter: VID 0x0B05 (ASUSTek)")
        if let error = lastError { lines.append("Warning: \(error)") }
        lines.append("HID interfaces: \(devices.count)")
        for (index, device) in devices.enumerated() {
            lines.append("")
            lines.append("[\(index + 1)] \(device.productName)")
            lines.append("  VID/PID: \(device.vidHex) / \(device.pidHex)")
            lines.append("  Manufacturer: \(device.manufacturer)")
            lines.append("  Serial: \(device.serialNumber)")
            lines.append("  Usage: page \(device.primaryUsagePage), id \(device.primaryUsage) [\(device.category)]")
            lines.append("  Location: 0x\(String(format: "%08X", device.locationID))")
            lines.append("  Report descriptor: \(device.reportDescriptorBytes) bytes")
            if device.isOmniReceiver { lines.append("  Note: Omni 2.4G receiver") }
            lines.append("  Interface ID: \(device.id)")
        }
        if devices.isEmpty {
            lines.append("")
            lines.append("No ASUS HID interface found. Connect the device and rescan.")
        }
        return lines.joined(separator: "\n")
    }
}
