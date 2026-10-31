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
