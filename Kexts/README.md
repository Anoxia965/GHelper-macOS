# Kexts（本仓库随附的驱动）

GHelper 本身只是个用户态 App，它要读/写风扇转速和 CPU 温度，依赖下面这几个**第三方开源内核扩展（kext）**。
它们由黑苹果社区维护，本仓库只是**随附打包**方便下载，**版权与许可归各自作者所有**（不是本项目写的）。

> ⚠️ kext 必须放进你的 OpenCore **EFI** 里由引导注入，**不能**直接装到 `/Library/Extensions`。
> 怎么放见仓库根目录 `README.md` 的「安装驱动（kext）」一节。

## 清单

| 文件 | Bundle ID | 版本 | 作用 | 谁需要 |
| --- | --- | --- | --- | --- |
| `Lilu.kext` | `as.vit9696.Lilu` | 1.7.3 | 补丁框架，是下面几个 kext 的**公共依赖** | **所有人**（已随附） |
| `VirtualSMC.kext` | `as.vit9696.VirtualSMC` | 1.3.9 | 模拟 SMC，提供 App 读写所需的 SMC 后端（AppleSMC 替身） | **所有人**（AMD/Intel 都需要） |
| `AsusFanSMC.kext` | `local.hackintosh.AsusFanSMC` | 1.0.0 | 华硕主板的风扇控制键（F0=CPU 风扇 / F1=GPU 风扇） | **华硕主板**用户（AMD/Intel 都适用） |
| `SMCAMDProcessor.kext` | `wtf.spinach.SMCAMDProcessor` | 1.0.1 | 暴露 AMD CPU 温度（SMC 键） | **仅 AMD CPU** |
| `AMDRyzenCPUPowerManagement.kext` | `wtf.spinach.AMDRyzenCPUPowerManagement` | 0.7.2 | AMD 电源/温度基础驱动，**必须先于** SMCAMDProcessor 加载 | **仅 AMD CPU** |

> 注：`AsusFanSMC` / `SMCAMDProcessor` 依赖 `Lilu.kext` 与 `VirtualSMC.kext`，所以这两个**必装**（本文件夹已带）；
> 如果你已有的 EFI 里已经有更新版本的 `VirtualSMC` / `Lilu`，用你自己的即可，不必覆盖。

## 出处（建议按自己机型去官方源核对最新版）

- VirtualSMC / Lilu：Acidanthera（https://github.com/acidanthera ）
- SMCAMDProcessor / AMDRyzenCPUPowerManagement：Shaneee / wtf.spinach（AMD 电源管理相关仓库）
- AsusFanSMC：社区维护的华硕风扇驱动（local.hackintosh）

不同主板 / 不同 macOS 版本对 kext 版本有要求，请以自己的 EFI 能稳定注入为准。
