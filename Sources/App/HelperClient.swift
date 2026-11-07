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

    /// 助手自报版本（install 时写入 /Library/PrivilegedHelperTools/.ghelper-helper-version）
    @Published var helperVersion: String = ""
    /// 助手版本是否与当前 App 版本匹配（不匹配则应在合适时机重装，消除「更新后功能静默失效」）
    @Published var helperOutdated: Bool = false
    /// 安装过程中的提示（如 kext 需批准+重启），供 UI 展示
    @Published var installMessage: String? = nil

    // 睿频前置：debug=0x144
    @Published var ocBootArgStatus: OCBootArgStatus = .unknown
    @Published var ocBootArgMessage: String = ""
    /// 安装完成后若检测到缺参数，置 true 由 UI 弹确认框
    @Published var bootArgPromptPending = false
    /// 预览（DRYRUN）结果文本，确认弹窗展示
    @Published var bootArgPreviewText: String = ""
    /// 预览完成后置 true，弹「确认修改」框（二次确认，避免误操作损坏 EFI）
    @Published var bootArgConfirmPending = false

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
                self?.probeHelperVersion()
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

    /// 通用 WMNB 直通（经助手 → rgbctl → GHRGB kext）。用于读取风扇曲线缓存与调试。
    func callWMNB(sig: UInt32, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                 completion: @escaping (Bool, String) -> Void) {
        guard let proxy = proxy() else {
            completion(false, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.callWMNB(sig: sig, devid: devid, a1: a1, a2: a2, a3: a3, a4: a4, reply: completion)
    }

    /// 经 WMNB 写风扇自定义曲线并接管（替代 SMC 手动模式）。
    /// devid: 0x00110024=CPU 风扇 / 0x00110025=GPU 风扇；a1..a4 为 asus-wmi 打包的 8 点曲线。
    func setFanCurve(_ index: Int, devid: UInt32, a1: UInt32, a2: UInt32, a3: UInt32, a4: UInt32,
                     completion: @escaping (Bool, String) -> Void) {
        guard let proxy = proxy() else {
            completion(false, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.setFanCurve(index, devid: devid, a1: a1, a2: a2, a3: a3, a4: a4, reply: completion)
    }

    /// 把某把扇交回固件自动（写回出厂曲线；未缓存时退回 SMC Md=0）。
    func releaseFanCurve(_ index: Int, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = proxy() else {
            completion(false, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.releaseFanCurve(index, reply: completion)
    }

    /// 维持 WMNB 风扇看门狗心跳（不改变曲线，仅刷新助手侧 lastCommand）。
    func keepFanAlive(_ index: Int, completion: @escaping (Bool, String) -> Void) {
        guard let proxy = proxy() else {
            completion(false, "特权助手未连接，请到设置页重装")
            return
        }
        proxy.keepFanAlive(index, reply: completion)
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
    /// configureEFI=false 用于后台自动重装（助手版本同步）：只装助手，绝不碰 EFI、不弹确认框。
    func install(configureEFI: Bool = true) {
        // 显式拼 App 包内路径，不依赖 Info.plist 的 SMAuxiliaryExecutables 声明
        // （当前 Info.plist 未声明该键，forAuxiliaryExecutable 可能返回 nil 导致安装失败）
        let helperURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("GHelperHelper")
        guard let helper = helperURL?.path,
              FileManager.default.isExecutableFile(atPath: helper) else {
            lastError = "在 App 包内找不到 GHelperHelper（应为 Contents/MacOS/GHelperHelper）"
            return
        }
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

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
          KERR=$(mktemp /tmp/ghelper_kext.XXXXXX)
          if kmutil load -p /Library/Extensions/GHRGB.kext -z 2>"$KERR"; then
            echo "GHRGB kext loaded"
          else
            echo "KEXTMSG:GHRGB 未即时加载（正常现象）。请到『系统设置 ▸ 隐私与安全性』批准 GHRGB，再重启生效。详情: $(head -c 200 "$KERR" | tr '\n' ' ')"
          fi
          rm -f "$KERR"
        fi
        cat > '\(kHelperPlistPath)' <<'PLISTEOF'
        \(plist)
        PLISTEOF
        chown root:wheel '\(kHelperPlistPath)'
        chmod 644 '\(kHelperPlistPath)'
        launchctl bootout system/\(kHelperMachServiceName) 2>/dev/null || launchctl unload -w '\(kHelperPlistPath)' 2>/dev/null
        launchctl bootstrap system '\(kHelperPlistPath)' 2>/dev/null || launchctl load -w '\(kHelperPlistPath)'
        # 记录助手版本，供 App 判断是否需要重装（与当前 App 版本比对）
        echo '\(appVersion)' > /Library/PrivilegedHelperTools/.ghelper-helper-version
        echo "helper-version:\(appVersion)"
        # 装 zenmaster 到固定路径 venv（助手在 LaunchDaemon 最小环境下也能找到，且不受系统 python 版本影响）
        VENV=/Library/PrivilegedHelperTools/zenmaster-venv
        VPY="$VENV/bin/python3"
        if [ ! -x "$VPY" ] || ! "$VPY" -c "import zenmaster" 2>/dev/null; then
          BASE=""
          for cand in /usr/local/bin/python3 /usr/bin/python3 python3 \
                      /Users/anoxia-m/.workbuddy/binaries/python/versions/3.13.12/bin/python3; do
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
        # 安装阶段只做「只读预览」（DRYRUN），绝不写入 EFI。
        # ad-hoc 签名的特权助手在 macOS 15 严格 SIP/AMFI 下需要三件套，但任何 EFI 改动都必须
        # 先让用户看到将要改哪几份、点确认后才由 ensureBootArg() 写入（见下方回调）。
        \(configureEFI ? efiWriteScript(dryrun: true) : "echo 'efi-preview:skipped'")
        """

        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                self?.lastError = ok ? nil : out
                // do shell script 回传的换行可能是 \r，用 .newlines 统一切分，避免提示丢失
                if let m = out.components(separatedBy: .newlines).first(where: { $0.hasPrefix("KEXTMSG:") }) {
                    self?.installMessage = String(m.dropFirst("KEXTMSG:".count))
                }
                self?.refreshStatus()
                // 安装阶段只做了只读预览；是否写入 EFI 完全交给用户二次确认。
                // 后台自动重装（configureEFI=false）不解析、不弹框、不碰 EFI。
                guard configureEFI else { return }
                if !ok {
                    self?.ocBootArgMessage = "系统前置预览失败：\(out)（EFI 未被改动）"
                    return
                }
                let p = self?.parseEFIPreview(out) ?? HelperClient.EFIPreview()
                self?.bootArgPreviewText = "安装已完成（特权助手、灯控驱动均已就位）。\n\n" + p.text
                if p.total == 0 {
                    self?.ocBootArgStatus = .noOC
                    self?.ocBootArgMessage = "未找到 OC 的 config.plist，EFI 未被改动。若是白果，请手动确保 AMFI/SIP 放行未签名代码。"
                } else if p.needConfirm {
                    // 关键：只有用户点「确认添加」才会真正写入 EFI，此处绝不自动写
                    self?.ocBootArgStatus = .missing
                    self?.ocBootArgMessage = "系统前置待确认：请留意弹窗，确认后才会写入 EFI（重启生效）。"
                    self?.bootArgConfirmPending = true
                } else {
                    self?.ocBootArgStatus = .present
                    self?.ocBootArgMessage = "系统前置参数已齐备，EFI 无需改动。"
                }
            }
        }
    }

    // MARK: 助手版本探测与自动重装

    /// ping 成功后用独立连接探测助手自报版本。旧版助手不支持 helperVersion 方法时调用会超时，
    /// 据此判定为「版本过旧需重装」——从而一键更新 App 后也能自愈，不再静默失效。
    /// 版本不符则延迟自动重装（弹一次密码框）；用户取消则由 UI 提示手动点「安装/重装」。
    private func probeHelperVersion() {
        let expected = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let probe = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        probe.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        probe.resume()
        var got = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !got else { return }
            probe.invalidate()
            self.helperVersion = "legacy"
            self.helperOutdated = true
            self.scheduleAutoReinstall()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        (probe.remoteObjectProxy as? HelperProtocol)?.helperVersion { [weak self] v in
            got = true
            timeout.cancel()
            probe.invalidate()
            Task { @MainActor in
                guard let self else { return }
                self.helperVersion = v
                self.helperOutdated = (v != expected)
                if self.helperOutdated { self.scheduleAutoReinstall() }
            }
        }
    }

    private var autoReinstallTriggered = false
    /// 助手版本过旧时延迟触发一次重装（弹密码框）。进程内只触发一次，避免重复弹窗。
    private func scheduleAutoReinstall() {
        guard !autoReinstallTriggered else { return }
        autoReinstallTriggered = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // 后台版本同步只更新助手二进制：不碰 EFI、不弹 EFI 确认框，
            // 避免用户没主动安装时突然弹出「要改启动参数」的窗口。
            self?.install(configureEFI: false)
        }
    }

    // MARK: 睿频前置（debug=0x144）

    /// 用户态检测（只读已挂载卷，含 U 盘，不动 EFI）：扫所有 OC，检查系统前置三件套是否齐备。
    /// 任意一份缺任一项即视为未配置（missing）；无任何 OC 则 noOC。
    /// promptIfMissing=true 时若缺参数则置 bootArgPromptPending
    func checkOCBootArg(promptIfMissing: Bool = false) {
        let script = """
        ANY=0; DBG=1; AMFI=1; CSR=1
        uuid=7C436110-AB2A-4BBB-A880-FE41995C9F82
        for vol in /Volumes/*/EFI/OC/config.plist; do
          [ -f "$vol" ] || continue
          ANY=1
          ba=$(/usr/libexec/PlistBuddy -c "Print :NVRAM:Add:$uuid:boot-args" "$vol" 2>/dev/null)
          echo "$ba" | grep -q 'debug=0x144' || DBG=0
          echo "$ba" | grep -q 'amfi_get_out_of_my_way=0x1' || AMFI=0
          csr=$(/usr/libexec/PlistBuddy -c "Print :NVRAM:Add:$uuid:csr-active-config" "$vol" 2>/dev/null)
          [ -n "$csr" ] || CSR=0
        done
        if [ "$ANY" = 0 ]; then echo "PREREQ:NO_OC"
        elif [ "$DBG" = 1 ] && [ "$AMFI" = 1 ] && [ "$CSR" = 1 ]; then echo "PREREQ:OK"
        else echo "PREREQ:MISSING"
        fi
        """
        runUserScript(script) { [weak self] out in
            Task { @MainActor in
                let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let st: OCBootArgStatus
                if s.contains("PREREQ:NO_OC") { st = .noOC }
                else if s.contains("PREREQ:OK") { st = .present }
                else { st = .missing }
                self?.ocBootArgStatus = st
                if promptIfMissing && st == .missing {
                    self?.bootArgPromptPending = true
                }
            }
        }
    }

    // MARK: 统一的 EFI 系统前置写入（debug=0x144 + AMFI 放行 + csr-active-config）
    // 解决：ad-hoc 签名的特权助手在 macOS 15 严格 SIP/AMFI 下无法被 launchd 加载，
    // 导致 App 连不上助手、风扇/灯光控制全部失效（监控读数不受影响）。
    // 扫描所有 OC（内置盘 + U 盘，含未挂载 EFI），逐份备份后写入三件套，输出 SUMMARY 供 UI 解析。

    /// 通用：收集所有 OC config.plist 路径。
    /// 关键安全点：已挂载的卷直接采用，绝不重复挂载（double-mount 会让同一 FAT 卷被挂两次且都读写，
    /// 改写文件时极易损坏 EFI 文件系统，表现为 EFI/OC 目录整体丢失）。
    /// 仅对当前未挂载的 EFI 分区用 `diskutil mount` 挂一次，并记录我们新挂载的分区号以便末尾卸载。
    private let ocConfigCollector: String = """
    collect_oc_configs() {
      out="$1"; usfile="${2:-}"; : > "$out"
      # 必须同时清空「本次自己挂载的分区」列表：否则末尾可能按陈旧记录
      # 卸载到用户自己挂载的 EFI 卷（违背「只卸载自己挂的」）。
      [ -n "$usfile" ] && : > "$usfile"
      seen=""
      for vol in /Volumes/*/EFI/OC/config.plist; do
        [ -f "$vol" ] || continue
        echo "$seen" | grep -qxF "$vol" && continue
        seen="$seen
    $vol"; echo "$vol" >> "$out"
      done
      for disk in $(diskutil list | awk '$2=="EFI"{print $NF}'); do
        mp=$(diskutil info "$disk" 2>/dev/null | awk -F': ' '/Mount Point/{print $2}' | xargs)
        if [ -z "$mp" ] || [ "$mp" = "-" ]; then
          if diskutil mount "$disk" >/dev/null 2>&1; then
            mp=$(diskutil info "$disk" 2>/dev/null | awk -F': ' '/Mount Point/{print $2}' | xargs)
            [ -n "$mp" ] && [ "$mp" != "-" ] && [ -n "$usfile" ] && echo "$disk" >> "$usfile"
          fi
        fi
        if [ -n "$mp" ] && [ "$mp" != "-" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
          echo "$seen" | grep -qxF "$mp/EFI/OC/config.plist" && continue
          seen="$seen
    $mp/EFI/OC/config.plist"; echo "$mp/EFI/OC/config.plist" >> "$out"
        fi
      done
    }
    """

    /// 统一的 EFI 启动参数写入脚本（dryrun=true 时只预览不改写）。
    /// 写入三件套：debug=0x144（按位 OR）+ AMFI 放行（amfi_get_out_of_my_way=0x1 amfi=0x80）+ csr-active-config=430A0000。
    /// 安全要点：见 ocConfigCollector（不重复挂载）；改写后 plist 保留原格式并 plutil -lint 校验。
    private func efiWriteScript(dryrun: Bool) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dry = dryrun ? "1" : "0"
        return ocConfigCollector + """
        CFGOUT=/private/tmp/ghelper-cfg-$$.txt
        USOUT=/private/tmp/ghelper-us-$$.txt
        collect_oc_configs "$CFGOUT" "$USOUT"
        export BDIR="\(home)/Library/Application Support/GHelper/efi-backups"
        export DRYRUN="\(dry)"
        mkdir -p "$BDIR"
        export TS=$(date +%Y%m%d-%H%M%S)
        python3 - <<'PY'
        import plistlib, os, shutil, re, subprocess
        paths=[p for p in open(os.environ['CFGOUT']).read().split('\\n') if p.strip()]
        # inode 去重（同一份 config 可能经多条路径命中）
        seen=set(); uniq=[]
        for p in paths:
            try: st=os.stat(p)
            except OSError: continue
            k=(st.st_dev, st.st_ino)
            if k in seen: continue
            seen.add(k); uniq.append(p)
        uuid='7C436110-AB2A-4BBB-A880-FE41995C9F82'
        AMFI=['amfi_get_out_of_my_way=0x1','amfi=0x80']
        CSR=bytes([0x43,0x0a,0x00,0x00])
        dryrun = os.environ.get('DRYRUN','0')=='1'
        bdir=os.environ['BDIR']; ts=os.environ['TS']
        wrote=unchanged=amfi_added=csr_added=0
        would=0
        for i,path in enumerate(uniq,1):
            comps=path.strip('/').split('/')
            label=comps[-4].replace(' ','_') if len(comps)>=4 else 'cfg'
            raw=open(path,'rb').read()
            fmt = plistlib.FMT_BINARY if raw[:6]==b'bplist' else plistlib.FMT_XML
            data=plistlib.loads(raw)
            nv=data.setdefault('NVRAM',{})
            add=nv.setdefault('Add',{})
            entry=add.setdefault(uuid,{})
            ba=entry.get('boot-args') or ''
            m=re.search(r'debug=0x([0-9a-fA-F]+)', ba)
            newba=ba
            if m:
                cur=int(m.group(1),16); nvv=cur|0x144
                if nvv!=cur:
                    newba=ba.replace(m.group(0),'debug=0x%x'%nvv)
            else:
                newba=(ba+' debug=0x144').strip()
            for f in AMFI:
                if f not in newba:
                    newba=(newba+' '+f).strip(); amfi_added+=1
            entry['boot-args']=newba
            csr_add=False
            if entry.get('csr-active-config') is None:
                entry['csr-active-config']=CSR; csr_add=True; csr_added+=1
            changed = (newba!=ba) or csr_add
            if dryrun:
                # 只列出「确实需要改」的配置，已配齐的不打扰用户
                if changed:
                    would+=1
                    print('DRYRUN %s'%path)
                    print('DRYRUN   boot-args: %r -> %r'%(ba,newba))
                    if csr_add: print('DRYRUN   csr-active-config: (none) -> 430A0000')
                continue
            if changed:
                shutil.copy(path, os.path.join(bdir,'config-%s-%d-%s.plist'%(ts,i,label)))
                # 安全写入：先写同目录临时文件 -> plutil 校验 -> 原子替换。
                # 任何一步失败都删掉临时文件、保留原 config.plist 完好，绝不留下半写坏的文件。
                tmp = path + '.ghelper-tmp'
                try:
                    with open(tmp,'wb') as f:
                        plistlib.dump(data, f, fmt=fmt)
                    r=subprocess.run(['plutil','-lint',tmp],capture_output=True,text=True)
                    if r.returncode!=0:
                        print('PLISTERR %s %s'%(path,r.stdout.strip()))
                        os.remove(tmp)
                        continue
                    os.replace(tmp, path)
                    wrote+=1
                except Exception as e:
                    print('PLISTERR %s %s'%(path,e))
                    try: os.remove(tmp)
                    except OSError: pass
            else:
                unchanged+=1
        print('WOULDWRITE %d'%would)
        print('SUMMARY %d %d %d %d %d'%(wrote,unchanged,len(uniq),amfi_added,csr_added))
        PY
        sync
        for d in $(cat "$USOUT" 2>/dev/null); do
          diskutil unmount "$d" >/dev/null 2>&1 || { sleep 1; diskutil unmount "$d" >/dev/null 2>&1; }
        done
        rm -f "$CFGOUT" "$USOUT"
        """
    }

    /// 提权写入「系统前置三件套」到所有 OpenCore 的 boot-args / NVRAM（内置盘 + U 盘），
    /// 每份先备份 config.plist。会挂载未挂载的 EFI 分区；同一份配置按 inode 去重只处理一次。
    /// 输出一行 `SUMMARY <写入> <未变> <总数> <amfi 新增> <csr 新增>` 供 UI 解析。
    func ensureBootArg() {
        let script = efiWriteScript(dryrun: false)
        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                let message = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if ok {
                    var wrote = 0, already = 0, total = 0
                    for line in message.components(separatedBy: .newlines) {
                        guard line.hasPrefix("SUMMARY") else { continue }
                        let parts = line.components(separatedBy: .whitespacesAndNewlines)
                            .filter { !$0.isEmpty }
                        if parts.count >= 5 {
                            wrote = Int(parts[1]) ?? 0
                            already = Int(parts[2]) ?? 0
                            total = Int(parts[3]) ?? 0
                        }
                    }
                    if total == 0 {
                        self?.ocBootArgStatus = .noOC
                        self?.ocBootArgMessage = "未找到 OpenCore 的 config.plist（内置盘与 U 盘均未发现）。若是白果或非 OC 引导，请手动确保 AMFI/SIP 已放行未签名代码，否则风扇/灯光控制将无法加载特权助手。"
                    } else if wrote > 0 {
                        self?.ocBootArgStatus = .configured
                        var msg = "已写入系统前置（debug=0x144 + AMFI 放行 + csr-active-config，共 \(wrote)/\(total) 份 OC 配置，含 U 盘）"
                        if already > 0 { msg += "，另 \(already) 份本来已有" }
                        msg += "。请重启生效（备份在 ~/Library/Application Support/GHelper/efi-backups/）"
                        self?.ocBootArgMessage = msg
                    } else {
                        self?.ocBootArgStatus = .present
                        self?.ocBootArgMessage = "共 \(total) 份 OC 配置（含 U 盘）均已含系统前置参数，无需修改"
                    }
                } else {
                    self?.ocBootArgStatus = .noOC
                    self?.ocBootArgMessage = "配置失败：\(message)"
                    self?.lastError = message
                }
            }
        }
    }

    /// DRYRUN 输出解析结果（只读预览，绝不写入 EFI）。
    struct EFIPreview {
        var text: String = ""       /// 供二次确认弹窗展示的正文
        var wouldWrite: Int = 0     /// 实际需要改动的 OC 配置份数
        var total: Int = 0          /// 扫描到的 OC 配置总份数
        var needConfirm: Bool { wouldWrite > 0 }
    }

    /// 从 efiWriteScript(dryrun:) 的输出里解析预览。
    /// 安装流程与手动「系统前置」按钮共用，保证两处确认逻辑完全一致。
    /// 混杂的其它脚本输出（installed / KEXTMSG / helper-version 等）会被忽略。
    private func parseEFIPreview(_ out: String) -> EFIPreview {
        var p = EFIPreview()
        var lines: [String] = []
        for ln in out.components(separatedBy: .newlines) {
            if ln.hasPrefix("DRYRUN ") {
                lines.append(String(ln.dropFirst("DRYRUN ".count)))
            } else if ln.hasPrefix("WOULDWRITE ") {
                p.wouldWrite = Int(ln.dropFirst("WOULDWRITE ".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            } else if ln.hasPrefix("SUMMARY ") {
                let parts = ln.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                if parts.count >= 4 { p.total = Int(parts[3]) ?? 0 }
            }
        }
        if p.total == 0 {
            p.text = "未找到任何 OpenCore 配置（内置盘与 U 盘均未发现 EFI/OC/config.plist），无需改动 EFI。若是白果或非 OC 引导，请手动确保 AMFI/SIP 放行未签名代码。"
        } else if p.wouldWrite == 0 {
            p.text = "扫描到 \(p.total) 份 OpenCore 配置，系统前置参数均已齐备，无需改动 EFI。"
        } else {
            p.text = "即将修改以下 \(p.wouldWrite) 份 OpenCore 配置（共扫描到 \(p.total) 份）：\n"
                + lines.joined(separator: "\n")
                + "\n\n每份改动前会先备份 config.plist，写入采用临时文件 + 校验 + 原子替换。"
                + "\n确认后写入：debug=0x144 + amfi_get_out_of_my_way=0x1 + amfi=0x80 + csr-active-config=430A0000，需重启生效。"
                + "\n\n此时 EFI 尚未被改动；点「取消」则完全不写入。点「确认添加」会再请求一次管理员密码（这是写入 EFI 的独立提权）。"
        }
        return p
    }

    /// 预览（DRYRUN）将要修改的 OC 配置，列出具体文件与目标值，供二次确认。
    /// 由 UI 的「现在添加」触发；确认后再调 ensureBootArg() 真正写入。
    func previewBootArg() {
        bootArgPromptPending = false
        let script = efiWriteScript(dryrun: true)
        runAdminScript(script) { [weak self] ok, out in
            Task { @MainActor in
                guard let self else { return }
                let p = self.parseEFIPreview(ok ? out : "")
                self.bootArgPreviewText = p.text
                if !ok {
                    self.ocBootArgStatus = .noOC
                    self.ocBootArgMessage = "预览失败：\(out)"
                    self.lastError = out
                    return
                }
                if p.total == 0 { self.ocBootArgStatus = .noOC }
                // 只有确实需要改动才弹二次确认；已配齐时不打扰用户
                self.bootArgConfirmPending = p.needConfirm
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
          mp=$(diskutil info "$disk" 2>/dev/null | awk -F': ' '/Mount Point/{print $2}' | xargs)
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
        let script = ocConfigCollector + """
        SRC='\(src)'
        BDIR="\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Application Support/GHelper/efi-backups"
        mkdir -p "$BDIR"
        TS=$(date +%Y%m%d-%H%M%S)
        CFGOUT=/private/tmp/ghelper-kext-cfg-$$.txt
        USOUT=/private/tmp/ghelper-kext-us-$$.txt
        collect_oc_configs "$CFGOUT" "$USOUT"
        export PLISTS=$(cat "$CFGOUT")
        export SRC BDIR TS
        python3 - <<'PY'
        import plistlib, os, shutil, glob, subprocess
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
            raw = open(p, 'rb').read()
            fmt = plistlib.FMT_BINARY if raw[:6] == b'bplist' else plistlib.FMT_XML
            cfg = plistlib.loads(raw)
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
            # 与 efiWriteScript 一致：临时文件 -> plutil 校验 -> 原子替换，绝不半写坏 config.plist
            tmp = p + '.ghelper-tmp'
            try:
                with open(tmp, 'wb') as f:
                    plistlib.dump(cfg, f, fmt=fmt)
                r = subprocess.run(['plutil', '-lint', tmp], capture_output=True, text=True)
                if r.returncode != 0:
                    print('PLISTERR %s %s' % (p, r.stdout.strip()))
                    os.remove(tmp)
                    continue
                os.replace(tmp, p)
            except Exception as e:
                print('PLISTERR %s %s' % (p, e))
                try: os.remove(tmp)
                except OSError: pass
        print('SUMMARY %d %d %d' % (copied, enabled, total))
        PY
        sync
        for d in $(cat "$USOUT" 2>/dev/null); do
          diskutil unmount "$d" >/dev/null 2>&1 || { sleep 1; diskutil unmount "$d" >/dev/null 2>&1; }
        done
        rm -f "$CFGOUT" "$USOUT"
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
