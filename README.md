# GHelper for macOS

原生 Swift 写的 macOS 菜单栏 App，把 Windows 版 GHelper 的核心能力带到黑苹果：**风扇曲线、传感器监控、睿频、电池养护、键盘灯效**。v2.0 起开始接入 ROG 键鼠耳机外设。

**当前版本 v2.0.1**，针对华硕 ROG + AMD Ryzen（MacBookPro16,4 SMBIOS）实测调校。

> 风扇控制核心**与 CPU 品牌无关**：优先走华硕 EC / WMNB 直连，兜底 AppleSMC。Intel 华硕主板基本开箱可用，见文末「参与开发」。

---

## 功能一览

### 监控

- **菜单栏浮层**（320pt）：点菜单栏风扇图标弹出，CPU 型号 / 温度 / 占用 / 频率、核心占用网格、风扇转速、显卡温度与占用、WindowServer 占用，一眼扫尽。
- **主窗口**（SaaS 风格三区布局）：左侧图标导航 + 中间 KPI 大数字与曲线 + 右侧快捷状态栏。关窗只隐藏，不退出。
- **传感器**：CPU / GPU 温度与占用、CPU 实时频率、内存、电池温度与循环次数、每把风扇的实际 / 目标转速与占空比。GPU 温度 / 占用经 [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 驱动读取（含核心 / 显存细分）；GPU **核心频率在 macOS 下读不到**，如实标注「不适用」。
- **WindowServer 监控**：用 `ps cputime` 差分算瞬时 CPU 占用（黑苹果无硬件加速时常是头号大户），曲线经中值 + EMA 平滑，读数仍是真实瞬时值。
- **硬件信息页**：macOS 版本、SMBIOS、CPU、内存、PCI 显卡、OpenCore、SIP、kext 加载状态等，读不到显示「—」，不写死。
- **CPU 温度校准**：AMD Tctl 偏高，设置里用偏移滑块现场校准（默认 0）。

### 控制

- **每把风扇独立**：CPU（fan0）与 GPU（fan1）各自选**固件自动 / 自定义曲线 / 固定转速**；非自动时可指定温度来源（CPU / GPU / 电池 / CPU 占用）；曲线调乱了一键「恢复默认曲线」。
- **限制最高转速**：首次安装自动测绘本机实测上限，默认压在约 80%，曲线 / 固定转速 / SMC 兜底全部夹到上限以下。
- **睿频开关**：经 root 助手调 `zenmaster`（Python 版 RyzenAdj）钉 CPU 频率上限——开 = 读取到的最大频率、关 = 基础频率（本机实测约 5250 / 2400 MHz，其他机型按实测走），每 30 秒重涂防系统热管理覆盖。需 boot-args `debug=0x144`。
- **电池养护（充电上限 80%）**：经 ACPI WMNB 写 EC 寄存器，单档 80%（本机实测只支持这一档，非 60/80/100 三档）。EC 冷启动复位成 100%，助手开机自动重涂。
- **键盘 RGB**：华硕内置键盘灯效经 `GHRGB.kext` → ACPI WMNB 下发，颜色 + 亮度已真机验证；呼吸 / 彩虹等特效按协议下发，未在每台机器上逐一验证。需 root 助手与 kext。

### 界面

- **中英文切换**：主窗口左下角与菜单栏浮层头部均可切，偏好持久化。
- **检查更新 / 一键更新**：从 GitHub Releases 拉取；下载安装、替换旧版（备份到 `OldInstalls/`）、自动打开新实例。App 与助手带版本协商，助手过期会在下次启动自动重装同步。

### ROG 外设（v2.0+，测试版）

> 目前是**探测 / 诊断阶段，只读不写**。目标是按型号逐个开放 DPI、回报率、按键映射、逐键 RGB、耳机 EQ 等控制。

- **外设页**：`IOHIDManager` 枚举华硕 VID `0x0B05` 的全部 HID 接口，列出 PID、产品名、usage、location、report descriptor 大小。
- **回传诊断**：点「一键发 Issue」自动打开预填好的 GitHub Issue，补充设备型号和想要的功能即可提交；无 GitHub 账号可「复制诊断信息」发群里。诊断只含设备标识，无隐私信息。

---

## 系统要求

- **macOS 13 (Ventura) 及以上**（含 Sequoia 15 / macOS 26）；构建锁定 `x86_64-apple-macosx13.0` 部署目标。
- 黑苹果引导：**OpenCore + VirtualSMC**。
- 风扇控制需 **AsusFanSMC**；CPU 温度 AMD 需 `SMCAMDProcessor` + `AMDRyzenCPUPowerManagement`（顺序不能反），Intel 走 VirtualSMC 自带键。
- 白苹果无 AsusFanSMC，风扇控制不可用，但监控与硬件信息页仍可用。
- NVIDIA 显卡想看 GPU 温度 / 占用需装 **NullMoth** 驱动（NVAccel）；未装则显示「—」，属正常降级。

---

## 安装

> 默认你用 **OpenCore** 引导。下面所有 kext / config 步骤都按 OpenCore 说明。

### 第 0 步：准备

- OpenCore 引导的黑苹果（已装 VirtualSMC）、华硕主板。
- 管理员密码（装助手时用）。
- **先备份整个 EFI 分区**。

> ⚠️ 双系统注意：Windows + macOS 各有独立 EFI 分区，备份时分别挂载各存一份。App 只动 macOS 这一侧，不碰 Windows ESP。

### 第 1 步：下载

到 [Releases](https://github.com/Anoxia965/GHelper-macOS/releases) 下载 `GHelper-<版本>.pkg`（App + 驱动）或单独的 `Kexts.zip`。

### 第 2 步：把驱动放进 EFI（最关键）

OpenCore 开机自动注入 kext，所以**不能**装进 `/Library/Extensions`，必须放 EFI：

1. 挂载 EFI 分区，解压 `Kexts.zip`，把 5 个 `.kext` 复制到 `EFI/OC/Kexts/`。
2. 让它们进入 OC 注入列表（`config.plist → Kernel → Add`）：用 **ProperTree** 打开后 `File ▸ OC Snapshot`（⌘R），或用 **OCAT** 更新保存。
3. **AMD 用户**：确认 `AMDRyzenCPUPowerManagement.kext` 排在 `SMCAMDProcessor.kext` **之前**，反了读不到 CPU 温度。
4. **系统前置**：风扇 / 灯光 / 睿频需要 OC 的 `NVRAM → Add → 7C436110-…` 加 `debug=0x144`（睿频）+ AMFI 放行（`amfi_get_out_of_my_way=0x1 amfi=0x80`）+ `csr-active-config=430A0000`。点「设置 ▸ 安装 / 重装」后 App 会**先列出所有将要修改的配置供你确认**，确认才写入。也可在「设置 ▸ 系统前置」单独补配。改完需重启。
5. 保存并重启。

> 🛡️ **EFI 安全**：已挂载的 EFI 卷直接复用，绝不重复挂载（同一 FAT 卷挂两次并写会损坏文件系统）；未挂载的只挂一次，且只卸载自己挂的；写入前备份 `config.plist`，保留原格式（binary/XML），采「临时文件 → `plutil -lint` → 原子替换」；**安装与驱动补齐都必须先预览 + 二次确认**，App 不会后台静默写 EFI。

### 第 3 步：安装 App

1. 双击 `.pkg` 装到 `/Applications`。
2. 被 Gatekeeper 拦住就右键「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/GHelper.app`。
3. 进「设置」点 **安装 / 重装特权助手**（管理员密码）。助手装成开机自启 LaunchDaemon（`RunAtLoad + KeepAlive`），并装入灯光用的 `GHRGB.kext`。
4. 按弹窗授予「辅助功能 / 全盘访问」权限。
5. 若用键盘 RGB，系统设置 ▸ 隐私与安全性底部会出现「`GHRGB` 已被阻止」，**点「允许」并重启一次**（macOS 对第三方 kext 的强制批准，不是 App 的 bug）。

> 改完代码重新 `./build.sh` 后需覆盖 `/Applications` 里的 App（自启指向该路径）。

### 第 4 步：验证

打开「硬件信息」页，确认 `VirtualSMC`、`AsusFanSMC` 显示「已加载」；AMD 机器还应看到 `SMCAMDProcessor`。看到这些，风扇控制与温度监控就可用了。

---

## 快速上手

- 点菜单栏图标看快速面板；点「展开到独立窗口」或用 Dock 图标打开大窗口。
- 风扇页给 CPU / GPU 各选模式；非自动时用滑块或曲线设定转速，可开「限制最高转速」。
- CPU 温度偏高就在设置里拉 `cpuTempOffset` 偏移。
- 有 ROG 外设：插上设备 →「外设」页 →「重新扫描」→「一键发 Issue」回传诊断。

---

## 架构

```
GHelper.app  (菜单栏 + 窗口，普通用户进程)
   │  NSXPCConnection ── mach 服务 cn.anoxia.GHelper.helper
   ▼
cn.anoxia.GHelper.helper  (root LaunchDaemon)
   ├─ 风扇写：GHRGB kext → ACPI WMNB / EC 直连（优先）
   │          或 AppleSMC IOConnectCallStructMethod (selector=2) 兜底
   ├─ 睿频：zenmaster（Python RyzenAdj）写 AMD SMU
   └─ 电池养护 / 键盘 RGB：GHRGB kext → ACPI WMNB

ROG 外设探测（v2.0+）：App 层 IOHIDManager 直接枚举 VID 0x0B05，不需要 root
```

需要 root 助手是因为 AppleSMC **写操作**只允许特权进程（否则 `kIOReturnNotReady`），WMNB 通道也要经内核驱动做特权 ioctl。

助手带 **15 秒看门狗**：App 超过 15 秒没续心跳（比如崩了），自动把风扇**交回固件自动**，避免卡低转速过热。这是安全兜底，请勿移除。

---

## 风扇控制要点（实测）

- **占空比是 0–100 百分比，不是 0–255**：固件约定 1–100，实测出厂曲线字节 `[1,6,10,15,20,23,28,90]`。写成 0–255 会把 50% 变成 128 被夹到满速。`-asusfanpct` bootarg 本机实测无效。
- **风扇爬升很慢**：改完设定等约 **30–45 秒** 才到稳态。
- **两把扇都走 WMNB / EC 直连接管**（CPU `0x00110024` / GPU `0x00110025`），手动 / 曲线 / 自动均可；GHRGB 未加载时退回 SMC 兜底（仅 CPU 风扇可靠）。
- **上限按本机实测自适应**：首次安装自动测绘每把扇的空闲与 100% 占空比稳态最高转速，限速默认约 80%（留 3% 余量），换机器会重新测绘。本机参考：CPU 空闲 ~3200 / 100% ≈ 7300 RPM，GPU 空闲 ~2100 / 100% ≈ 7500 RPM。额定由固件 Turbo 按温度调度，软件无法强制拉满。

---

## 参与开发

风扇控制核心与 CPU 品牌无关，差异只在「温度从哪读、风扇键叫什么」：

- **Intel + 华硕主板**：`AsusFanSMC` 同样适用，CPU 温度走 VirtualSMC 自带键，不需要 AMD kext。
- **Intel + 非华硕主板**：通常没有 `F0/F1` 键，需接别的风扇后端。
- **温度来源扩展**：改 `Sources/Shared/Sensors.swift` 的 `TempSource`。

代码里的「硬件抽象缝」：

- `Sources/Shared/Hardware.swift` — 探测系统 / 硬件 / kext 加载状态。
- `Sources/Shared/Sensors.swift` — `FanState.index`、`TempSource` 定义与解析。
- `Sources/App/FanCurve.swift` — `FanRole`、`FanControl`（模式 / 温度来源 / 曲线）。
- `Sources/App/AppModel.swift` — 全局状态、下发、看门狗、温度校准。
- `Sources/App/PeripheralMonitor.swift` — ROG 外设 HID 探测（只读）。

欢迎提 Issue / PR，也欢迎反馈你在自己主板上测出的风扇键、温度键，以及 ROG 外设的诊断信息。

### 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/Anoxia965/GHelper-macOS.git
cd GHelper-macOS
./build.sh          # 产物在 Build/GHelper.app + .pkg / .app.zip
```

构建后按上面第 2、3 步装驱动和 App。

---

## 安全须知

- 所有 EFI 操作都遵循「先预览 + 二次确认 + 备份 + lint + 原子替换」，App 绝不后台静默写 EFI。
- 仓库外的 `prepare_efi.py`、`*_efi.sh` 是你本机调 EFI 的辅助脚本，用前务必备份。
- 拿不到有效温度读数时，App 自动把风扇交回固件自动，绝不让风扇停在低转速。
- 本仓库**不包含** `Build/`（编译产物）、`Backup/`（EFI 备份，可能含序列号/MLB/ROM）、`Downloads/`（第三方 kext 压缩包），请勿公开这些目录。
- `Kexts/` 内驱动为第三方开源项目，版权归各自作者，本仓库仅随附打包。

---

## 已知限制

- GPU 核心频率在 macOS 下物理读不到；WindowServer 是单进程多核口径，瞬时值可能超过 100%。
- 电池养护只有 80% 单档（本机 DSDT 写路径限制），风扇手动占空比封顶 75%。
- v2.0 外设功能目前**只做探测**，具体控制待按型号适配。
- 某些信息（OpenCore 版本、SIP 状态）普通权限下读不到，显示「未检测」属正常降级。

---

## 许可证 / 免责声明

代码以 **MIT** 许可证发布（见 `LICENSE`），`Kexts/` 内驱动遵循各自许可证。

本软件按「原样」提供，作者不承担因使用导致的硬件损坏、数据丢失或系统不稳定后果。操作风扇 / 温度传感器及黑苹果引导属进阶折腾，请自担风险并始终保留 EFI 备份。

---

## 致谢

首先感谢 **NullMoth（[@nullmoth](https://github.com/nullmoth)）**：他逆向了 NVIDIA 驱动（[nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)），让我的华硕 FA607（RTX 4060）能在 macOS 下用上独显——也正因如此才有了做这个 App 的念头。他的 [1401](https://github.com/nullmoth/1401) 安装器是装这套驱动最省事的方式，推荐需要装驱动的兄弟使用。

同时感谢所有让黑苹果跑起来的驱动作者与社区：

- **Acidanthera** — VirtualSMC / Lilu
- **Shaneee / wtf.spinach** — SMCAMDProcessor / AMDRyzenCPUPowerManagement
- **AsusFanSMC 社区维护者** — 华硕主板风扇控制键
- **NullMoth 团队** — NVIDIA macOS 驱动
- 以及整个 **OpenCore / Hackintosh** 社区
