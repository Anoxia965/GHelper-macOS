/*
 * kmod_stub.cpp —— 手工提供 _kmod_info 符号
 *
 * 背景：Xcode 26 的 ld / ld-classic 在 -kext 模式下不再自动合成 _kmod_info，
 *       导致 kmutil 报 "kexts must have a _kmod_info symbol"。
 *
 * 做法：用 SDK 里 XNU 的权威定义 mach/kmod.h :: kmod_info_t 自己定义这个变量，
 *       start/stop 指向 ld 在 -kext 模式下生成的 __start / __stop 桩函数
 *       （这两个桩由 libkmod.a 的 __realmain / __antimain 提供实现）。
 *
 * 安全性：结构布局由编译器按官方头文件计算，不手写偏移、不 guess。
 */

#include <mach/kmod.h>

extern "C" {

/* kmod_info 的 start/stop 入口桩，符号名精确为 "__start" / "__stop"（双下划线开头）。
 * 这里自己实现，不再依赖 libkmod.a —— 与真机 AsusFanSMC 里 __realmain 为 NULL、
 * 桩直接返回 KERN_SUCCESS 的行为一致（真正的驱动注册由 IOKit personality 完成）。 */
kern_return_t __start(kmod_info_t *ki, void *data) __asm("__start");
kern_return_t __stop(kmod_info_t *ki, void *data) __asm("__stop");

kern_return_t __start(kmod_info_t *, void *)
{
	return KERN_SUCCESS;
}

kern_return_t __stop(kmod_info_t *, void *)
{
	return KERN_SUCCESS;
}

/*
 * c_start.o / c_stop.o 里的桩会被反汇编成：
 *     leaq __realmain(%rip), %rax
 *     movq (%rax), %rax
 *     testq %rax, %rax
 *     je   跳过并返回 0（KERN_SUCCESS）
 *     jmpq *%rax
 *
 * 也就是说 __realmain / __antimain 是【函数指针变量】，而 AsusFanSMC 里它们
 * 实测为全 0（NULL）—— 启动桩因此直接返回 KERN_SUCCESS，不执行任何用户代码。
 * kext 的注册与 IOService 匹配由内核 IOKit 的 driver matching 完成，与此桩无关。
 *
 * 这里显式给出同名符号并置 NULL，与真机在用的 AsusFanSMC 行为完全一致。
 */
void *gh_realmain_slot __asm("__realmain") = NULL;
void *gh_antimain_slot __asm("__antimain") = NULL;

kmod_info_t kmod_info = {
	/* next            */ NULL,
	/* info_version    */ 1,              /* KMOD_INFO_VERSION */
	/* id              */ 0xffffffff,
	/* name            */ "cn.anoxia.GHRGBProbe",
	/* version         */ "1.0.0",
	/* reference_count */ -1,             /* -1 = 未被引用 */
	/* reference_list  */ NULL,
	/* address         */ 0,              /* 由内核在加载时填写 */
	/* size            */ 0,              /* 同上 */
	/* hdr_size        */ 0,
	/* start           */ __start,
	/* stop            */ __stop,
};

} /* extern "C" */
