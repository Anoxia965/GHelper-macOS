# GHelper for macOS

把 Windows 上华硕笔记本的 **GHelper** 风扇 / 传感器控制，**用原生 Swift 重写**成 macOS 菜单栏 App，面向 **黑苹果（Hackintosh）** 用户。
不是把 `GHelper.exe` 搬过来，而是重新实现了它最核心的能力：读传感器、按温度控风扇、独立控制 CPU / GPU 风扇。

> 当前针对 **华硕 ROG + AMD Ryzen（MacBookPro16,4 SMBIOS）** 的机器调校并实测，但硬件信息页与大部分逻辑是通用的，其它机型也能跑（详见下方「已知限制」）。

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
- 黑苹果引导环境：**OpenCore** + **VirtualSMC**（而非 AppleSMC）。
- **AsusFanSMC** 驱动（提供 `F0Md/F0Tg/F1Md/F1Tg` 等风扇控制键）。
- 读 **AMD CPU 温度** 需要：`AMDRyzenCPUPowerManagement.kext` **先于** `SMCAMDProcessor.kext` 加载（依赖顺序不能反）。Intel 机器无此需求，CPU 温度来源会显示不可用，不影响其它功能。

> 普通（白苹果）机器没有 AsusFanSMC，风扇控制不可用，但监控与硬件信息页仍可用。

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

## 构建

需要 Xcode 命令行工具（`xcode-select --install`）：

```bash
./build.sh
```

产物在 `Build/GHelper.app`（含内嵌的 `GHelperHelper`）。

---

## 安装

1. 把 `Build/GHelper.app` 拷到 `/Applications`。
2. 打开 App → 去「设置」页点「安装特权助手」（会要管理员密码），它把 root 助手装成开机自启的守护进程（`/Library/LaunchDaemons/cn.anoxia.GHelper.helper.plist`，`RunAtLoad + KeepAlive`：开机自启 + 崩溃自愈）。
3. App 自身通过 LaunchAgent 登录自启。

> 改完代码重新 `./build.sh` 后，需要重新覆盖 `/Applications` 里的 App（或点 App 内的「重装助手」），LaunchAgent 固定指向 `/Applications` 路径。

---

## 风扇控制要点（实测）

- **占空比驱动封顶 75%**，但 75% 稳态已能到 **6100 RPM**，够覆盖 6000 目标；不必折腾 `-asusfanpct`。
- **风扇爬升很慢**：改完设定后要等约 **30–40 秒** 才到稳态，别以为没生效。
- **fan0（CPU 风扇）手动 / 曲线 / 自动都能正常接管**。
- ⚠️ **fan1（GPU 风扇）在本机 AsusFanSMC 下，一旦切到手动/曲线就停转，只能固件自动**（实测：手动→0 RPM，自动→稳稳 2100 RPM）。这是驱动行为，不是 App bug。App 已做保护：即使你在 UI 选了 GPU 风扇的非自动模式，也会强制交回固件自动并提示，绝不会误停 GPU 风扇影响散热。
- 想要原生 7000+ 转需要 ≥80% 触发固件 Turbo，由固件按温度调度（App 不强制）。

---

## 安全须知

- 本项目**不直接修改你的 EFI**，但仓库外的 `prepare_efi.py`、`*_efi.sh` 是你本机调 EFI 的辅助脚本，使用它们前务必先备份 EFI。
- 拿不到有效温度读数时，App 会自动把风扇交回固件自动，**绝不让风扇停在低转速**。
- 本仓库 **不包含** `Build/`（编译产物）、`Backup/`（EFI 备份，可能含序列号/MLB/ROM）、`Downloads/`（第三方 kext 压缩包）。请勿将其纳入版本控制后公开。

---

## 已知限制 / 待办

- GPU 风扇手动控制受 AsusFanSMC 驱动限制，目前只能自动（见上）。彻底解决需更换支持 fan1 手动的驱动版本。
- 某些信息（OpenCore 版本、SIP 状态）在普通用户权限下读不到，会显示「未检测」，属正常降级。
- 未来可做：打包成 dmg/zip + 一键卸载脚本。

---

## 免责声明

本软件按「原样」提供，作者不承担因使用本软件导致的任何硬件损坏、数据丢失或系统不稳定后果。操作风扇/温度传感器及黑苹果引导属于进阶折腾，请自担风险，并始终保留 EFI 备份。
