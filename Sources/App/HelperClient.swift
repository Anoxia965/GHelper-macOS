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
        # 检测 OC boot-args 状态（root，可挂载 EFI，含 U 盘）——扫所有 OC，任意一份缺参数就提示
        BO_ANY=0; BO_MISS=0
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] || continue
          BO_ANY=1
          /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$vol" 2>/dev/null | grep -q 'debug=0x144' || BO_MISS=1
        done
        MP=/private/tmp/ghelper-efi-$$
        mkdir -p "$MP"
        for disk in $(diskutil list | awk '/EFI/{print $NF}'); do
          diskutil mount "$disk" >/dev/null 2>&1
          for vol in /Volumes/*/EFI/OC/config.plist; do
            [ -f "$vol" ] || continue
            BO_ANY=1
            /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$vol" 2>/dev/null | grep -q 'debug=0x144' || BO_MISS=1
          done
          if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then
            if [ -f "$MP/EFI/OC/config.plist" ]; then
              BO_ANY=1
              /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$MP/EFI/OC/config.plist" 2>/dev/null | grep -q 'debug=0x144' || BO_MISS=1
            fi
            umount "$MP" 2>/dev/null
          fi
        done
        if [ "$BO_ANY" = 0 ]; then echo "BOOTARG:NO_OC"
        elif [ "$BO_MISS" = 1 ]; then echo "BOOTARG:MISSING"
        else echo "BOOTARG:OK"
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

    /// 用户态检测（只读已挂载卷，含 U 盘，不动 EFI）：扫所有 OC，任意一份缺参数即 MISSING。
    /// promptIfMissing=true 时若缺参数则置 bootArgPromptPending
    func checkOCBootArg(promptIfMissing: Bool = false) {
        let script = """
        ANY=0; MISS=0
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] || continue
          ANY=1
          if /usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$vol" 2>/dev/null | grep -q 'debug=0x144'; then
            :
          else
            MISS=1
          fi
        done
        if [ "$ANY" = 0 ]; then echo NO_OC
        elif [ "$MISS" = 1 ]; then echo MISSING
        else echo PRESENT
        fi
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

    /// 提权写入 debug=0x144 到**所有** OpenCore 的 boot-args（内置盘 + U 盘），
    /// 每份先备份 config.plist。会挂载未挂载的 EFI 分区；同一份配置按 inode 去重只处理一次。
    /// 输出一行 `SUMMARY <写入> <已有> <总数>` 供 UI 解析。
    func ensureBootArg() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        PLISTS=""
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] && PLISTS="$PLISTS
        $vol"
        done
        MPBASE=/private/tmp/ghelper-efi-$$
        mkdir -p "$MPBASE"
        MPS=""
        for disk in $(diskutil list | awk '/EFI/{print $NF}'); do
          MP="$MPBASE/$disk"
          mkdir -p "$MP"
          if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then
            MPS="$MPS $MP"
            [ -f "$MP/EFI/OC/config.plist" ] && PLISTS="$PLISTS
        $MP/EFI/OC/config.plist"
          else
            diskutil mount "$disk" >/dev/null 2>&1
            for vol in /Volumes/*/EFI/OC/config.plist; do
              [ -f "$vol" ] && PLISTS="$PLISTS
        $vol"
            done
          fi
        done
        export CFGS="$PLISTS"
        export BDIR="\(home)/Library/Application Support/GHelper/efi-backups"
        mkdir -p "$BDIR"
        export TS=$(date +%Y%m%d-%H%M%S)
        python3 - <<'PY'
        import plistlib, re, os, shutil
        raw = [p for p in os.environ.get('CFGS', '').split('\\n') if p.strip()]
        seen, paths = set(), []
        for p in raw:
            try:
                st = os.stat(p)
            except OSError:
                continue
            key = (st.st_dev, st.st_ino)
            if key in seen:
                continue
            seen.add(key)
            paths.append(p)
        bdir, ts = os.environ['BDIR'], os.environ['TS']
        wrote = already = 0
        for i, path in enumerate(paths, 1):
            comps = path.strip('/').split('/')
            label = comps[-4].replace(' ', '_') if len(comps) >= 4 else 'cfg'
            shutil.copy(path, os.path.join(bdir, 'config-%s-%d-%s.plist' % (ts, i, label)))
            data = plistlib.load(open(path, 'rb'))
            nv = data.setdefault('NVRAM', {})
            add = nv.setdefault('Add', {})
            uuid = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
            entry = add.setdefault(uuid, {})
            ba = entry.get('boot-args') or ''
            m = re.search(r'debug=0x([0-9a-fA-F]+)', ba)
            if m:
                cur = int(m.group(1), 16)
                new = cur | 0x144
                ba2 = ba.replace(m.group(0), 'debug=0x%x' % new)
                changed = (new != cur)
            else:
                ba2 = (ba + ' debug=0x144').strip()
                changed = True
            if changed:
                entry['boot-args'] = ba2
                plistlib.dump(data, open(path, 'wb'))
                wrote += 1
            else:
                already += 1
        print('SUMMARY %d %d %d' % (wrote, already, len(paths)))
        PY
        for m in $MPS; do umount "$m" 2>/dev/null; done
        rm -rf "$MPBASE" 2>/dev/null
        """

        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                let message = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if ok {
                    var wrote = 0, already = 0, total = 0
                    for line in message.components(separatedBy: .newlines) {
                        guard line.hasPrefix("SUMMARY") else { continue }
                        let parts = line.split(separator: " ")
                        if parts.count >= 4 {
                            wrote = Int(parts[1]) ?? 0
                            already = Int(parts[2]) ?? 0
                            total = Int(parts[3]) ?? 0
                        }
                    }
                    if total == 0 {
                        self?.ocBootArgStatus = .noOC
                        self?.ocBootArgMessage = "未找到 OpenCore 的 config.plist（内置盘与 U 盘均未发现）"
                    } else if wrote > 0 {
                        self?.ocBootArgStatus = .configured
                        var msg = "已写入 debug=0x144（\(wrote)/\(total) 份 OC 配置，含 U 盘）"
                        if already > 0 { msg += "，另 \(already) 份本来已有" }
                        msg += "。请重启生效（备份在 ~/Library/Application Support/GHelper/efi-backups/）"
                        self?.ocBootArgMessage = msg
                    } else {
                        self?.ocBootArgStatus = .present
                        self?.ocBootArgMessage = "共 \(total) 份 OC 配置（含 U 盘）均已有 debug=0x144，无需修改"
                    }
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
