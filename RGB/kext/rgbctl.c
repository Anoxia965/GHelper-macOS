/*
 * rgbctl —— GHRGB kext 的用户态测试/调试工具（GHelper root 助手同款调用）
 *
 * 用法（root）：
 *   rgbctl set <mode> <r> <g> <b> <speed>   设颜色（speed: 0=慢 1=常 2=快）
 *   rgbctl bright <0-15>                    设亮度等级
 *   rgbctl get                              读回 8 字节状态（颜色）
 *   rgbctl getbright                        读回亮度等级
 *   rgbctl wmnb <sig> <devid> <a1> <a2> <a3> <a4>
 *                                          通用 WMNB 直通（sig: 0x53564544=DEVS 写 / 0x53545344=DSTS 查）
 *
 * 例：rgbctl wmnb 0x53545344 0x00110024 0 0 0 0   （查 CPU 风扇曲线缓存）
 *     rgbctl wmnb 0x53564544 0x00110024 <t0..3> <d0..3> <t4..7> <d4..7>
 *                                           （写 CPU 风扇曲线：8 点温度/占空比各 4 字节）
 *
 * 编译：clang -framework IOKit -framework CoreFoundation -o rgbctl rgbctl.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

#define GHRGB_UC_SET_RGB    0
#define GHRGB_UC_SET_BRIGHT 1
#define GHRGB_UC_GET_STATUS 2
#define GHRGB_UC_GET_BRIGHT 3
#define GHRGB_UC_CALL_WMNB  4

/* WMNB sig 前缀（与内核 callWMNB 一致） */
#define WMNB_DEVS 0x53564544  /* "DEVS" 写 */
#define WMNB_DSTS 0x53545344  /* "DSTS" 查 */

static io_connect_t g_conn = IO_OBJECT_NULL;

static int open_client(void) {
	io_service_t svc = IOServiceGetMatchingService(
		kIOMasterPortDefault, IOServiceMatching("GHRGB"));
	if (svc == IO_OBJECT_NULL) {
		fprintf(stderr, "找不到 GHRGB 服务（驱动未加载？）\n");
		return -1;
	}
	kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
	IOObjectRelease(svc);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "IOServiceOpen 失败：%x（需 root）\n", kr);
		return -1;
	}
	return 0;
}

static void close_client(void) {
	if (g_conn != IO_OBJECT_NULL) { IOServiceClose(g_conn); g_conn = IO_OBJECT_NULL; }
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr,
			"用法:\n"
			"  rgbctl set <mode> <r> <g> <b> <speed>\n"
			"  rgbctl bright <0-15>\n"
			"  rgbctl get\n"
			"  rgbctl getbright\n"
			"  rgbctl wmnb <sig> <devid> <a1> <a2> <a3> <a4>\n");
		return 2;
	}
	if (open_client() != 0) return 1;

	int rc = 0;
	kern_return_t kr;

	if (strcmp(argv[1], "set") == 0 && argc >= 7) {
		uint64_t in[5] = {
			strtoul(argv[2], NULL, 0), strtoul(argv[3], NULL, 0),
			strtoul(argv[4], NULL, 0), strtoul(argv[5], NULL, 0),
			strtoul(argv[6], NULL, 0) };
		kr = IOConnectCallScalarMethod(g_conn, GHRGB_UC_SET_RGB, in, 5, NULL, NULL);
		printf("setRGB -> %s (%x)\n", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
		rc = (kr == KERN_SUCCESS) ? 0 : 1;

	} else if (strcmp(argv[1], "bright") == 0 && argc >= 3) {
		uint64_t in[1] = { strtoul(argv[2], NULL, 0) };
		kr = IOConnectCallScalarMethod(g_conn, GHRGB_UC_SET_BRIGHT, in, 1, NULL, NULL);
		printf("setBright -> %s (%x)\n", kr == KERN_SUCCESS ? "OK" : "FAIL", kr);
		rc = (kr == KERN_SUCCESS) ? 0 : 1;

	} else if (strcmp(argv[1], "get") == 0) {
		uint8_t out[8]; size_t outCnt = sizeof(out);
		kr = IOConnectCallStructMethod(g_conn, GHRGB_UC_GET_STATUS, NULL, 0, out, &outCnt);
		if (kr == KERN_SUCCESS) {
			printf("getStatus len=%zu: ", outCnt);
			for (uint32_t i = 0; i < outCnt; i++) printf("%02x ", out[i]);
			printf("\n");
		} else {
			printf("getStatus -> FAIL (%x)\n", kr); rc = 1;
		}

	} else if (strcmp(argv[1], "getbright") == 0) {
		uint64_t out = 0; uint32_t outCnt = 1;
		kr = IOConnectCallScalarMethod(g_conn, GHRGB_UC_GET_BRIGHT, NULL, 0, &out, &outCnt);
		if (kr == KERN_SUCCESS) printf("getBright level=%llu\n", out);
		else { printf("getBright -> FAIL (%x)\n", kr); rc = 1; }

	} else if (strcmp(argv[1], "wmnb") == 0 && argc >= 8) {
		uint64_t in[6] = {
			strtoul(argv[2], NULL, 0), strtoul(argv[3], NULL, 0),
			strtoul(argv[4], NULL, 0), strtoul(argv[5], NULL, 0),
			strtoul(argv[6], NULL, 0), strtoul(argv[7], NULL, 0) };
		uint8_t out[16]; size_t outCnt = sizeof(out);
		kr = IOConnectCallStructMethod(g_conn, GHRGB_UC_CALL_WMNB, in, sizeof(in), out, &outCnt);
		if (kr == KERN_SUCCESS) {
			printf("wmnb sig=%llx devid=%llx -> OK len=%zu: ",
				in[0], in[1], outCnt);
			for (uint32_t i = 0; i < outCnt; i++) printf("%02x ", out[i]);
			printf("\n");
		} else {
			printf("wmnb sig=%llx devid=%llx -> FAIL (%x)\n", in[0], in[1], kr);
			rc = 1;
		}

	} else {
		fprintf(stderr, "未知命令：%s\n", argv[1]);
		rc = 2;
	}

	close_client();
	return rc;
}
