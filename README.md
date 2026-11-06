# GHelper for macOS

把 Windows 上华硕笔记本的 **GHelper** 风扇 / 传感器控制，**用原生 Swift 重写**成 macOS 菜单栏 App，面向 **黑苹果（Hackintosh）** 用户。
不是把 `GHelper.exe` 搬过来，而是重新实现了它最核心的能力：读传感器、按温度控风扇、独立控制 CPU / GPU 风扇。

> 当前针对 **华硕 ROG + AMD Ryzen（MacBookPro16,4 SMBIOS）** 的机器调校并实测；风扇控制核心是**与 CPU 品牌无关的**（优先走华硕 EC/WMNB 直连通道，兜底走 AppleSMC 读写），
> Intel 机型的兄弟下载下来改改温度来源 / 风扇后端也能用，欢迎一起完善（见文末「Intel 机型 / 一起参与开发」）。

---

## 功能一览

- **菜单栏常驻 + 独立窗口**：点菜单栏风扇图标弹快速面板——一眼看全 CPU 型号/温度/占用/频率、核心占用网格、每把风扇转速、显卡温度与占用，**单页不滚动**；点 Dock 图标或面板上的「窗口」按钮打开大窗口（关窗不退出）。
- **每把风扇独立控制**：CPU 风扇（fan0）和 GPU 风扇（fan1）各自可选
  - 模式：**固件自动 / 自定义曲线 / 固定转速**
  - 温度来源（非自动时）：CPU(SMC) / GPU / 电池 / CPU 占用率
  - **限制最高转速**：可开「限制最高转速」开关并填目标 RPM（默认 CPU 7500 / GPU 7000，压在额定以下），开启后曲线 / 固定转速 / SMC 兜底全部夹到上限以下
  - **恢复默认曲线**：曲线调乱了一键还原
- **传感器监控**：CPU / GPU 温度、CPU / GPU 占用率、CPU 实时频率、电池温度与循环次数、每把风扇的实际/目标转速与占空比。
- **硬件信息页**：自动探测 macOS 版本、SMBIOS、CPU、内存、PCI 显卡、OpenCore、SIP、SMC 后端、kext 加载状态等（读不到显示「—」，不写死本机信息）。
- **CPU 温度校准**：AMD 的 Tctl 往往偏高，设置里用偏移滑块现场校准（默认 0）。
- **频率显示**：CPU 实时频率（经 root 助手跑 `powermetrics` 读取，能看到真实 boost 频率）。显卡显示型号、显存、**GPU 温度与占用**（NVIDIA 机型经 [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 驱动可读取，含核心/显存占用细分）；GPU **核心频率**在 macOS 下物理读不到，诚实标注「不适用」，不影响温度/占用监控。
- **键盘 RGB 灯光**：华硕键盘 RGB（经 `GHRGB` 内核驱动 → ACPI WMNB 通道）→ 在「灯光」标签页选颜色 + 亮度（0–3）即时下发。颜色与亮度已真机验证；呼吸/彩虹等特效按协议下发，本机未逐一验证。需要 root 助手与 `GHRGB.kext`（随 App 安装自动装入 `/Library/Extensions`）。

---

## 系统要求

- macOS（项目在 macOS 26.x 上开发实测）。
- 黑苹果引导环境：**OpenCore + VirtualSMC**（不是 AppleSMC）。
- 风扇控制需要 **AsusFanSMC**（华硕主板风扇键 `F0`/`F1`）；CPU 温度：AMD 需要 `SMCAMDProcessor`，Intel 走 VirtualSMC 自带键。
- 白苹果没有 AsusFanSMC，风扇控制不可用，但监控与硬件信息页仍可用。
- **NVIDIA 显卡想看 GPU 温度 / 占用**：需额外安装 **NullMoth** 驱动（NVAccel）。已装则 App 自动读取；未装则显卡卡显示「—」，属正常降级（不影响其它监控）。

---

## 安装（按步骤来）

> 本教程默认你用 **OpenCore（OC）** 引导——我们通用的做法。下面所有 kext / config 步骤都按 OpenCore 说明，不涉及其它引导器。

### 第 0 步：准备

- 一台用 OpenCore 引导的黑苹果（已装 VirtualSMC）。
- **华硕主板**（风扇控制需要 AsusFanSMC）；**AMD CPU** 还需两个 AMD kext（下面随附）。
- 管理员密码（安装助手时会用到）。
- 先**备份整个 EFI 分区**（改 EFI 前必做）。

> ⚠️ **双系统注意**：若 Windows + macOS 双系统，**两块盘各有独立的 EFI 分区**。备份时请分别挂载、各存一份，别把 Windows 的 ESP 当「多余的」清掉；做引导修复时也别让 `bcdboot` / `bootrec` 把引导写错目标盘。`GHelper` 只动 macOS 这一侧 EFI，不会碰 Windows ESP。

### 第 1 步：下载

到 [Releases](https://github.com/Anoxia965/GHelper-macOS/releases) 下载：

| 文件 | 内容 |
| --- | --- |
| `GHelper.pkg` | **安装包**（双击按提示装到 `/Applications`，内含 `GHelper.app` + 所需驱动 `Kexts/`） |
| `Kexts.zip` | 只想要驱动时下载：VirtualSMC、Lilu、AsusFanSMC、SMCAMDProcessor、AMDRyzenCPUPowerManagement |

> 想自己编译源码，见文末「从源码构建」。

### 第 2 步：把驱动装进 EFI（最关键）

OpenCore 在开机时会自动**注入**这些 kext，所以**不能**装到 `/Library/Extensions`，必须放进 EFI：

1. 挂载 EFI 分区（OC 引导盘上的 `EFI` 卷）。
2. 解压 `Kexts.zip`，把里面 5 个 `.kext` 复制到 `EFI/OC/Kexts/`。
   （若已有同名或更新版本，保留你自己的即可。）
3. 让它们进入 OC 的注入列表（`config.plist` 的 `Kernel → Add`）：
   - 用 **ProperTree** 打开 `EFI/OC/config.plist` → 菜单 `File ▸ OC Snapshot`（⌘R）；或
   - 用 **OCAT**（OpenCore Auxiliary Tools）打开后点「更新 / 保存」。
4. **AMD 用户**：确认 `AMDRyzenCPUPowerManagement.kext` 排在 `SMCAMDProcessor.kext` **之前**（顺序反了会读不到 CPU 温度）。
5. **睿频开关前置（v1.3.0+）**：想用 App 里的「睿频开关（开=跑满 / 关=锁基础频率降温）」，OC 的 `NVRAM → Add → 7C436110-…:boot-args` 需含 `debug=0x144`。App 内点「安装 / 重装」会自动检测并补上；手动装驱动的用户请自己确认已加。
6. 保存并重启。

> ⚠️ 只是在你现有 EFI 上**追加**这几个 kext，别动其它部分。

### 第 3 步：安装 App

1. 双击 `GHelper.pkg`，按提示安装到 `/Applications`（驱动已在安装包的 `Kexts/` 里，见第 2 步）。
2. 打开 App。若被 Gatekeeper 拦住：右键「打开」，或在终端执行
   ```bash
   xattr -dr com.apple.quarantine /Applications/GHelper.app
   ```
3. 进「设置」页，点 **安装特权助手**（输入管理员密码）。这会把 root 助手装成开机自启的守护进程（`/Library/LaunchDaemons/cn.anoxia.GHelper.helper.plist`，`RunAtLoad + KeepAlive`）。
4. 按系统弹窗授予「辅助功能 / 全盘访问」等权限（App 需要读传感器和硬件信息）。

> 以后改完代码重新 `./build.sh` 后，需重新覆盖 `/Applications` 里的 App（或点 App 内「重装助手」），因为自启指向的是 `/Applications` 路径。

### 第 4 步：验证

打开 App 的「硬件信息」页，确认：

- `VirtualSMC`、`AsusFanSMC` 显示「已加载」
- AMD 机器还能看到 `SMCAMDProcessor` 已加载

看到这些，风扇控制与温度监控就可用了。

### 检查更新 / 一键更新

- 设置页点 **检查更新**，App 会去 GitHub Releases 看有没有新版本（启动时也会静默查一次，有新版顶部会亮角标）。
- 发现新版点 **下载并更新**：自动下载安装包 → **删掉旧安装（移到废纸篓）** → 装新版 → 重启。更新后如驱动有变，再点「安装 / 重装」助手即可。
- **以后发新版**：往 GitHub 打 tag 发 Release、附上 `GHelper.pkg` 即可，用户端点「检查更新」就能收到。

---

## 怎么用（快速上手）

- **菜单栏图标**：点开是快速面板——CPU 型号 / 温度 / 占用 / 频率、核心占用网格、风扇转速、显卡温度与占用，都在一屏内（不滚动）；切风扇模式、开「展开到独立窗口」也在这里。
- **大窗口**：点 Dock 图标或面板上的「窗口」按钮打开；关窗不退出，只隐藏。
- **独立控制**：CPU 风扇和 GPU 风扇各选模式与温度来源；非自动模式下用滑块或曲线编辑器设定转速，并可开「限制最高转速」把转速压在额定以下；曲线调乱了点「恢复默认曲线」一键还原。
- **校准**：CPU 温度偏高就在设置里拉 `cpuTempOffset` 偏移。

---

## 它是怎么工作的（架构）

```
GHelper.app  (菜单栏 + 窗口，普通用户进程)
   │  NSXPCConnection  ── mach 服务 cn.anoxia.GHelper.helper
   ▼
cn.anoxia.GHelper.helper  (root LaunchDaemon)
   ├─ 风扇写：GHRGB kext → ACPI WMNB / EC 直连（优先）或 AppleSMC IOConnectCallStructMethod (selector=2) 兜底
   ▼
华硕 EC / AppleSMC  ←→  物理风扇
```

为什么需要 root 助手：AppleSMC 的**写操作**只允许特权进程（否则返回 `kIOReturnNotReady`），而风扇写优先走的 **ACPI WMNB/EC 直连通道**也要经内核驱动（`GHRGB.kext`）做特权 ioctl，所以「写风扇转速」都经 XPC 转发给 root 助手执行。

助手带 **15 秒看门狗**：App 超过 15 秒没续心跳（比如崩了），助手自动把风扇**交回固件自动**，避免卡在低转速过热。这是安全兜底，请勿移除。

---

## 风扇控制要点（实测）

- **占空比是 0–100 百分比，不是 0–255**：本机固件风扇曲线约定占空比 1–100，实测出厂曲线占空比字节即 `[1,6,10,15,20,23,28,90]`。App 按此下发，切忌按 0–255 写（会把 50% 写成 128，被固件夹到满速）。无需再折腾 `-asusfanpct`（该 bootarg 本机实测无效）。
- **风扇爬升很慢**：改完设定后要等约 **30–45 秒** 才到稳态，别以为没生效。
- **两把扇都走 WMNB/EC 直连通道接管**（CPU=0x00110024 / GPU=0x00110025，经 GHRGB kext 通用选择器 4），手动 / 曲线 / 自动均可；GHRGB kext 未加载或 rgbctl 缺失时自动退回 SMC（`F{i}Md`/`F{i}Tg`）兜底。
- **GPU 风扇现在也能正常控速**：之前在 SMC 通道下切手动会停转，改走 WMNB 曲线下发（与 Windows GHelper 同款机制）后两把扇都能平滑接管。
- **限制最高转速**：每把扇可开「限制最高转速」开关并填目标 RPM（默认 CPU 7500 / GPU 7000，压在额定 F0Mx=7800 / F1Mx=7400 以下）；开启后曲线 / 固定转速 / SMC 兜底全部夹到上限以下（多留 3% 余量，确保不突破）。
- **实测最高转速**：CPU 空闲~3200、100% 占空比稳态≈7300（F0Mx=7800）；GPU 空闲~2100、100% 占空比≈6500+（F1Mx=7400，仍在爬升）。想要原生 7000+ 转需 ≥80% 触发固件 Turbo，由固件按温度调度（App 不强制）。

---

## Intel 机型 / 一起参与开发

风扇控制的核心是**通用的**：App 通过华硕 EC/WMNB 直连通道（由 `GHRGB.kext` 提供）或 AppleSMC（由 VirtualSMC 提供）读写风扇键，与 CPU 是 AMD 还是 Intel 无关。
不同点只在「温度从哪读、风扇键叫什么」：

- **Intel + 华硕主板**：`AsusFanSMC` 同样适用（按主板走），风扇控制基本开箱即用；CPU 温度走 VirtualSMC 自带键，不需要那两个 AMD kext。
- **Intel + 非华硕主板**：通常没有 `AsusFanSMC` 的 `F0/F1` 键，需要接入别的风扇后端（如主板 EC / 其它 SMC 键）。这正是要补的地方。
- **温度来源扩展**：Intel 可接 `Intel Power Gadget` 或 VirtualSMC 的 `TC0P` 等键，改 `Sources/Shared/Sensors.swift` 的 `TempSource` 解析即可。

**代码里的「硬件抽象缝」（方便接手）：**
- `Sources/Shared/Hardware.swift` — 探测系统/硬件/kext 加载状态，已用**关键字匹配** kext，不写死 bundle ID。
- `Sources/Shared/Sensors.swift` — `FanState.index`（0=CPU / 1=GPU）、`TempSource` 定义与解析。
- `Sources/App/FanCurve.swift` — `FanRole`（cpu/gpu，映射 F0/F1）、`FanControl`（模式/温度来源/曲线，Codable）。
- `Sources/App/AppModel.swift` — 全局状态、`temperature(for:)`、`applyNow()` 下发、看门狗、`cpuTempOffset` 校准。

想加 Intel 支持，主要做三件事：①在 `Sensors.swift` 增加 Intel 温度来源；②在 `FanCurve.swift` 抽象「风扇后端」接口，把 AsusFanSMC 的 F0/F1 作为其中一个实现；③`Hardware.swift` 自动识别机型切换默认配置。欢迎提 Issue / PR，也欢迎反馈你在自己主板上测出的风扇键、温度键。

---

## 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/Anoxia965/GHelper-macOS.git
cd GHelper-macOS
./build.sh          # 产物在 Build/GHelper.app（含内嵌的 GHelperHelper）
```

构建后同样先装驱动（第 2 步）、再装 App（第 3 步）。

---

## 安全须知

- 本项目**不直接修改你的 EFI**；仓库外的 `prepare_efi.py`、`*_efi.sh` 是你本机调 EFI 的辅助脚本，用前务必先备份 EFI。
- 拿不到有效温度读数时，App 会自动把风扇交回固件自动，**绝不让风扇停在低转速**。
- 本仓库 **不包含** `Build/`（编译产物）、`Backup/`（EFI 备份，可能含序列号/MLB/ROM）、`Downloads/`（第三方 kext 压缩包），请勿公开这些目录。
- `Kexts/` 里的 kext 是**第三方开源项目**，版权归各自作者（见 `Kexts/README.md`），本仓库仅随附打包方便下载。

---

## 已知限制 / 待办

- 风扇曲线走 WMNB 通道需要 **GHRGB kext 含通用 WMNB 选择器（v2+）**，该 kext 改动后需重启一次加载；App / 助手 / rgbctl 均为用户态，重启后可随时改随时测。
- 若 GHRGB kext 未加载或 rgbctl 缺失，风扇控制自动退回 SMC 通道（仅 CPU 风扇可靠，GPU 风扇在 SMC 下仍受限）。
- 某些信息（OpenCore 版本、SIP 状态）在普通用户权限下读不到，会显示「未检测」，属正常降级。
- 未来可做：一键卸载脚本；抽象风扇后端以支持更多主板 / Intel。

---

## 许可证

代码以 **MIT** 许可证发布（见 `LICENSE`）。`Kexts/` 内驱动为第三方项目，遵循各自许可证。

---

## 免责声明

本软件按「原样」提供，作者不承担因使用本软件导致的任何硬件损坏、数据丢失或系统不稳定后果。操作风扇/温度传感器及黑苹果引导属于进阶折腾，请自担风险，并始终保留 EFI 备份。

---

## 致谢 / Credits

这个 App 能存在，首先要感谢 **NullMoth（[@nullmoth](https://github.com/nullmoth)）**：是他逆向了 NVIDIA 驱动（[nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)），让我的华硕 FA607（RTX 4060）能在 macOS 下用上独显——也正因为他的工作，我才有了做这个 App 的念头。没有他，这个项目根本不会开始。他做的 **[1401](https://github.com/nullmoth/1401)** 安装器（Mac / Windows 版）也是装这套 NVIDIA 驱动最省事的方式，推荐需要装驱动的兄弟去用。

同时也要感谢所有让黑苹果能跑起来的驱动作者与社区：

- **Acidanthera** — VirtualSMC / Lilu（SMC 后端与补丁框架的基础）
- **Shaneee / wtf.spinach** — SMCAMDProcessor / AMDRyzenCPUPowerManagement（AMD CPU 温度与电源管理）
- **AsusFanSMC 社区维护者** — 华硕主板风扇控制键
- **NullMoth 团队** — NVIDIA macOS 驱动（NVAccel / NVRM 等）
- 以及整个 **OpenCore / Hackintosh** 社区

本仓库仅随附打包这些第三方开源驱动，版权与许可归各自作者所有。
