/*
 * GHRGBProbe —— FA607 键盘 RGB 只读探针（阶段 A）
 *
 * 目的：验证 macOS 能否访问 DSDT 里声明的 ASUS EC 信箱寄存器区
 *       (_SB.PCI0.SBRG/MC00 @ SystemMemory 0xFE700C00, 256 字节)，
 *       并把当前状态读出来，供离线解析字节布局。
 *
 * 安全边界：
 *   - 全程【只读】：只做 volatile 读，不写任何寄存器，不发触发位。
 *   - 加载后一次性执行，之后完全静默（无定时器、无中断、无回调）。
 *   - start() 无论读成功与否都返回 true —— 绝不让加载失败引发开机异常。
 *   - 【默认静默开关】：不带 ghrgbprobe=1 时只登记一个 "armed-disabled" 标记，
 *     连 MMIO 映射都不建立，绝不碰 0xFE700C00。只有本次启动显式带
 *     ghrgbprobe=1 才进入采样分支。下次正常开机自动回到静默，无需卸载。
 *
 * 开关判定（2026-11-03 修正）：
 *   原先用 PE_parse_boot_argn("ghrgbprobe", ...) 判定，实测 boot-args 明明含
 *   ghrgbprobe=1（sysctl kern.bootargs + DeviceTree /options 均确认），该 API
 *   却返回 false —— macOS 26 对第三方 kext 的 boot-arg 解析有过滤。改为直接读
 *   DeviceTree /options 节点的 boot-args 属性（OSData 或 OSString），自己做子串
 *   匹配；同时把读到的原始值写进 IORegistry，即使没命中也能一次定位原因。
 *   只用 IOKit/libkern 现役 KPI，不引入任何 pexpert 私有符号。
 *
 * 结果通过 IORegistry 属性暴露，用 ioreg -r -c GHRGBProbe -l 查看。
 *   ProbeResult = armed-disabled  → 已加载、未采样（默认状态，零硬件接触）
 *   ProbeResult = ok              → 本次已采样，读 MC-Ver / Status8 等
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IORegistryEntry.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <libkern/c++/OSString.h>
#include <libkern/c++/OSData.h>

#define MC_BASE   0xFE700C00ULL   /* DSDT: OperationRegion (MC00, SystemMemory, 0xFE700C00, 0x100) */
#define MC_SIZE   0x100

/* 内核态不依赖 libc，手写子串查找 */
static bool cstrContains(const char *hay, const char *needle)
{
	if (!hay || !needle) return false;
	for (const char *p = hay; *p; ++p) {
		const char *h = p, *n = needle;
		while (*h && *n && *h == *n) { ++h; ++n; }
		if (*n == '\0') return true;
	}
	return false;
}

static bool bytesContain(const char *hay, UInt32 len, const char *needle)
{
	if (!hay || !needle) return false;
	UInt32 nlen = 0;
	while (needle[nlen]) ++nlen;
	if (nlen == 0 || nlen > len) return false;
	for (UInt32 i = 0; i + nlen <= len; ++i) {
		UInt32 j = 0;
		while (j < nlen && hay[i + j] == needle[j]) ++j;
		if (j == nlen) return true;
	}
	return false;
}

class GHRGBProbe : public IOService
{
	OSDeclareDefaultStructors(GHRGBProbe)

private:
	IOMemoryMap *fMap;

public:
	virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual void free(void) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(GHRGBProbe, IOService)

bool GHRGBProbe::start(IOService *provider)
{
	if (!IOService::start(provider)) {
		return false;
	}

	fMap = NULL;

	/* ---- 默认静默开关：读 DeviceTree /options 的 boot-args ---- */
	const char *needle    = "ghrgbprobe=1";
	const char *armSource = "none";
	bool        armed     = false;

	IORegistryEntry *options = IORegistryEntry::fromPath("/options", gIODTPlane);
	if (options) {
		OSObject *obj = options->getProperty("boot-args");
		if (obj) {
			OSData   *d = OSDynamicCast(OSData, obj);
			OSString *s = OSDynamicCast(OSString, obj);
			if (d) {
				setProperty("BootArgsRaw", d);   /* 诊断：原样留存 */
				if (bytesContain((const char *)d->getBytesNoCopy(),
								 d->getLength(), needle)) {
					armed = true;
					armSource = "device-tree-data";
				}
			} else if (s) {
				setProperty("BootArgsRaw", s);
				if (cstrContains(s->getCStringNoCopy(), needle)) {
					armed = true;
					armSource = "device-tree-string";
				}
			}
		} else {
			armSource = "no-boot-args-property";
		}
		options->release();
	} else {
		armSource = "no-options-node";
	}

	/* ---- 诊断属性：无论是否 armed 都记录来源 ---- */
	setProperty("ArmSource", armSource);
	setProperty("ProbeArmed", armed);

	if (!armed) {
		setProperty("ProbeResult", "armed-disabled");
		setProperty("ProbeNote", "DeviceTree boot-args 未找到 ghrgbprobe=1，未映射 MMIO");
		IOLog("GHRGBProbe: armed-disabled (ArmSource=%s)，未访问硬件\n", armSource);
		registerService();
		return true;
	}

	IOMemoryDescriptor *md =
		IOMemoryDescriptor::withPhysicalAddress((IOPhysicalAddress)MC_BASE,
												MC_SIZE,
												kIODirectionIn);   /* 只读映射：从内核 API 层面就无法写入 */
	if (!md) {
		IOLog("GHRGBProbe: withPhysicalAddress failed\n");
		setProperty("ProbeResult", "memory-descriptor-failed");
		registerService();
		return true;   /* 关键：不因探测失败阻止加载 */
	}

	fMap = md->map(kIOMapAnywhere);
	md->release();

	if (!fMap) {
		IOLog("GHRGBProbe: map failed\n");
		setProperty("ProbeResult", "map-failed");
		registerService();
		return true;
	}

	volatile UInt8 *base = (volatile UInt8 *)fMap->getVirtualAddress();
	if (!base) {
		setProperty("ProbeResult", "null-virtual-address");
		registerService();
		return true;
	}

	/* ---- 只读采样 ---- */
	UInt8  ver1 = base[0x00];
	UInt8  ver2 = base[0x01];
	UInt8  busy = base[0x7C];
	UInt8  cmdc = base[0x7D];

	UInt32 mc58 = 0, mc5c = 0, mc60 = 0, mc64 = 0, mc68 = 0;
	UInt8  st[8];
	for (int i = 0; i < 8; i++) {
		st[i] = base[0x6C + i];
	}
	/* 32 位寄存器用 memcpy 读，避免非对齐访问的未定义行为 */
	{
		UInt8 tmp[4];
		for (int i = 0; i < 4; i++) tmp[i] = base[0x58 + i];
		__builtin_memcpy(&mc58, tmp, 4);
		for (int i = 0; i < 4; i++) tmp[i] = base[0x5C + i];
		__builtin_memcpy(&mc5c, tmp, 4);
		for (int i = 0; i < 4; i++) tmp[i] = base[0x60 + i];
		__builtin_memcpy(&mc60, tmp, 4);
		for (int i = 0; i < 4; i++) tmp[i] = base[0x64 + i];
		__builtin_memcpy(&mc64, tmp, 4);
		for (int i = 0; i < 4; i++) tmp[i] = base[0x68 + i];
		__builtin_memcpy(&mc68, tmp, 4);
	}

	/* ---- 暴露给用户态 ---- */
	setProperty("PhysicalBase", MC_BASE, 64);
	setProperty("ProbeResult", "ok");
	setProperty("MC-Ver", (UInt32)(((UInt32)ver2 << 8) | (UInt32)ver1), 32);
	setProperty("MC-Busy", busy, 8);
	setProperty("MC-Cmd", cmdc, 8);
	setProperty("MC-58-DEVID", mc58, 32);
	setProperty("MC-5C-Data1", mc5c, 32);
	setProperty("MC-60-Data2", mc60, 32);
	setProperty("MC-64", mc64, 32);
	setProperty("MC-68", mc68, 32);
	setProperty("Status8", OSData::withBytes(st, 8));

	IOLog("GHRGBProbe: ver=%02x.%02x busy=%02x cmd=%02x devid=%08x d1=%08x d2=%08x "
		  "st=%02x %02x %02x %02x %02x %02x %02x %02x\n",
		  ver2, ver1, busy, cmdc, mc58, mc5c, mc60,
		  st[0], st[1], st[2], st[3], st[4], st[5], st[6], st[7]);

	registerService();
	return true;
}

void GHRGBProbe::stop(IOService *provider)
{
	if (fMap) {
		fMap->release();
		fMap = NULL;
	}
	IOService::stop(provider);
}

void GHRGBProbe::free(void)
{
	if (fMap) {
		fMap->release();
		fMap = NULL;
	}
	IOService::free();
}
