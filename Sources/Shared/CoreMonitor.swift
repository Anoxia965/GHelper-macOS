//
//  CoreMonitor.swift — 每逻辑核心（线程）占用率
//
//  用 Mach 的 host_processor_info(PROCESSOR_CPU_LOAD_INFO) 读取每个逻辑 CPU
//  的 user/system/nice/idle 累计 tick，两次采样求差得到瞬时占用。
//  不需要 root。本机 16 物理核 / 32 逻辑线程 → 返回 32 个值。
//

import Foundation
import Darwin

final class CoreMonitor {

    /// 上一次采样（每核 active / total 累计 tick），用于求差
    private var prevActive: [Double] = []
    private var prevTotal:  [Double] = []

    /// 返回每个逻辑核心的占用百分比（0…100），长度 = 逻辑核数
    func sample() -> [Double] {
        var ncpu = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let kr = host_processor_info(mach_host_self(),
                                     PROCESSOR_CPU_LOAD_INFO,
                                     &ncpu, &info, &infoCount)
        guard kr == KERN_SUCCESS, let raw = info, ncpu > 0 else { return [] }

        defer {
            // 释放 Mach 分配的缓冲区
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount))
        }

        let stride = Int(CPU_STATE_MAX)
        var activeNow: [Double] = []
        var totalNow:  [Double] = []

        for i in 0..<Int(ncpu) {
            let base = i * stride
            let user   = Double(raw[base + Int(CPU_STATE_USER)])
            let system = Double(raw[base + Int(CPU_STATE_SYSTEM)])
            let nice   = Double(raw[base + Int(CPU_STATE_NICE)])
            let idle   = Double(raw[base + Int(CPU_STATE_IDLE)])
            let total  = user + system + nice + idle
            activeNow.append(user + system + nice)
            totalNow.append(total)
        }

        // 第一次采样无法求差，先存基线返回空（下一次起才有值）
        if prevActive.isEmpty {
            prevActive = activeNow
            prevTotal  = totalNow
            return Array(repeating: 0, count: activeNow.count)
        }

        var out: [Double] = []
        for i in 0..<activeNow.count {
            let dActive = activeNow[i] - prevActive[i]
            let dTotal  = totalNow[i]  - prevTotal[i]
            let load = dTotal > 0 ? (dActive / dTotal) * 100 : 0
            out.append(min(100, max(0, load)))
        }

        prevActive = activeNow
        prevTotal  = totalNow
        return out
    }
}
