//
//  SMC.swift — AppleSMC IOKit 读写层
//
//  两个坑（踩过，别改回去）：
//  1. IOConnectCallStructMethod 的 selector 恒为 2（老代码里的 KERNEL_INDEX_SMC），
//     真正的命令码（5=读 / 6=写 / 9=取键信息 / 8=取索引）要写进 data8 字段。
//  2. 结构体里 key 是大端四字符码，但 dataSize 是小端，dataType 的四字符码在内存里是倒序的。
//     所以下面全程用 80 字节原始缓冲区 + 固定偏移，不依赖 Swift 结构体布局。
//

import Foundation
import IOKit

// MARK: - 缓冲区布局偏移

private enum Off {
    static let key       = 0    // UInt32，大端四字符码
    static let dataSize  = 28   // UInt32，小端
    static let dataType  = 32   // UInt32，倒序四字符码
    static let attr      = 36   // UInt8，读写属性
    static let result    = 40   // UInt8
    static let status    = 41   // UInt8
    static let data8     = 42   // UInt8，命令码
    static let data32    = 44   // UInt32
    static let bytes     = 48   // 字节负载
    static let bufSize   = 80
}

// MARK: - 命令码

private enum Cmd {
    static let readBytes: UInt8   = 5
    static let writeBytes: UInt8  = 6
    static let readIndex: UInt8   = 8
    static let readKeyInfo: UInt8 = 9
    static let readPLimit: UInt8  = 11
    static let readVers: UInt8    = 12
}

/// externalMethod 索引，恒为 2
private let kMethodIndex: UInt32 = 2

/// SMC 返回码
public enum SMCResult: UInt8, Error {
    case success          = 0x00
    case keyNotFound      = 0x84  // kSMCKeyNotFound
    case notWritable      = 0x86
    case badParameter     = 0x89
    case spNotSupported   = 0x8b

    var message: String {
        switch self {
        case .success:        return "成功"
        case .keyNotFound:    return "键不存在"
        case .notWritable:    return "键不可写"
        case .badParameter:   return "参数错误"
        case .spNotSupported: return "不支持"
        }
    }
}

// MARK: - 错误

enum SMCError: Error, LocalizedError {
    case serviceNotFound
    case cannotOpen(kern_return_t)
    case callFailed(kern_return_t)
    case smc(SMCResult)
    case badLength(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:         return "找不到 AppleSMC 服务"
        case .cannotOpen(let k):       return "无法打开 AppleSMC (0x\(String(k, radix: 16)))"
        case .callFailed(let k):       return "SMC 调用失败 (0x\(String(k, radix: 16)))"
        case .smc(let r):              return "SMC 返回: \(r.message) (0x\(String(r.rawValue, radix: 16)))"
        case .badLength(let e, let g): return "数据长度不符: 期望 \(e)，实际 \(g)"
        }
    }
}

// MARK: - 键信息

struct SMCKeyInfo {
    let dataSize: Int
    let type: String          // 人类可读，如 "fpe2" / "sp78" / "ui8 "
    let attributes: UInt8

    var isWritable: Bool  { attributes & 0x40 != 0 }
    var isReadable: Bool  { attributes & 0x80 != 0 }
    var isFunction: Bool  { attributes & 0x10 != 0 }
    var isConst: Bool     { attributes & 0x08 != 0 }
    var isPrivateWrite: Bool { attributes & 0x01 != 0 }
    var isPrivateRead: Bool  { attributes & 0x02 != 0 }

    var attributeText: String {
        var p: [String] = []
        if isReadable { p.append("R") } else { p.append("-") }
        if isWritable { p.append("W") } else { p.append("-") }
        if isFunction { p.append("F") }
        if isConst { p.append("C") }
        if isPrivateWrite { p.append("pw") }
        if isPrivateRead { p.append("pr") }
        return p.joined()
    }
}

// MARK: - 核心

final class SMC {
    static let shared = SMC()

    private var conn: io_connect_t = 0
    private var isOpen = false

    private init() {}

    // MARK: 连接

    func open() throws {
        if isOpen { return }

        var master: mach_port_t = 0
        IOMasterPort(0, &master)

        var iter: io_iterator_t = 0
        let mkr = IOServiceGetMatchingServices(master, IOServiceMatching("AppleSMC"), &iter)
        guard mkr == KERN_SUCCESS else { throw SMCError.callFailed(mkr) }

        let service = IOIteratorNext(iter)
        IOObjectRelease(iter)
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }

        var port: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &port)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { throw SMCError.cannotOpen(kr) }

        conn = port
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(conn)
        isOpen = false
    }

    // MARK: 四字符码

    /// 字符串 → 大端 UInt32（"F0Ac" → 0x46304163）
    static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        var c = Array(s.utf8)
        while c.count < 4 { c.append(0x20) }        // 不足 4 位补空格
        for (i, ch) in c.prefix(4).enumerated() {
            v |= UInt32(ch) << (24 - 8 * i)
        }
        return v
    }

    /// UInt32 → 字符串（0x46304163 → "F0Ac"）
    static func fourCCString(_ v: UInt32) -> String {
        var s = ""
        for i in 0..<4 {
            s.append(Character(UnicodeScalar(UInt8((v >> (24 - 8 * i)) & 0xFF))))
        }
        return s
    }

    /// 内存里的 4 字节（小端）→ 可读类型名，如 [0x32,0x65,0x70,0x66] → "fpe2"
    private static func typeString(bytes: [UInt8]) -> String {
        let v = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return fourCCString(v)
    }

    /// 类型名 → 要写进缓冲区的 4 字节（"fpe2" → [0x32,0x65,0x70,0x66]）
    private static func typeBytes(_ type: String) -> [UInt8] {
        let v = fourCC(type)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: 底层调用

    private struct Raw {
        var result: UInt8
        var dataSize: UInt32
        var type: String
        var attributes: UInt8
        var bytes: [UInt8]
    }

    private func call(cmd: UInt8, key: String,
                      dataSize: UInt32? = nil,
                      type: String? = nil,
                      payload: [UInt8]? = nil) throws -> Raw {
        if !isOpen { try open() }

        var input = [UInt8](repeating: 0, count: Off.bufSize)

        // key：四字符码按小端写入（内存里字符顺序是反的，实测验证）
        let k = SMC.fourCC(key)
        input[Off.key + 0] = UInt8(k & 0xFF)
        input[Off.key + 1] = UInt8((k >> 8) & 0xFF)
        input[Off.key + 2] = UInt8((k >> 16) & 0xFF)
        input[Off.key + 3] = UInt8((k >> 24) & 0xFF)

        // 命令码
        input[Off.data8] = cmd

        // dataSize：小端
        if let ds = dataSize {
            input[Off.dataSize + 0] = UInt8(ds & 0xFF)
            input[Off.dataSize + 1] = UInt8((ds >> 8) & 0xFF)
            input[Off.dataSize + 2] = UInt8((ds >> 16) & 0xFF)
            input[Off.dataSize + 3] = UInt8((ds >> 24) & 0xFF)
        }

        // dataType：倒序四字节
        if let t = type {
            let tb = SMC.typeBytes(t)
            for i in 0..<4 { input[Off.dataType + i] = tb[i] }
        }

        // 负载
        if let p = payload {
            for (i, b) in p.enumerated() where i < 32 { input[Off.bytes + i] = b }
        }

        var output = [UInt8](repeating: 0, count: Off.bufSize)
        var outCnt = Off.bufSize

        let kr = IOConnectCallStructMethod(conn, kMethodIndex,
                                           &input, Off.bufSize,
                                           &output, &outCnt)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }

        // result：非 0 即为 SMC 层错误
        let result = output[Off.result]
        if let r = SMCResult(rawValue: result), r != .success { throw SMCError.smc(r) }
        if result != 0 { throw SMCError.badLength(expected: 0, got: 0) }

        let size = UInt32(output[Off.dataSize + 0]) |
                   UInt32(output[Off.dataSize + 1]) << 8 |
                   UInt32(output[Off.dataSize + 2]) << 16 |
                   UInt32(output[Off.dataSize + 3]) << 24
        let typeStr = SMC.typeString(bytes: Array(output[Off.dataType..<(Off.dataType + 4)]))

        return Raw(result: result, dataSize: size, type: typeStr,
                   attributes: output[Off.attr],
                   bytes: Array(output[Off.bytes..<(Off.bytes + 32)]))
    }

    // MARK: 公开读接口

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        let r = try call(cmd: Cmd.readKeyInfo, key: key)
        return SMCKeyInfo(dataSize: Int(r.dataSize), type: r.type, attributes: r.attributes)
    }

    /// 键是否存在
    func exists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func readRaw(_ key: String) throws -> (data: Data, type: String) {
        let info = try keyInfo(key)
        let r = try call(cmd: Cmd.readBytes, key: key, dataSize: UInt32(info.dataSize))
        let n = min(Int(info.dataSize), 32)
        return (Data(r.bytes.prefix(n)), info.type)
    }

    /// 读取并解码为 Double；不存在或解码失败返回 nil
    func readDouble(_ key: String) -> Double? {
        guard let (data, type) = try? readRaw(key) else { return nil }
        return SMC.decode(data: data, type: type)
    }

    func readString(_ key: String) -> String? {
        guard let (data, _) = try? readRaw(key) else { return nil }
        return String(data: data, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 公开写接口

    func writeRaw(_ key: String, data: Data, type: String? = nil) throws {
        let info = try keyInfo(key)
        let t = type ?? info.type
        guard data.count == info.dataSize else {
            throw SMCError.badLength(expected: info.dataSize, got: data.count)
        }
        _ = try call(cmd: Cmd.writeBytes, key: key,
                     dataSize: UInt32(data.count), type: t, payload: [UInt8](data))
    }

    func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeRaw(key, data: Data([value]), type: "ui8 ")
    }

    /// fpe2 定点小数：value × 4 取整
    func writeFPE2(_ key: String, _ value: Double) throws {
        let raw = UInt16(max(0, min(16383.75, value)) * 4)
        try writeRaw(key, data: Data([UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]), type: "fpe2")
    }

    // MARK: 枚举

    /// 先读 #KEY 拿到键总数，再用命令码 8 逐个取回键名
    func allKeys() -> [String] {
        guard let count = readDouble("#KEY") else { return [] }
        var keys: [String] = []
        for i in 0..<Int(count) {
            var input = [UInt8](repeating: 0, count: Off.bufSize)
            input[Off.data8] = Cmd.readIndex
            input[Off.data32 + 0] = UInt8(i & 0xFF)
            input[Off.data32 + 1] = UInt8((i >> 8) & 0xFF)
            input[Off.data32 + 2] = UInt8((i >> 16) & 0xFF)
            input[Off.data32 + 3] = UInt8((i >> 24) & 0xFF)

            var output = [UInt8](repeating: 0, count: Off.bufSize)
            var outCnt = Off.bufSize
            let kr = IOConnectCallStructMethod(conn, kMethodIndex,
                                               &input, Off.bufSize, &output, &outCnt)
            guard kr == KERN_SUCCESS, output[Off.result] == 0 else { continue }
            let v = UInt32(output[Off.key + 0]) | UInt32(output[Off.key + 1]) << 8 |
                    UInt32(output[Off.key + 2]) << 16 | UInt32(output[Off.key + 3]) << 24
            keys.append(SMC.fourCCString(v))
        }
        return keys
    }

    // MARK: 探测

    /// 按候选键逐个试探（枚举不可用时的兜底）
    func probeKeys(_ candidates: [String]) -> [(key: String, type: String, value: Double?)] {
        var out: [(String, String, Double?)] = []
        for k in candidates {
            if let (data, type) = try? readRaw(k) {
                out.append((k, type, SMC.decode(data: data, type: type)))
            }
        }
        return out
    }

    // MARK: 解码

    static func decode(data: Data, type: String) -> Double? {
        guard data.count >= 1 else { return nil }
        func u16() -> UInt16 {
            guard data.count >= 2 else { return 0 }
            return UInt16(data[0]) << 8 | UInt16(data[1])
        }
        func u32() -> UInt32 {
            guard data.count >= 4 else { return 0 }
            return UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                   UInt32(data[2]) << 8  | UInt32(data[3])
        }
        switch type {
        case "ui8 ": return Double(data[0])
        case "si8 ": return Double(Int8(bitPattern: data[0]))
        case "ui16": return Double(u16())
        case "si16": return Double(Int16(bitPattern: u16()))
        case "ui32": return Double(u32())
        case "si32": return Double(Int32(bitPattern: u32()))
        case "fpe2": return Double(u16()) / 4.0
        case "sp1e": return Double(u16()) / 16384.0
        case "sp3c": return Double(u16()) / 1024.0
        case "sp4b": return Double(u16()) / 512.0
        case "sp5a": return Double(u16()) / 2048.0
        case "sp69": return Double(u16()) / 512.0
        case "sp78": return Double(Int16(bitPattern: u16())) / 256.0
        case "sp87": return Double(Int16(bitPattern: u16())) / 128.0
        case "sp96": return Double(Int16(bitPattern: u16())) / 64.0
        case "spb4": return Double(Int16(bitPattern: u16())) / 16.0
        case "spf0": return Double(Int16(bitPattern: u16())) / 65536.0
        case "flt ": return Double(Float(bitPattern: u32()))
        case "pwm ": return Double(u16()) / 65536.0 * 100.0
        default:
            switch data.count {
            case 1: return Double(data[0])
            case 2: return Double(u16())
            case 4: return Double(u32())
            default: return nil
            }
        }
    }
}
