//
//  fanread.c —— 直连 AppleSMC 读风扇/键信息（SMC 读不需要 root，但用管理员权限跑最稳）
//  用法：fanread           读一组默认键
//        fanread F0Ac F0Mx 读指定键
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

#define kMethodIndex 2
#define Off_key      0
#define Off_dataSize 28
#define Off_dataType 32
#define Off_result   40
#define Off_data8    42
#define Off_bytes    48
#define BufSize      80
#define Cmd_readBytes    5
#define Cmd_readKeyInfo  9

static UInt32 fourCC(const char* s) {
    UInt32 v = 0; char c[4];
    for (int i = 0; i < 4; i++) c[i] = (i < (int)strlen(s)) ? s[i] : ' ';
    for (int i = 0; i < 4; i++) v |= (UInt32)(unsigned char)c[i] << (24 - 8 * i);
    return v;
}

// 通用 SMC 调用；返回 0 成功。输出 dataSize、类型(4 字符)、字节负载(32)
static int smc_call(io_connect_t conn, UInt8 cmd, const char* key,
                    UInt32 ds_in, const char* type_in, UInt8* payload_in,
                    UInt32* ds_out, char* type_out, UInt8* bytes_out) {
    UInt8 in[BufSize]; memset(in, 0, sizeof(in));
    UInt32 k = fourCC(key);
    for (int i = 0; i < 4; i++) in[Off_key + i] = (k >> (8 * i)) & 0xFF;
    in[Off_data8] = cmd;
    if (ds_in) for (int i = 0; i < 4; i++) in[Off_dataSize + i] = (ds_in >> (8 * i)) & 0xFF;
    if (type_in) { UInt32 tv = fourCC(type_in); for (int i = 0; i < 4; i++) in[Off_dataType + i] = (tv >> (8 * i)) & 0xFF; }
    if (payload_in) for (int i = 0; i < 32; i++) in[Off_bytes + i] = payload_in[i];

    UInt8 out[BufSize]; memset(out, 0, sizeof(out));
    size_t outCnt = BufSize;
    kern_return_t kr = IOConnectCallStructMethod(conn, kMethodIndex, in, BufSize, out, &outCnt);
    if (kr != KERN_SUCCESS) return -1;
    if (out[Off_result] != 0) return -2;
    *ds_out = out[Off_dataSize] | out[Off_dataSize+1]<<8 | out[Off_dataSize+2]<<16 | out[Off_dataSize+3]<<24;
    UInt32 tv = out[Off_dataType] | out[Off_dataType+1]<<8 | out[Off_dataType+2]<<16 | out[Off_dataType+3]<<24;
    for (int i = 0; i < 4; i++) type_out[i] = (tv >> (8 * i)) & 0xFF;
    type_out[4] = 0;
    for (int i = 0; i < 32; i++) bytes_out[i] = out[Off_bytes + i];
    return 0;
}

static double decode(UInt8* b, int n, const char* type) {
    if (n < 1) return 0;
    unsigned u16 = (n >= 2) ? (b[0]<<8 | b[1]) : b[0];
    UInt32 u32 = (n >= 4) ? (b[0]<<24 | b[1]<<16 | b[2]<<8 | b[3]) : 0;
    if (!strcmp(type, "ui8 ")) return b[0];
    if (!strcmp(type, "si8 ")) return (double)(signed char)b[0];
    if (!strcmp(type, "fpe2")) return (double)u16 / 4.0;   // 14.2 定点
    if (!strcmp(type, "ui16")) return u16;
    if (!strcmp(type, "si16")) return (double)(short)u16;
    if (!strcmp(type, "ui32")) return (double)u32;
    if (!strcmp(type, "si32")) return (double)(int)u32;
    if (!strcmp(type, "flt ")) return (double)(float)(UInt32)u32;
    if (n == 2) return u16;
    if (n == 4) return (double)u32;
    return b[0];
}

int main(int argc, char** argv) {
    mach_port_t master; IOMasterPort(0, &master);
    io_iterator_t iter;
    IOServiceGetMatchingServices(master, IOServiceMatching("AppleSMC"), &iter);
    io_service_t s = IOIteratorNext(iter); IOObjectRelease(iter);
    io_connect_t conn;
    kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &conn);
    IOObjectRelease(s);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "open AppleSMC fail 0x%x\n", kr); return 1; }

    const char* def[] = {"FNum","F0Ac","F0Mn","F0Mx","F0Tg","F0Md","F1Ac","F1Mx","F1Tg","F1Md",NULL};
    const char** keys = (argc > 1) ? (const char**)(argv + 1) : def;

    for (int i = 0; keys[i]; i++) {
        char key[8]; strncpy(key, keys[i], 4); key[4] = 0;
        UInt32 k = fourCC(key);
        // keyInfo
        UInt8 in2[BufSize]; memset(in2, 0, sizeof(in2));
        for (int j = 0; j < 4; j++) in2[Off_key + j] = (k >> (8*j)) & 0xFF;
        in2[Off_data8] = Cmd_readKeyInfo;
        UInt8 out2[BufSize]; memset(out2, 0, sizeof(out2)); size_t oc = BufSize;
        kr = IOConnectCallStructMethod(conn, kMethodIndex, in2, BufSize, out2, &oc);
        if (kr != KERN_SUCCESS) { printf("%s: keyinfo_fail(0x%x)\n", key, kr); continue; }
        if (out2[Off_result] != 0) { printf("%s: not_found\n", key); continue; }
        UInt32 ds = out2[Off_dataSize] | out2[Off_dataSize+1]<<8 | out2[Off_dataSize+2]<<16 | out2[Off_dataSize+3]<<24;
        UInt32 tv = out2[Off_dataType] | out2[Off_dataType+1]<<8 | out2[Off_dataType+2]<<16 | out2[Off_dataType+3]<<24;
        char type[5]; for (int j = 0; j < 4; j++) type[j] = (tv >> (8*j)) & 0xFF; type[4] = 0;
        // SMC 把 dataType 倒序存，Swift 端再反转一次得到 "fpe2"；这里同样反转以对齐
        char typeR[5]; for (int j = 0; j < 4; j++) typeR[j] = type[3 - j]; typeR[4] = 0;
        // read bytes
        UInt8 in3[BufSize]; memset(in3, 0, sizeof(in3));
        for (int j = 0; j < 4; j++) in3[Off_key + j] = (k >> (8*j)) & 0xFF;
        in3[Off_data8] = Cmd_readBytes;
        for (int j = 0; j < 4; j++) in3[Off_dataSize + j] = (ds >> (8*j)) & 0xFF;
        // 读请求不写 dataType（与 SMC.swift readRaw 一致：只给 dataSize）
        UInt8 out3[BufSize]; memset(out3, 0, sizeof(out3)); oc = BufSize;
        kr = IOConnectCallStructMethod(conn, kMethodIndex, in3, BufSize, out3, &oc);
        double val = 0;
        UInt32 n = 0;
        if (kr == KERN_SUCCESS && out3[Off_result] == 0) {
            // 输出体的 dataSize 字段常为 0，实际字节数用 keyInfo 的 ds（与 SMC.swift 一致）
            n = ds;
            val = decode(&out3[Off_bytes], (int)n, typeR);
        } else {
            printf("%s: kr=0x%x result=0x%x\n", key, kr, out3[Off_result]);
            continue;
        }
        printf("%-5s type=%-4s size=%-2u = %.3f  raw=", key, type, ds, val);
        for (int j = 0; j < (int)n && j < 8; j++) printf("%02x ", out3[Off_bytes + j]);
        printf("\n");
    }
    IOServiceClose(conn);
    return 0;
}
