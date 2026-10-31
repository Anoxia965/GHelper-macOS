# GHelper for macOS

把 Windows 上华硕笔记本的 **GHelper** 风扇 / 传感器控制，**用原生 Swift 重写**成 macOS 菜单栏 App，面向 **黑苹果（Hackintosh）** 用户。
不是把 `GHelper.exe` 搬过来，而是重新实现了它最核心的能力：读传感器、按温度控风扇、独立控制 CPU / GPU 风扇。

> 当前针对 **华硕 ROG + AMD Ryzen（MacBookPro16,4 SMBIOS）** 的机器调校并实测；风扇控制核心是**与 CPU 品牌无关的**（走的都是 AppleSMC 读写），
> Intel 机型的兄弟下载下来改改温度来源 / 风扇后端也能用，欢迎一起完善（见文末「Intel 机型 / 一起参与开发」）。

---

## 功能

- **菜单栏常驻 + 独立窗口**：菜单栏点风扇图标弹快速面板；点 Dock 图标或面板上的「窗口」按钮打开 820×620 大窗口（关窗不退出，只隐藏）。
- **每把风扇独立控制**：CPU 风扇（fan0）和 GPU 风扇（fan1）各自可选
  - 模式：**固件自动 / 自定义曲线 / 固定转速**
  - 温度来源（非自动时）：CPU(SMC) / GPU / 电池 / CPU 占用率
  - 各自的转速滑块或温度→转速曲线编辑器
- **传感器监控**：GPU 温度、CPU 温度（经 SMCAMDProcessor）、CPU 占用率、电池温度/循环次数、每把风扇的实际/目标转速、占空比。
- **硬件信息页**：自动探测并展示 macOS 版本/Build、内核、SIP、SMBIOS 机型、处理器型号与核心数、内存容量与插槽、PCI 显卡列表、OpenCore 版本、启动卷、SMC 后端、以及常见黑苹果补丁 kext 的加载状态。全部优雅降级（读不到显示「—」），**不硬编码本机信息**，方便共享。
- **CPU 温度校准**：SMCAMDProcessor 报的是 Tctl，往往偏高，设置里用偏移滑块现场校准（默认 0，谁用谁调）。

---

## 系统要求

- macOS（本项目在 macOS 26.x 上开发实测）。
- 黑苹果引导环境：**OpenCore** + **VirtualSMC**（而不是 AppleSMC）。
- 风扇控制需要 **AsusFanSMC**（华硕主板风扇键 `F0`/`F1`）；CPU 温度：AMD 需要 `SMCAMDProcessor`，Intel 走 VirtualSMC 自带键（见文末）。
- 普通（白苹果）机器没有 AsusFanSMC，风扇控制不可用，但监控与硬件信息页仍可用。

---

## 快速开始（二选一）

**A. 直接用打包好的（推荐新手）**
1. 到 [Releases](https://github.com/Anoxia965/GHelper-macOS/releases) 下载 `GHelper.app.zip` 和 `Kexts.zip`。
2. 按下面「安装驱动（kext）」把 `Kexts/` 里的 kext 装进 EFI。
3. 按「安装 App」把 `GHelper.app` 装好。

**B. 自己编译（想改代码 / 适配其它机型）**
```bash
git clone https://github.com/Anoxia965/GHelper-macOS.git
cd GHelper-macOS
./build.sh          # 需要 Xcode 命令行工具：xcode-select --install
# 产物在 Build/GHelper.app
```
然后同样先装驱动、再装 App。

---

## 安装驱动（kext）— 最重要的一步

GHelper 依赖的几个 kext 已经放在仓库的 **`Kexts/`** 目录（也在 Release 的 `Kexts.zip` 里）。
kext **不能**装到 `/Library/Extensions`，必须放进你的 OpenCore **EFI** 由引导注入：

1. 挂载你的 EFI 分区（OpenCore 引导盘上的 EFI 卷）。
2. 把 `Kexts/` 里的这几个 kext **复制到 `EFI/OC/Kexts/`**（如果已有同名/更新版本，保留你自己的）：
   - `Lilu.kext`（依赖框架，必装）
   - `VirtualSMC.kext`（SMC 后端，必装）
   - `AsusFanSMC.kext`（华硕风扇键，华硕主板必装）
   - `AMDRyzenCPUPowerManagement.kext` **+** `SMCAMDProcessor.kext`（**仅 AMD CPU** 需要）
3. 用 **ProperTree** 打开 `EFI/OC/config.plist` → 菜单 `File ▸ OC Snapshot`（⌘R）刷新 Kernel→Add，让刚才复制的 kext 进入注入列表。
   - 如果你是 AMD：务必确认 **`AMDRyzenCPUPowerManagement.kext` 排在 `SMCAMDProcessor.kext` 之前**（依赖顺序不能反，否则读不到 CPU 温度）。
   - 华硕主板：确认 `AsusFanSMC.kext` 在列表里。
4. 保存，重启。进系统后打开「硬件信息」页，应能见到这些 kext 显示「已加载」；风扇控制与 CPU 温度即可用。

> 提示：如果你已经在用一套能正常启动的 EFI，只需**追加**这几个 kext，不要动其它部分。
> 改 EFI 前请先备份整个 EFI 分区。

---

## 安装 App

1. 把 `GHelper.app` 拷到 `/Applications`。
   - 若被 Gatekeeper 拦截：右键「打开」，或在终端执行
     ```bash
     xattr -dr com.apple.quarantine /Applications/GHelper.app
     ```
2. 打开 App → 去「设置」页点 **「安装特权助手」**（会要管理员密码）。它把 root 助手装成开机自启的守护进程：
   `/Library/LaunchDaemons/cn.anoxia.GHelper.helper.plist`（`RunAtLoad + KeepAlive`：开机自启 + 崩溃自愈）。
3. 若系统弹出「辅助功能 / 全盘访问」等权限请求，按提示授予（App 需要读传感器、读硬件信息）。
4. App 自身通过 LaunchAgent 登录自启。

> 改完代码重新 `./build.sh` 后，需要重新覆盖 `/Applications` 里的 App（或点 App 内的「重装助手」），因为 LaunchAgent 固定指向 `/Applications` 路径。

---

## 架构

```
GHelper.app  (菜单栏 + 窗口，普通用户进程)
   │  NSXPCConnection  ── mach 服务 cn.anoxia.GHelper.helper
   ▼
cn.anoxia.GHelper.helper  (root LaunchDaemon)
   │  AppleSMC IOConnectCallStructMethod (selector=2)
   ▼
内核 SMC  ←→  AsusFanSMC 驱动  ←→  物理风扇
```

为什么需要 root 助手：AppleSMC 的**写操作**只允许特权进程（否则返回 `kIOReturnNotReady`）。所以所有「写风扇转速」的指令都经 XPC 转发给以 root 运行的助手执行。

助手带 **15 秒看门狗**：如果 App 超过 15 秒没续心跳（比如崩了），助手自动把风扇**交回固件自动**，避免风扇卡在低转速导致过热。这是安全兜底，请勿移除。

---

## 风扇控制要点（实测）

- **占空比驱动封顶 75%**，但 75% 稳态已能到 **6100 RPM**，够覆盖 6000 目标；不必折腾 `-asusfanpct`。
- **风扇爬升很慢**：改完设定后要等约 **30–40 秒** 才到稳态，别以为没生效。
- **fan0（CPU 风扇）手动 / 曲线 / 自动都能正常接管**。
- ⚠️ **fan1（GPU 风扇）在本机 AsusFanSMC 下，一旦切到手动/曲线就停转，只能固件自动**（实测：手动→0 RPM，自动→稳稳 2100 RPM）。这是驱动行为，不是 App bug。App 已做保护：即使你在 UI 选了 GPU 风扇的非自动模式，也会强制交回固件自动并提示，绝不会误停 GPU 风扇影响散热。
- 想要原生 7000+ 转需要 ≥80% 触发固件 Turbo，由固件按温度调度（App 不强制）。

---

## Intel 机型 / 一起参与开发

风扇控制的核心是**通用的**：App 通过 AppleSMC（由 VirtualSMC 提供）读写风扇键，与 CPU 是 AMD 还是 Intel 无关。
所以只要你那台机器有对应的 SMC 风扇键 + 温度来源，这套代码就能用。不同点只在「温度从哪读、风扇键叫什么」：

- **Intel + 华硕主板**：`AsusFanSMC` 同样适用（它是按主板走的），风扇控制基本开箱即用；CPU 温度走 VirtualSMC 自带键，不需要 `SMCAMDProcessor` / `AMDRyzenCPUPowerManagement`。
- **Intel + 非华硕主板**：通常没有 `AsusFanSMC` 那套 `F0/F1` 键，需要接入别的风扇后端（例如基于主板 EC / 其它 SMC 键）。这正是需要补充的地方。
- **温度来源扩展**：目前 CPU 温度默认取自 AMD 的 SMC 键；Intel 可接 `Intel Power Gadget` 或 VirtualSMC 的 `TC0P` 等键，改 `Sources/Shared/Sensors.swift` 的 `TempSource` 解析即可。

**代码里的「硬件抽象缝」在哪（方便接手）：**
- `Sources/Shared/Hardware.swift` — 探测 macOS / SMBIOS / CPU / 内存 / PCI / OpenCore / SIP / SMC / kext 加载状态；已用**关键字匹配** kext，不写死 bundle ID。
- `Sources/Shared/Sensors.swift` — `FanState.index`（0=CPU / 1=GPU）、`TempSource` 定义与解析。
- `Sources/App/FanCurve.swift` — `FanRole`（cpu/gpu，映射到 F0/F1）、`FanControl`（模式/温度来源/曲线，Codable）。
- `Sources/App/AppModel.swift` — 全局状态、`temperature(for:)`、`applyNow()` 下发、看门狗、`cpuTempOffset` 校准。

想加 Intel 支持，主要工作是：①在 `Sensors.swift` 增加 Intel 温度来源；②在 `FanCurve.swift` 抽象出「风扇后端」接口，把 AsusFanSMC 的 F0/F1 作为其中一个实现；③`Hardware.swift` 自动识别机型并切换默认配置。
欢迎提 Issue / PR，也欢迎把你在自己主板上测出来的风扇键、温度键反馈进来。

---

## 安全须知

- 本项目**不直接修改你的 EFI**，但仓库外的 `prepare_efi.py`、`*_efi.sh` 是你本机调 EFI 的辅助脚本，使用它们前务必先备份 EFI。
- 拿不到有效温度读数时，App 会自动把风扇交回固件自动，**绝不让风扇停在低转速**。
- 本仓库 **不包含** `Build/`（编译产物）、`Backup/`（EFI 备份，可能含序列号/MLB/ROM）、`Downloads/`（第三方 kext 压缩包）。请勿将其纳入版本控制后公开。
- `Kexts/` 目录里的 kext 是**第三方开源项目**，版权归各自作者（见 `Kexts/README.md`），本仓库仅随附打包方便下载。

---

## 已知限制 / 待办

- GPU 风扇手动控制受 AsusFanSMC 驱动限制，目前只能自动（见上）。彻底解决需更换支持 fan1 手动的驱动版本。
- 某些信息（OpenCore 版本、SIP 状态）在普通用户权限下读不到，会显示「未检测」，属正常降级。
- 未来可做：打包成 dmg + 一键卸载脚本；抽象风扇后端以支持更多主板 / Intel。

---

## 许可证

代码以 **MIT** 许可证发布（见 `LICENSE`）。
`Kexts/` 内驱动为第三方项目，遵循各自许可证。

---

## 免责声明

本软件按「原样」提供，作者不承担因使用本软件导致的任何硬件损坏、数据丢失或系统不稳定后果。操作风扇/温度传感器及黑苹果引导属于进阶折腾，请自担风险，并始终保留 EFI 备份。
