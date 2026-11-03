# FA607 键盘 RGB — DSDT 逆向结论（2026-11-02）

来源：AcpiOut/dsdt.dat（ASUS Notebook，AMI BIOS，iasl 反编译 → RGB/dump/dsdt.dsl）
依据：_SB.PCI0.SBRG 下 MC00 区域 + TU56/TU57/TU5A/TU5B 方法 + WMNB 的 DEVS/DSTS 分发

## 通道：内存映射寄存器区（不是 USB，不是 EC 62/66 端口）

```
OperationRegion (MC00, SystemMemory, 0xFE700C00, 0x100)   // Scope _SB.PCI0.SBRG
```

| 偏移 | 名称 | 宽度 | 用途 |
|------|------|------|------|
| 0x58 | MC58 | 32 | DEVID（命令标识） |
| 0x5C | MC5C | 32 | 数据字 1 |
| 0x60 | MC60 | 32 | 数据字 2 |
| 0x6C..0x73 | MC6C..MC73 | 8×8 | 读回缓冲（8 字节） |
| 0x7C | MC7C | 8 | 触发/忙标志（写 1 启动；EC 完成后清 0） |
| 0x7D | MC7D | 8 | 命令码 |

## 命令码（MC7D）

| 命令码 | ACPI 方法 | DEVID | 数据 |
|--------|-----------|-------|------|
| 0x03 | TU56(a,b,c) | 0x00100056 | 写 RGB：data1=IIA1, data2=IIA2 |
| 0x05 | TU57(a,b) | 0x00100057 | 写（数据 1 个字，用途待实验确认） |
| 0x04 | TU5B(devid) | 0x0010005B | 读回：返回 MC6C..MC73 共 8 字节 |
| 0x06 | TU5A(a,b,c) | — | 写（3 参数，待确认） |

## 调用序列

**写 RGB（DEVID 0x00100056）**：
1. [0x58] = 0x00100056
2. [0x5C] = 数据字1（含 模式/R/G/B 之一组）
3. [0x60] = 数据字2（含 速度 等）
4. [0x7D] = 0x03
5. [0x7C] = 1（触发，TU56 不等完成即返回）

**读回（DEVID 0x0010005B）**：
1. [0x58] = 0x0010005B
2. [0x7D] = 0x04
3. [0x7C] = 1；自旋等 [0x7C] 清零（WCMR，需加超时保护！）
4. Sleep 10ms（ACPI 里 TU5B 有 Sleep(0x0A)）
5. 读 [0x6C..0x73] = 8 字节状态（预期含 模式/R/G/B/速度/电源标志）

DSTS 查询确认：0x00100056 → 0x00010000 =「支持、当前关闭」，特性存在。

## 待实验确认（探针 kext 阶段）

- 读回 8 字节的具体字段顺序（模式/颜色/速度/电源标志的排列）
- 0x0010005A（命令 0x06）的实际用途

---

## ★ 探针实测（2026-11-03，阶段 A 收工）

**只读探针 GHRGBProbe v1.0.0 实测通过**，装到 `/Library/Extensions/` + `kmutil load -p ... -z`
进 AuxKC。带 `ghrgbprobe=1` 重启后 `ioreg -r -c GHRGBProbe -l` 结果：

```
ProbeResult = ok / ProbeArmed = Yes / ArmSource = device-tree-string
MC-Ver = 0x0100 (256)    MC-Busy = 0x00    MC-Cmd = 0x01
MC-58-DEVID = 0x00110025   MC-5C-Data1 = 0x00000000
MC-60-Data2 = 0x61534e4e   MC-64 = 0x0e0c0100   MC-68 = 0x591e4e53
Status8 = 3f 46 49 49 4e 4e 53 61  ("?FIINNSa")
```

**三项关键结论：**

1. **安全验证通过（最重要）**：映射并只读 `0xFE700C00` 不会卡总线、不会崩、不会掉
   GPU 驱动（NullMoth 4 个 kext 照常加载）。之前担心的「MMIO 读卡死」在本机不成立。
   这解除了正式驱动的最大风险阻塞。

2. **信箱是活的、结构化**：`MC-Ver=0x0100`、busy 标志清 0、数据区有内容 → 确认
   `0xFE700C00` 是真实 EC 信箱，协议通道有效。

3. **⚠️ 并发铁证 —— 必须走 ACPI 而非裸 MMIO**：`MC-58-DEVID=0x00110025` 落在
   `0x0011xxxx` 段，是 **AsusFanSMC** 用的 DEVID（不是 RGB 的 `0x0010005x`）。
   说明 RGB 与风扇**共用同一个信箱**，且探针抓到的 8 字节是风扇驱动上次用完留下的
   残留，不是 RGB 当前状态（只读探针故意不发触发位）。→ 正式 RGB 驱动必须走
   `WMNB`(ACPI) 求值拿 AML 互斥锁，否则会与风扇驱动互踩。这与下方「macOS 侧实现要点」
   的判断一致，现升级为已证实。

**注意**：本次快照是开机后的残留态，不是 `DEVID 0x0010005B` 主动读回的 RGB 状态。
真正的「当前 RGB 颜色/模式」要等正式驱动发读命令才能拿到——但那已经不需要再担心安全。

**下一步（阶段 B，未执行）**：写完整功能 kext（模式/四区/亮度/速度 + 读回校验），
走 `IOACPIPlatformDevice` 求值 `\_SB.PCI0.SBRG.WMNB`，自旋等 [0x7C] 必须带超时
（DSDT 的 WCMR 是裸 While）。验证通过后接 GHelper 灯光 tab、升 v1.7.0 发版。

**清理**：探针已恢复默认静默（`ghrgbprobe=1` 已从 EFI config 移除，备份
`Backup/EFI-bootarg-remove-20261103-102502/config.plist`）。验证用完后用
`/Library/Application Support/GHRGBDev/rollback.sh` 彻底卸载探针。


---

## ★ 协议最终确认（2026-11-02，来源：Linux 内核 asus-wmi.c + 本机 DSDT 双向印证）

### DEVID（include/linux/platform_data/x86/asus-wmi.h）

| 常量 | 值 | DSDT 对应 |
|------|-----|-----------|
| ASUS_WMI_DEVID_TUF_RGB_MODE | 0x00100056 | TU56（命令 0x03） |
| ASUS_WMI_DEVID_TUF_RGB_MODE2 | 0x0010005A | TU5A（命令 0x06） |
| ASUS_WMI_DEVID_TUF_RGB_CMD | 0x00100057 | TU57（命令 0x05） |
| （读状态，DSTS 专用） | 0x0010005B | TU5B（命令 0x04） |

本机 DSDT 的 DSTS 查询对 0x00100056 返回 0x00010000（特性存在），
故 kbd_rgb_dev = **0x00100056**（Linux 里 `asus_wmi_dev_is_present` 的同一逻辑）。

### 设置颜色（DEVS / DEVID 0x00100056）

```
arg1 = cmd | (mode << 8) | (r << 16) | (g << 24)
arg2 = b | (speed << 8)
→ MC5C = arg1, MC60 = arg2, [0x7D] = 0x03, [0x7C] = 1
```

- **cmd**：0xb3 = 应用；0xb4 = 应用并保存到 BIOS
- **mode**：0–11 有效，**9 保留**（传 9 或 ≥12 会被改成 10 = 静态）
- **speed**：0xe1 慢 / 0xeb 正常 / 0xf5 快

### 开关机灯效（DEVS / DEVID 0x00100057）

```
arg1 = 0xbd | (cmd << 8) | (flags << 16)     // cmd: 0 或 BIT(2)
arg2 = 0
flags: BIT(1)=boot, BIT(3)=awake, BIT(5)=sleep, BIT(7)=shutdown
```
注：arg0 必须是 0xbd，否则 EC 不响应（内核注释原话）。

### 读回状态（DSTS / DEVID 0x0010005B）

返回 MC6C..MC73 共 8 字节。实机对照（2026-11-03，设 mode=0/R=255/G=0/B=0 后读回
`<0100ff0000f5ff00>`）：**字节 [2]=R [3]=G [4]=B**（ff 00 00 完美对应红的 R/G/B），
[0]/[1]/[5]/[6]/[7] 为 EC 内部模式/速度标识，颜色三段是权威的。

### ★ 键盘亮度（独立通道，2026-11-03 实测确认）

亮度**不**在 RGB 颜色包里，是独立的 DEVID `0x00050021`：
```
DSTS 读：返回 (M64D & 0x0F) | 0x00050000  → 低 4 位 = 亮度等级
DEVS 写：arg1 = 0x80 | (level & 0x0F)      → bit7=开/关，低 4 位=等级
         （DSDT：Local0 = IIA1 & 0x8F ; SECC(0x05, Local0)）
```
实测等级 0–3 即可（4 档；DSDT 掩码 0x0F 允许 0–15，但本机键盘背光实测 0–3 足够）。
注意：RGB 颜色包（0x00100056）与亮度包（0x00050021）是 EC 的两个独立命令，
互不影响；设置颜色不会改亮度，反之亦然。

### 用户态通道（IOUserClient）

GHRGB kext 暴露 `GHRGBUserClient`（selector）：
- 0 = setRGB(mode,r,g,b,speed)
- 1 = setBright(level)
- 2 = getStatus（返回 8 字节颜色）
- 3 = getBright（返回等级）
测试工具 `RGB/kext/rgbctl.c` 已编译装到 `/usr/local/bin/rgbctl`（root 调）。

### macOS 侧实现要点

- 走 ACPI 求值（与 AsusFanSMC 同一路径 WMNB）可获得 AML 全局锁，避免与风扇驱动抢信箱
- 等价于 `WMNB(0, 0x53564544 /*DEVS*/, buffer{0x00100056, arg1, arg2, 0, 0})`
- 自旋等 [0x7C] 必须带超时（DSDT 的 WCMR 是无超时死循环）

---

## ⚠ 工具链阻塞（2026-11-02 实测）

macOS 26 + CommandLineTools(clang 21 / ld-1267 / ld-classic ld64-957)：
`ld -kext` **不再生成 `_kmod_info` 符号**（实测 `nm` 无该符号），
kmutil 因此拒绝加载：`kexts must have a _kmod_info symbol`。
无完整 Xcode、无 KDK。→ 自研 kext 需要解决此问题（手写 kmod_info 或换旧版工具链）。

## macOS kext 实现路径

首选：IOMemoryDescriptor 映射物理地址 0xFE700C00，直接读写寄存器（无需 ACPI 求值）
兜底：IOACPIPlatformDevice 求值 `\_SB.PCI0.SBRG.TU56/TU5B`

风险控制：
- 自旋等待必须带超时（ACPI 的 WCMR 是裸 While，死锁保护要我们自己做）
- 只碰已确认的命令码 0x03/0x04（RGB 写/读），0x05/0x06 先读回对照再上
