//
//  HelperClient.swift — 与 root 助手通信，并负责安装 / 卸载
//

import Foundation
import ServiceManagement

@MainActor
final class HelperClient: ObservableObject {

    @Published var isInstalled = false
    @Published var statusText = "未连接"
    @Published var lastError: String?

    private var connection: NSXPCConnection?

    // MARK: 连接

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        return conn
    }

    func refreshStatus() {
        connection?.invalidate()
        connection = makeConnection()

        guard let service = connection?.remoteObjectProxyWithErrorHandler({ err in
            Task { @MainActor in
                self.isInstalled = false
                self.statusText = "助手未运行"
            }
        }) as? HelperProtocol else {
            isInstalled = false
            statusText = "助手未运行"
            return
        }

        service.ping { [weak self] info in
            Task { @MainActor in
                self?.isInstalled = true
                self?.statusText = info
            }
        }
    }

    private func proxy() -> HelperProtocol? {
        if connection == nil { connection = makeConnection() }
        guard let conn = connection else { return nil }
        let p = conn.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in
                self?.lastError = err.localizedDescription
                self?.isInstalled = false
            }
        }
        return p as? HelperProtocol
    }

    // MARK: 风扇指令

    func setFanManual(_ index: Int, manual: Bool, completion: @escaping (Bool, String) -> Void) {
        proxy()?.setFanManual(index, manual: manual, reply: completion)
    }

    func setFanTargetRPM(_ index: Int, rpm: Double, completion: @escaping (Bool, String) -> Void) {
        proxy()?.setFanTargetRPM(index, rpm: rpm, reply: completion)
    }

    func writeKey(_ key: String, value: Double, completion: @escaping (Bool, String) -> Void) {
        proxy()?.writeKey(key, value: value, reply: completion)
    }

    // MARK: 安装

    /// 用 osascript 弹系统密码框，一次性把助手装进去
    func install() {
        guard let helper = Bundle.main.path(forAuxiliaryExecutable: "GHelperHelper") else {
            lastError = "在 App 包内找不到 GHelperHelper"
            return
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(kHelperMachServiceName)</string>
            <key>MachServices</key>
            <dict><key>\(kHelperMachServiceName)</key><true/></dict>
            <key>ProgramArguments</key>
            <array><string>\(kHelperInstallPath)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>/var/log/GHelper.helper.log</string>
        </dict>
        </plist>
        """

        let script = """
        mkdir -p /Library/PrivilegedHelperTools
        cp '\(helper)' '\(kHelperInstallPath)'
        chown root:wheel '\(kHelperInstallPath)'
        chmod 755 '\(kHelperInstallPath)'
        cat > '\(kHelperPlistPath)' <<'PLISTEOF'
        \(plist)
        PLISTEOF
        chown root:wheel '\(kHelperPlistPath)'
        chmod 644 '\(kHelperPlistPath)'
        launchctl bootout system/\(kHelperMachServiceName) 2>/dev/null || launchctl unload -w '\(kHelperPlistPath)' 2>/dev/null
        launchctl bootstrap system '\(kHelperPlistPath)' 2>/dev/null || launchctl load -w '\(kHelperPlistPath)'
        sleep 1
        echo installed
        """

        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                self?.lastError = ok ? nil : out
                self?.refreshStatus()
            }
        }
    }

    func uninstall() {
        proxy()?.uninstall { [weak self] ok, msg in
            Task { @MainActor in
                self?.lastError = ok ? nil : msg
                self?.isInstalled = false
                self?.statusText = "未连接"
            }
        }
    }

    // MARK: 开机启动

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = "设置开机启动失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: 提权执行

    private func runAdminScript(_ shell: String,
                                completion: @escaping (Bool, String) -> Void) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let pipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errPipe
            task.launch()
            task.waitUntilExit()

            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            completion(task.terminationStatus == 0,
                       task.terminationStatus == 0 ? out : err)
        }
    }
}
