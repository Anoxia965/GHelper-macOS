/*
 * GHRGB —— FA607 键盘 RGB 驱动（阶段 B，核心：ACPI/WMNB 通道）
 *
 * 通道：ACPI WMNB（与 AsusFanSMC 同一 ATKD 设备、同一方法）。WMNB 是 Serialized，
 *      因此本驱动与风扇驱动对 EC 信箱的访问由 AML 互斥，无需裸 MMIO 抢寄存器。
 *
 * 颜色（TU56）：仅写寄存器 + 触发位，不自旋 → 启动路径安全。
 * 亮度（0x00050021）：独立的键盘背光 DEVID，bit7=开/关，低 4 位=等级（0–15，实测 0–3）。
 * 读回（TU5B / DSTS 0x0010005B）：返回 MC6C..MC73 共 8 字节，颜色在 [2..4]。
 *
 * 用户态通道：IOUserClient（selector 0=setRGB 1=setBright 2=getStatus 3=getBright），
 * 由 GHelper 的 root 助手调用，无需每次写 boot-args。
 *
 * 调色字节布局（asus-wmi + 本机 DSDT 双向印证）：
 *   DEVS / DEVID 0x00100056：
 *     arg1 = 0xB3(apply) | (mode<<8) | (r<<16) | (g<<24)
 *     arg2 = b | (speed<<8)
 *   DEVS / DEVID 0x00050021（亮度）：
 *     arg1 = 0x80 | (level & 0x0F)     // bit7=on，低 4 位=等级
 *   DSTS / DEVID 0x0010005B（读回）：返回 MC6C..MC73 共 8 字节
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IORegistryEntry.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/IOUserClient.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>
#include <kern/thread_call.h>

#define GHRGB_DEVID_RGB    0x00100056
#define GHRGB_DEVID_PWR    0x00100057
#define GHRGB_DEVID_READ   0x0010005B
#define GHRGB_DEVID_KBD_BL 0x00050021
#define WMNB_DEVS          0x53564544UL
#define WMNB_DSTS          0x53545344UL

#define GHRGB_UC_SET_RGB    0
#define GHRGB_UC_SET_BRIGHT 1
#define GHRGB_UC_GET_STATUS 2
#define GHRGB_UC_GET_BRIGHT 3

class GHRGB;

class GHRGBUserClient : public IOUserClient
{
	OSDeclareDefaultStructors(GHRGBUserClient)
private:
	GHRGB  *fDriver;
	task_t  fTask;

public:
	virtual bool initWithTask(task_t owningTask, void *securityID, UInt32 type,
	                          OSDictionary *properties) APPLE_KEXT_OVERRIDE;
	virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual IOReturn externalMethod(uint32_t selector,
	                                IOExternalMethodArguments *arguments,
	                                IOExternalMethodDispatch *dispatch,
	                                OSObject *target,
	                                void *reference) APPLE_KEXT_OVERRIDE;
};

class GHRGB : public IOService
{
	OSDeclareDefaultStructors(GHRGB)
private:
	IOACPIPlatformDevice *fATKD;

	static bool bootArgSet(const char *needle);
	IOReturn callWMNB(UInt32 sig, UInt32 devid, UInt32 arg1, UInt32 arg2, OSObject **result);

	static void deferredDumpThread(void *param0, void *param1);
	void deferredDump(void);

public:
	virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

	IOReturn setRGB(UInt8 mode, UInt8 r, UInt8 g, UInt8 b, UInt8 speed);
	IOReturn setBrightness(UInt8 level);
	IOReturn setPower(UInt8 flags);
	IOReturn getStatus(UInt8 out[8], UInt32 *outLen);
	IOReturn getBrightness(UInt32 *outLevel);
};

OSDefineMetaClassAndStructors(GHRGB, IOService)
OSDefineMetaClassAndStructors(GHRGBUserClient, IOUserClient)

/* boot-arg 判定：PE_parse_boot_argn 在第三方 AuxKC kext 不可靠，改读 DeviceTree /options */
bool GHRGB::bootArgSet(const char *needle)
{
	bool found = false;
	IORegistryEntry *options = IORegistryEntry::fromPath("/options", gIODTPlane);
	if (options) {
		OSObject *obj = options->getProperty("boot-args");
		if (obj) {
			OSData *d = OSDynamicCast(OSData, obj);
			if (d) {
				const char *hay = (const char *)d->getBytesNoCopy();
				UInt32 len = d->getLength();
				UInt32 nlen = (UInt32)strlen(needle);
				for (UInt32 i = 0; i + nlen <= len; i++) {
					if (strncmp(hay + i, needle, nlen) == 0) { found = true; break; }
				}
			} else {
				OSString *s = OSDynamicCast(OSString, obj);
				const char *cs = (s ? s->getCStringNoCopy() : NULL);
				if (cs) {
					UInt32 slen = (UInt32)strlen(cs);
					UInt32 nlen = (UInt32)strlen(needle);
					for (UInt32 i = 0; i + nlen <= slen; i++) {
						if (strncmp(cs + i, needle, nlen) == 0) { found = true; break; }
					}
				}
			}
		}
		options->release();
	}
	return found;
}

/* 核心：调用 ATKD 设备的 WMNB 方法。buf[0..3]=devid, [4..7]=arg1, [8..11]=arg2（小端） */
IOReturn GHRGB::callWMNB(UInt32 sig, UInt32 devid, UInt32 arg1, UInt32 arg2, OSObject **result)
{
	if (!fATKD) return kIOReturnNotReady;
	if (result) *result = NULL;

	UInt8 buf[20];
	memset(buf, 0, sizeof(buf));
	for (int i = 0; i < 4; i++) {
		buf[0 + i] = (devid >> (8 * i)) & 0xFF;
		buf[4 + i] = (arg1  >> (8 * i)) & 0xFF;
		buf[8 + i] = (arg2  >> (8 * i)) & 0xFF;
	}

	OSObject *params[3];
	params[0] = OSNumber::withNumber((UInt64)0, 32);
	params[1] = OSNumber::withNumber((UInt64)sig, 32);
	params[2] = OSData::withBytes(buf, 20);
	if (!params[0] || !params[1] || !params[2]) {
		if (params[0]) params[0]->release();
		if (params[1]) params[1]->release();
		if (params[2]) params[2]->release();
		return kIOReturnNoMemory;
	}

	IOReturn ret = fATKD->evaluateObject("WMNB", result, params, 3);
	params[0]->release();
	params[1]->release();
	params[2]->release();
	return ret;
}

IOReturn GHRGB::setRGB(UInt8 mode, UInt8 r, UInt8 g, UInt8 b, UInt8 speed)
{
	/* arg1 = 0xB3(apply) | mode<<8 | r<<16 | g<<24 ; arg2 = b | speed<<8 */
	UInt32 arg1 = 0xB3UL | ((UInt32)mode << 8) | ((UInt32)r << 16) | ((UInt32)g << 24);
	UInt32 arg2 = ((UInt32)b) | ((UInt32)speed << 8);
	OSObject *res = NULL;
	IOReturn ret = callWMNB(WMNB_DEVS, GHRGB_DEVID_RGB, arg1, arg2, &res);
	if (res) res->release();
	return ret;
}

/* 亮度：DEVID 0x00050021，ctrl_param = 0x80 | (level & 0x0F)
 * （DSDT：Local0 = IIA1 & 0x8F；SECC(0x05, Local0)。bit7=开/关，低 4 位=等级） */
IOReturn GHRGB::setBrightness(UInt8 level)
{
	UInt32 arg1 = 0x80UL | ((UInt32)(level & 0x0F));
	OSObject *res = NULL;
	IOReturn ret = callWMNB(WMNB_DEVS, GHRGB_DEVID_KBD_BL, arg1, 0, &res);
	if (res) res->release();
	return ret;
}

IOReturn GHRGB::setPower(UInt8 flags)
{
	/* DEVID 0x00100057: arg1 = 0xBD | (cmd<<8) | (flags<<16) ; arg2 = 0 */
	UInt32 arg1 = 0xBDUL | ((UInt32)flags << 16);
	OSObject *res = NULL;
	IOReturn ret = callWMNB(WMNB_DEVS, GHRGB_DEVID_PWR, arg1, 0, &res);
	if (res) res->release();
	return ret;
}

IOReturn GHRGB::getStatus(UInt8 out[8], UInt32 *outLen)
{
	OSObject *res = NULL;
	IOReturn ret = callWMNB(WMNB_DSTS, GHRGB_DEVID_READ, 0, 0, &res);
	if (ret != kIOReturnSuccess || !res) return ret;
	OSData *d = OSDynamicCast(OSData, res);
	if (d) {
		UInt32 n = d->getLength();
		*outLen = (n > 8) ? 8 : n;
		memcpy(out, d->getBytesNoCopy(), *outLen);
		ret = kIOReturnSuccess;
	} else {
		ret = kIOReturnUnsupported;
	}
	res->release();
	return ret;
}

IOReturn GHRGB::getBrightness(UInt32 *outLevel)
{
	OSObject *res = NULL;
	IOReturn ret = callWMNB(WMNB_DSTS, GHRGB_DEVID_KBD_BL, 0, 0, &res);
	if (ret != kIOReturnSuccess || !res) return ret;
	OSNumber *n = OSDynamicCast(OSNumber, res);
	if (n) {
		/* DSTS 0x00050021 返回 Local0 = (M64D & 0x0F) | 0x00050000 */
		*outLevel = n->unsigned32BitValue() & 0x0F;
		ret = kIOReturnSuccess;
	} else {
		ret = kIOReturnUnsupported;
	}
	res->release();
	return ret;
}

void GHRGB::deferredDumpThread(void *param0, void *param1)
{
	GHRGB *self = (GHRGB *)param0;
	if (self) self->deferredDump();
}

void GHRGB::deferredDump(void)
{
	UInt8 buf[8]; UInt32 len = 0;
	IOReturn r = getStatus(buf, &len);
	if (r == kIOReturnSuccess && len) {
		setProperty("SelfTestStatus", OSData::withBytes(buf, len));
		IOLog("GHRGB dump: getStatus ok len=%u: ", len);
		for (UInt32 i = 0; i < len; i++) IOLog("%02x ", buf[i]);
		IOLog("\n");
	} else {
		IOLog("GHRGB dump: getStatus failed %x\n", r);
		setProperty("SelfTestStatus", "read-failed");
	}

	UInt32 bl = 0;
	IOReturn rb = getBrightness(&bl);
	if (rb == kIOReturnSuccess) {
		setProperty("SelfTestBright", (UInt32)bl, 32);
		IOLog("GHRGB dump: brightness level=%u\n", bl);
	} else {
		IOLog("GHRGB dump: getBrightness failed %x\n", rb);
		setProperty("SelfTestBright", "read-failed");
	}
}

bool GHRGB::start(IOService *provider)
{
	if (!IOService::start(provider)) return false;
	fATKD = NULL;

	/* 找 ATKD（提供 WMNB 的 ACPI 设备），最多等 10s。
	 * IOACPIPlatformDevice::metaClass 不向第三方 kext 导出，故用 metaCast 运行期校验。 */
	OSDictionary *matching = IOService::nameMatching("ATKD");
	if (matching) {
		IOService *svc = IOService::waitForMatchingService(matching, 10ULL * 1000 * 1000 * 1000);
		if (svc) {
			if (svc->metaCast("IOACPIPlatformDevice"))
				fATKD = (IOACPIPlatformDevice *)svc;
			else
				svc->release();
		}
		matching->release();
	}
	setProperty("ATKDFound", fATKD ? true : false);
	IOLog("GHRGB: ATKD %s\n", fATKD ? "found" : "NOT found");

	/* 启动路径只做写（安全）。读留到延后线程（绕开启动关键路径）。 */
	if (bootArgSet("ghrgbbtest=1") && fATKD) {
		IOReturn rr = setRGB(0, 255, 0, 0, 0xEB); /* 静态红 */
		IOLog("GHRGB self-test setRGB(static,red) -> %x\n", rr);
		setProperty("SelfTestSetRGB", (UInt32)rr, 32);

		IOReturn br = setBrightness(3);             /* 亮度拉到最高（等级 3） */
		IOLog("GHRGB self-test setBrightness(3) -> %x\n", br);
		setProperty("SelfTestSetBright", (UInt32)br, 32);

		thread_call_t tc = thread_call_allocate((thread_call_func_t)deferredDumpThread, this);
		if (tc) thread_call_enter_delayed(tc, 5ULL * 1000 * 1000 * 1000); /* 5s 后读回 */
	}

	registerService();
	return true;
}

void GHRGB::stop(IOService *provider)
{
	if (fATKD) { fATKD->release(); fATKD = NULL; }
	IOService::stop(provider);
}

/* ---------------- IOUserClient ---------------- */

bool GHRGBUserClient::initWithTask(task_t owningTask, void *securityID, UInt32 type,
                                   OSDictionary *properties)
{
	if (!IOUserClient::initWithTask(owningTask, securityID, type, properties))
		return false;
	fTask = owningTask;
	fDriver = NULL;
	return true;
}

bool GHRGBUserClient::start(IOService *provider)
{
	if (!IOUserClient::start(provider)) return false;
	fDriver = OSDynamicCast(GHRGB, provider);
	if (!fDriver) return false;
	fDriver->retain();
	return true;
}

void GHRGBUserClient::stop(IOService *provider)
{
	if (fDriver) { fDriver->release(); fDriver = NULL; }
	IOUserClient::stop(provider);
}

IOReturn GHRGBUserClient::externalMethod(uint32_t selector,
                                         IOExternalMethodArguments *args,
                                         IOExternalMethodDispatch *dispatch,
                                         OSObject *target,
                                         void *reference)
{
	if (!fDriver) return kIOReturnNotReady;

	switch (selector) {
	case GHRGB_UC_SET_RGB: {
		if (!args->scalarInput || args->scalarInputCount < 5) return kIOReturnBadArgument;
		const uint64_t *s = args->scalarInput;
		return fDriver->setRGB((UInt8)s[0], (UInt8)s[1], (UInt8)s[2],
		                       (UInt8)s[3], (UInt8)s[4]);
	}
	case GHRGB_UC_SET_BRIGHT: {
		if (!args->scalarInput || args->scalarInputCount < 1) return kIOReturnBadArgument;
		return fDriver->setBrightness((UInt8)args->scalarInput[0]);
	}
	case GHRGB_UC_GET_STATUS: {
		UInt8 buf[8]; UInt32 len = 0;
		IOReturn r = fDriver->getStatus(buf, &len);
		if (r != kIOReturnSuccess) return r;
		if (args->structureOutput && args->structureOutputSize >= len) {
			memcpy(args->structureOutput, buf, len);
			args->structureOutputSize = len;
		}
		return kIOReturnSuccess;
	}
	case GHRGB_UC_GET_BRIGHT: {
		UInt32 lvl = 0;
		IOReturn r = fDriver->getBrightness(&lvl);
		if (r != kIOReturnSuccess) return r;
		if (args->scalarOutput && args->scalarOutputCount >= 1) {
			args->scalarOutput[0] = lvl;
			args->scalarOutputCount = 1;
		}
		return kIOReturnSuccess;
	}
	default:
		return kIOReturnBadArgument;
	}
}
