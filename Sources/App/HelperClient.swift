//
//  HelperClient.swift — 与 root 助手通信，并负责安装 / 卸载
//

import Foundation
import ServiceManagement

/// OC boot-args 里 debug=0x144 的配置状态（供睿频开关使用）
enum OCBootArgStatus: Equatable {
    case unknown
    case noOC       // 没找到已挂载的 OC EFI
    case present    // 已配置
    case missing    // OC 已挂载但缺 debug=0x144
    case configured // 本次刚写入（待重启）
}

@MainActor
final class HelperClient: ObservableObject {

    @Published var isInstalled = false
    @Published var statusText = "未连接"
    @Published var lastError: String?

    // 睿频前置：debug=0x144
    @Published var ocBootArgStatus: OCBootArgStatus = .unknown
    @Published var ocBootArgMessage: String = ""
    /// 安装完成后若检测到缺参数，置 true 由 UI 弹确认框
    @Published var bootArgPromptPending = false

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

    /// 读 CPU 实时频率（MHz）。助手未安装或方法不存在时回调 (0, 原因)
    func readFrequency(completion: @escaping (Double, String) -> Void) {
        guard let proxy = proxy() else {
            completion(0, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.readFrequency { mhz, status in
            completion(mhz, status)
        }
    }

    /// 切换睿频模式。enabled=true 跑满，false 锁默认频率（降温）
    func setBoostMode(enabled: Bool, completion: @escaping (Bool, String) -> Void) {
        proxy()?.setBoostMode(enabled: enabled, reply: completion)
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
        # 装 zenmaster 到固定路径 venv（助手在 LaunchDaemon 最小环境下也能找到，且不受系统 python 版本影响）
        VENV=/Library/PrivilegedHelperTools/zenmaster-venv
        VPY="$VENV/bin/python3"
        if [ ! -x "$VPY" ] || ! "$VPY" -c "import zenmaster" 2>/dev/null; then
          BASE=""
          for cand in /Users/anoxia-m/.workbuddy/binaries/python/versions/3.13.12/bin/python3 \
                      /usr/local/bin/python3 /usr/bin/python3 python3; do
            if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)" 2>/dev/null; then
              BASE="$cand"; break
            fi
          done
          [ -z "$BASE" ] && BASE=python3
          rm -rf "$VENV"
          "$BASE" -m venv "$VENV"
        fi
        "$VPY" -m pip install --quiet --upgrade pip 2>/dev/null
        "$VPY" -m pip install --quiet zenmaster 2>/dev/null || true
        sleep 1
        echo installed
        # 检测 OC boot-args 状态（root，可挂载 EFI）——用于安装后弹窗提示配置 debug=0x144
        BO=""
        for vol in /Volumes/*/EFI/OC/config.plist; do [ -f "$vol" ] && BO="$vol" && break; done
        if [ -z "$BO" ]; then
          MP=/private/tmp/ghelper-efi-$$
          mkdir -p "$MP"
          for disk in $(diskutil list | awk '/EFI/{print $NF}'); do
            diskutil mount "$disk" >/dev/null 2>&1
            for vol in /Volumes/*/EFI/OC/config.plist; do [ -f "$vol" ] && BO="$vol" && break; done
            [ -n "$BO" ] && break
            if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then
              if [ -f "$MP/EFI/OC/config.plist" ]; then BO="$MP/EFI/OC/config.plist"; break; fi
              umount "$MP" 2>/dev/null
            fi
          done
        fi
        if [ -z "$BO" ]; then echo "BOOTARG:NO_OC"
        elif /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$BO" 2>/dev/null | grep -q 'debug=0x144'; then echo "BOOTARG:OK"
        else echo "BOOTARG:MISSING"
        fi
        """

        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                self?.lastError = ok ? nil : out
                self?.refreshStatus()
                // 解析 boot-args 检测结果；缺参数则弹窗确认后配置
                if out.contains("BOOTARG:OK") {
                    self?.ocBootArgStatus = .present
                } else if out.contains("BOOTARG:MISSING") {
                    self?.ocBootArgStatus = .missing
                    self?.bootArgPromptPending = true
                } else if out.contains("BOOTARG:NO_OC") {
                    self?.ocBootArgStatus = .noOC
                }
            }
        }
    }

    // MARK: 睿频前置（debug=0x144）

    /// 用户态检测（只读已挂载卷，不动 EFI）。promptIfMissing=true 时若缺参数则置 bootArgPromptPending
    func checkOCBootArg(promptIfMissing: Bool = false) {
        let script = """
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] || continue
          if /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$vol" 2>/dev/null | grep -q 'debug=0x144'; then
            echo PRESENT; exit 0
          else
            echo MISSING; exit 0
          fi
        done
        echo NO_OC
        """
        runUserScript(script) { [weak self] out in
            Task { @MainActor in
                let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let st: OCBootArgStatus = s == "PRESENT" ? .present
                    : (s == "MISSING" ? .missing : .noOC)
                self?.ocBootArgStatus = st
                if promptIfMissing && st == .missing {
                    self?.bootArgPromptPending = true
                }
            }
        }
    }

    /// 提权写入 debug=0x144 到 OC boot-args（先备份 config.plist）。会挂载未挂载的 EFI 分区。
    func ensureBootArg() {
        let script = """
        PLIST=""
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] && PLIST="$vol" && break
        done
        MP=""
        if [ -z "$PLIST" ]; then
          MP=/private/tmp/ghelper-efi-$$
          mkdir -p "$MP"
          for disk in $(diskutil list | awk '/EFI/{print $NF}'); do
            diskutil mount "$disk" >/dev/null 2>&1
            for vol in /Volumes/*/EFI/OC/config.plist; do
              [ -f "$vol" ] && PLIST="$vol" && break
            done
            [ -n "$PLIST" ] && break
            if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then
              if [ -f "$MP/EFI/OC/config.plist" ]; then
                PLIST="$MP/EFI/OC/config.plist"; break
              fi
              umount "$MP" 2>/dev/null
            fi
          done
        fi
        [ -z "$PLIST" ] && { echo "未找到 OpenCore 的 config.plist（请确认已挂载 EFI 分区）"; exit 1; }
        BDIR="$HOME/Library/Application Support/GHelper/efi-backups"
        mkdir -p "$BDIR"
        TS=$(date +%Y%m%d-%H%M%S)
        cp "$PLIST" "$BDIR/config-$TS.plist"
        export CFG="$PLIST"
        python3 - <<'PY'
        import plistlib, re, os
        data = plistlib.load(open(os.environ['CFG'], 'rb'))
        nv = data.setdefault('NVRAM', {})
        add = nv.setdefault('Add', {})
        uuid = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
        entry = add.setdefault(uuid, {})
        ba = entry.get('boot-args') or ''
        m = re.search(r'debug=0x([0-9a-fA-F]+)', ba)
        if m:
            cur = int(m.group(1), 16)
            new = cur | 0x144
            ba = ba.replace(m.group(0), 'debug=0x%x' % new)
            changed = (new != cur)
        else:
            ba = (ba + ' debug=0x144').strip()
            changed = True
        entry['boot-args'] = ba
        plistlib.dump(data, open(os.environ['CFG'], 'wb'))
        print('OK' if changed else 'ALREADY', ba)
        PY
        """

        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                let message = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if ok {
                    let configured = message.hasPrefix("OK")
                    self?.ocBootArgStatus = configured ? .configured : .present
                    self?.ocBootArgMessage = configured
                        ? "已写入 debug=0x144，请重启生效（备份在 ~/Library/Application Support/GHelper/efi-backups/）"
                        : "debug=0x144 已存在，无需修改"
                } else {
                    self?.ocBootArgStatus = .noOC
                    self?.ocBootArgMessage = "配置失败：\(message)"
                    self?.lastError = message
                }
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

    /// 以当前用户身份跑 shell（无需提权，用于只读检测）
    private func runUserScript(_ shell: String,
                               completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", shell]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            completion(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

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
