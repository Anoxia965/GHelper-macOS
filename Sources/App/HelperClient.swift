//
//  HelperClient.swift — 与 root 助手通信，并负责安装 / 卸载
//

import Foundation
import ServiceManagement
import SwiftUI

/// OC boot-args 里 debug=0x144 的配置状态（供睿频开关使用）
enum OCBootArgStatus: Equatable {
    case unknown
    case noOC       // 没找到已挂载的 OC EFI
    case present    // 已配置
    case missing    // OC 已挂载但缺 debug=0x144
    case configured // 本次刚写入（待重启）
}

// MARK: - EFI / 驱动管理用数据结构

/// 一个 EFI 系统分区（ESP）的扫描结果
struct EFIPartition: Identifiable, Equatable {
    let id: String            // disk identifier，如 "disk1s4"
    let isMounted: Bool
    let mountPoint: String    // 已挂载时为 /Volumes/xxx，否则空
    let hasOC: Bool           // 该卷下是否存在 EFI/OC/config.plist
    let volumeName: String
}

/// 单个核心驱动在 EFI 内的状态
struct DriverStatus: Identifiable {
    let id = UUID()
    let name: String          // 如 "VirtualSMC.kext"
    let presentInEFI: Bool    // EFI/OC/Kexts/<name> 文件存在
    let enabledInConfig: Bool // config Kernel/Add 有且 Enabled
    let loaded: Bool          // 运行时已加载（kextstat）
    var ok: Bool { presentInEFI && enabledInConfig }
    var statusText: String {
        if loaded { return "已加载" }
        if presentInEFI && enabledInConfig { return "已安装·待重启" }
        if presentInEFI { return "文件在·未启用" }
        return "缺失"
    }
    var dotColor: Color {
        ok ? .green : (presentInEFI ? .orange : .red)
    }
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

    // MARK: 键盘 RGB

    /// 设置键盘 RGB 灯光（经 root 助手 → rgbctl → GHRGB kext）。
    func applyKeyboardLighting(r: Int, g: Int, b: Int, mode: Int,
                              brightness: Int, speed: Int,
                              completion: @escaping (Bool, String) -> Void) {
        guard let proxy = proxy() else {
            completion(false, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.applyKeyboardLighting(r: r, g: g, b: b, mode: mode,
                                   brightness: brightness, speed: speed,
                                   reply: completion)
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
        # 灯光：rgbctl（用户态工具）→ /usr/local/bin；GHRGB.kext → /Library/Extensions 并加载
        RGBCTL_SRC="$(dirname '\(helper)')/rgbctl"
        KEXT_SRC="$(dirname '\(helper)')/../Resources/GHRGB.kext"
        if [ -x "$RGBCTL_SRC" ]; then
          cp "$RGBCTL_SRC" /usr/local/bin/rgbctl
          chmod 755 /usr/local/bin/rgbctl
          echo "rgbctl installed"
        fi
        if [ -d "$KEXT_SRC" ]; then
          rm -rf /Library/Extensions/GHRGB.kext
          cp -R "$KEXT_SRC" /Library/Extensions/GHRGB.kext
          chown -R root:wheel /Library/Extensions/GHRGB.kext
          kmutil load -p /Library/Extensions/GHRGB.kext -z 2>/dev/null || true
          echo "GHRGB kext installed (reboot may be required)"
        fi
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

    // MARK: - EFI / 驱动管理

    @Published var efiPartitions: [EFIPartition] = []
    @Published var driverStatuses: [DriverStatus] = []
    @Published var efiMessage: String = ""
    @Published var efiWorking = false

    /// 随 App 打包的核心驱动（Install 时作为来源拷贝到 EFI/OC/Kexts）。
    /// 顺序即期望的 Kernel/Add 加载顺序（依赖：Lilu → VirtualSMC → AMDRyzen → SMCAMDProcessor → AsusFanSMC）。
    private let coreKexts = [
        "Lilu.kext",
        "VirtualSMC.kext",
        "AMDRyzenCPUPowerManagement.kext",
        "SMCAMDProcessor.kext",
        "AsusFanSMC.kext",
    ]

    /// 扫描所有 EFI 分区（用户态只读）。列出每个分区的挂载状态与是否含 OC，随后自动检测驱动。
    func scanEFI() {
        efiWorking = true
        efiMessage = "正在扫描 EFI 分区…"
        let script = """
        diskutil list | awk '/EFI/{print $NF}' | while read disk; do
          mp=$(diskutil info "$disk" 2>/dev/null | awk -F': ' '/Mount Point/{print $2}')
          [ "$mp" = "-" ] && mp=""
          hasoc=0; [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ] && hasoc=1
          vol=$([ -n "$mp" ] && basename "$mp" || echo "")
          echo "$disk|$([ -n "$mp" ] && echo 1 || echo 0)|${mp}|$hasoc|${vol}"
        done
        """
        runUserScript(script) { [weak self] out in
            Task { @MainActor in
                guard let self else { return }
                var parts: [EFIPartition] = []
                for line in out.components(separatedBy: .newlines) where !line.isEmpty {
                    let f = line.components(separatedBy: "|")
                    guard f.count >= 5 else { continue }
                    parts.append(EFIPartition(
                        id: f[0],
                        isMounted: f[1] == "1",
                        mountPoint: f[2],
                        hasOC: f[3] == "1",
                        volumeName: f[4]))
                }
                self.efiPartitions = parts
                self.efiWorking = false
                if parts.isEmpty {
                    self.efiMessage = "未发现 EFI 分区（diskutil list 无 EFI 类型）。"
                } else {
                    self.efiMessage = "找到 \(parts.count) 个 EFI 分区；含 OC 的已可操作，正在检测驱动…"
                    self.detectKexts()
                }
            }
        }
    }

    /// 提权挂载指定 EFI 分区（优先 diskutil mount，失败回退 mount_msdos 到受控目录）。
    func mountEFI(disk: String) {
        efiWorking = true
        efiMessage = "正在挂载 \(disk)…"
        let script = """
        disk="\(disk)"
        if diskutil mount "$disk" 2>/dev/null; then
          echo OK
        else
          MP=/private/tmp/ghelper-efi-mount/$(echo "$disk" | tr '/' '_')
          mkdir -p "$MP"
          if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then echo OK; else echo FAIL; fi
        fi
        """
        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                guard let self else { return }
                self.efiWorking = false
                if ok && !out.contains("FAIL") {
                    self.efiMessage = "\(disk) 已挂载，正在重新检测…"
                    self.scanEFI()
                } else {
                    self.efiMessage = "挂载 \(disk) 失败（需要管理员密码，且分区须为 FAT32）。也可在「磁盘工具」手动挂载后重新扫描。"
                }
            }
        }
    }

    /// 检测已挂载 OC 里 5 个核心 kext 的状态（文件存在 / config 启用 / 运行时加载）。用户态。
    func detectKexts() {
        efiWorking = true
        efiMessage = "正在检测驱动…"
        let coreList = coreKexts.joined(separator: " ")
        let script = """
        python3 - <<'PY'
        import plistlib, os, subprocess, glob
        core = '\(coreList)'.split()
        try:
            ks = subprocess.check_output(['kextstat'], text=True)
        except Exception:
            ks = ''
        def is_loaded(name):
            kw = name.replace('.kext', '')
            return any(kw in l for l in ks.splitlines())
        for vol in glob.glob('/Volumes/*/EFI/OC/config.plist'):
            d = os.path.dirname(os.path.dirname(os.path.dirname(vol)))
            kexts_dir = os.path.join(d, 'EFI/OC/Kexts')
            try:
                cfg = plistlib.load(open(vol, 'rb'))
            except Exception:
                continue
            add = cfg.get('Kernel', {}).get('Add', [])
            enabled = {e.get('BundlePath'): e.get('Enabled', False) for e in add}
            for name in core:
                present = os.path.isdir(os.path.join(kexts_dir, name))
                en = bool(enabled.get(name, False))
                print('|'.join([name, '1' if present else '0', '1' if en else '0', '1' if is_loaded(name) else '0']))
        PY
        """
        runUserScript(script) { [weak self] out in
            Task { @MainActor in
                guard let self else { return }
                self.efiWorking = false
                var statuses: [DriverStatus] = []
                for line in out.components(separatedBy: .newlines) where !line.isEmpty {
                    let f = line.components(separatedBy: "|")
                    guard f.count >= 4 else { continue }
                    statuses.append(DriverStatus(
                        name: f[0],
                        presentInEFI: f[1] == "1",
                        enabledInConfig: f[2] == "1",
                        loaded: f[3] == "1"))
                }
                self.driverStatuses = statuses
                if statuses.isEmpty {
                    self.efiMessage = "未找到已挂载且含 OC 的 EFI 卷，无法检测驱动。请先挂载含 OC 的 EFI 分区。"
                } else {
                    let missing = statuses.filter { !$0.ok }.count
                    self.efiMessage = missing == 0
                        ? "5 个核心驱动齐全且已启用 ✓"
                        : "有 \(missing) 个核心驱动缺失或未启用，可点「一键补齐」。"
                }
            }
        }
    }

    /// 一键补齐缺失的核心驱动：拷贝缺失 kext 到 EFI/OC/Kexts，并在 config Kernel/Add 添加/启用条目（处理依赖顺序），
    /// 每份 config 改动前自动备份。需管理员密码（提权）。
    func installMissingKexts() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("Kexts").path,
              FileManager.default.fileExists(atPath: src) else {
            efiMessage = "App 包内未找到 Kexts 资源，无法自动安装。请重新下载带驱动的安装包。"
            return
        }
        efiWorking = true
        efiMessage = "正在补齐缺失驱动（需管理员密码）…"
        let coreList = coreKexts.joined(separator: " ")
        let script = """
        SRC='\(src)'
        BDIR="$HOME/Library/Application Support/GHelper/efi-backups"
        mkdir -p "$BDIR"
        TS=$(date +%Y%m%d-%H%M%S)
        PLISTS=""
        for vol in /Volumes/*/EFI/OC/config.plist; do [ -f "$vol" ] && PLISTS="$PLISTS
        $vol"; done
        MPBASE=/private/tmp/ghelper-efi-$$
        mkdir -p "$MPBASE"
        for disk in $(diskutil list | awk '/EFI/{print $NF}'); do
          MP="$MPBASE/$disk"
          mkdir -p "$MP"
          if mount_msdos "/dev/$disk" "$MP" 2>/dev/null; then
            [ -f "$MP/EFI/OC/config.plist" ] && PLISTS="$PLISTS
        $MP/EFI/OC/config.plist"
          else
            diskutil mount "$disk" >/dev/null 2>&1
            for vol in /Volumes/*/EFI/OC/config.plist; do [ -f "$vol" ] && PLISTS="$PLISTS
        $vol"; done
          fi
        done
        export PLISTS SRC BDIR TS
        python3 - <<'PY'
        import plistlib, os, shutil, glob
        src = os.environ['SRC']
        bdir = os.environ['BDIR']
        ts = os.environ['TS']
        core = '\(coreList)'.split()
        plists = [p for p in os.environ['PLISTS'].split('\\n') if p.strip()]
        seen = set(); paths = []
        for p in plists:
            try:
                st = os.stat(p)
            except OSError:
                continue
            k = (st.st_dev, st.st_ino)
            if k in seen:
                continue
            seen.add(k); paths.append(p)
        copied = 0; enabled = 0; total = len(paths)
        for i, p in enumerate(paths, 1):
            d = os.path.dirname(os.path.dirname(os.path.dirname(p)))
            kdir = os.path.join(d, 'EFI/OC/Kexts')
            os.makedirs(kdir, exist_ok=True)
            cfg = plistlib.load(open(p, 'rb'))
            add = cfg.setdefault('Kernel', {}).setdefault('Add', [])
            en = {e.get('BundlePath'): e for e in add}
            for name in core:
                src_k = os.path.join(src, name)
                dst_k = os.path.join(kdir, name)
                if os.path.isdir(src_k) and not os.path.isdir(dst_k):
                    shutil.copytree(src_k, dst_k)
                    copied += 1
                if name in en:
                    if not en[name].get('Enabled', False):
                        en[name]['Enabled'] = True; enabled += 1
                else:
                    add.append({'Arch': 'Any', 'BundlePath': name, 'Comment': '',
                                'Enabled': True, 'ExecutablePath': 'Contents/MacOS/' + os.path.splitext(name)[0],
                                'PlistPath': 'Contents/Info.plist', 'MinKernel': '', 'MaxKernel': ''})
                    enabled += 1
            core_entries = [e for e in add if e.get('BundlePath') in core]
            others = [e for e in add if e.get('BundlePath') not in core]
            core_entries.sort(key=lambda e: core.index(e['BundlePath']))
            cfg['Kernel']['Add'] = core_entries + others
            shutil.copy(p, os.path.join(bdir, 'config-%s-%d.plist' % (ts, i)))
            plistlib.dump(cfg, open(p, 'wb'))
        print('SUMMARY %d %d %d' % (copied, enabled, total))
        PY
        """
        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                guard let self else { return }
                self.efiWorking = false
                if ok {
                    var copied = 0, enabled = 0, total = 0
                    for line in out.components(separatedBy: .newlines) where line.hasPrefix("SUMMARY") {
                        let parts = line.split(separator: " ")
                        if parts.count >= 4 {
                            copied = Int(parts[1]) ?? 0
                            enabled = Int(parts[2]) ?? 0
                            total = Int(parts[3]) ?? 0
                        }
                    }
                    self.efiMessage = "已处理 \(total) 份 OC 配置（拷贝 \(copied) 个驱动、启用/修复 \(enabled) 条）。请重启使驱动生效；备份在 ~/Library/Application Support/GHelper/efi-backups/。"
                    self.scanEFI()
                } else {
                    self.efiMessage = "安装失败：\(out)"
                }
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
