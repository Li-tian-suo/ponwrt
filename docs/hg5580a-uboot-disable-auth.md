# 支持未签名 FIP：关闭链式验签的两处补丁

> 适用：`pbs05/uboot-an758x` main 分支（U-Boot 2026.07 + TF-A 2.10）
> 目的：让我编译出的 BL2 能启动**不带证书**的 FIP

## 一、问题

`tf-a/make_helpers/defaults.mk:254` 无条件设置：

```make
TRUSTED_BOARD_BOOT		:= 1
```

于是 `bl2_main.c` 会调用 `crypto_mod_init()` + `auth_mod_init()`，并通过
`load_auth_image()` 加载下一级镜像。这条路要求完整的信任链。

对比原厂 FIP 与我们的 FIP（`fiptool info` 实测）：

```
原厂 FIP（从 bootloader 备份 0x800 处提取）：
  Trusted Boot Firmware BL2                 0x1DEF8
  EL3 Runtime Firmware BL31                 0xDE42
  Non-Trusted Firmware BL33                 0x46263
  Trusted key certificate                   0xA0E     ← 证书
  SoC Firmware key certificate              0x7DA     ← 证书
  Non-Trusted Firmware key certificate      0x7EA     ← 证书
  Trusted Boot Firmware BL2 certificate     0x736     ← 证书
  SoC Firmware content certificate          0x672     ← 证书
  Non-Trusted Firmware content certificate  0x682     ← 证书

我们构建的 FIP：
  EL3 Runtime Firmware BL31                 0xD621
  Non-Trusted Firmware BL33                 0x4CBCB
  （0 张证书）
```

所以**四种组合只有一种是原厂能跑的**：

| 组合 | 结果 |
| --- | --- |
| 原厂 BL2 + 原厂 FIP | ✅ 正常工作 |
| 原厂 BL2 + 我们的 FIP | ❌ 缺 6 张证书，验签失败 |
| 我们的 BL2 + 我们的 FIP（未打补丁） | ❌ 同样验签失败 |
| 我们的 BL2 + 我们的 FIP（**打补丁后**） | ✅ 用 `docs/hg5580a-uboot-port-guide.md` 的流程刷入即可 |

## 二、TF-A 自带的逃生门

`common/bl_common.c` 里已经有运行时开关：

```c
static int load_auth_image_internal(unsigned int image_id, image_info_t *image_data)
{
#if TRUSTED_BOARD_BOOT
	if (dyn_is_auth_disabled() == 0) {
		INFO("4-1\n");
		return load_auth_image_recursive(image_id, image_data, 0);   /* 验签 */
	}
#endif
	INFO("4-2\n");
	return load_image(image_id, image_data);                          /* 跳过 */
}
```

而 `dyn_disable_auth()` 只是把静态变量 `disable_auth` 置 1。

上游唯一的调用点在 `lib/fconf/fconf_tbbr_getter.c:54`，由 `TB_FW_CONFIG`
设备树里的 `disable_auth` 单元驱动：

```c
err = fdt_read_uint32(dtb, node, "disable_auth", &tbbr_dyn_config.disable_auth);
...
#if defined(DYN_DISABLE_AUTH)
	if (tbbr_dyn_config.disable_auth == 1)
		dyn_disable_auth();
#endif
```

**但 ecnt 平台从不填充 fconf TBBR**（全仓搜索 `fconf_populate_tbbr_dyn_config`
在 `plat/ecnt/` 下没有任何调用点），所以在 AN7583 上 `disable_auth` 永远是 0，
这个逃生门从设备树走不到。

## 三、补丁一：在 bl2_main 里主动关闭

`tf-a/bl2/bl2_main.c`，在 `auth_mod_init()` 之后：

```c
#if !defined(IMAGE_BL21) && !defined(IMAGE_BL22)
	crypto_mod_init();

	/* Initialize authentication module */
	auth_mod_init();

#if defined(TCSUPPORT_DISABLE_AUTH)
	/*
	 * 本平台的 FIP 不带证书，信任链无法校验。dyn_disable_auth() 让
	 * load_auth_image_internal() 落到 load_image()，完全跳过验签。
	 * 上游只能通过 fconf TBBR getter 走到这里，而 ecnt 平台不填充
	 * fconf TBBR，所以没有这个调用时 BL2 会以 "Authentication failed" 中止。
	 */
	dyn_disable_auth();
#endif
#endif
```

## 四、补丁二：把宏注册成编译器 define

**这一步容易漏掉。** `TCSUPPORT_*` 变量**不会**自动变成 `-D` 参数，
必须显式 `add_define`。`platform.mk` 里只有 `ifeq` 判断，真正的注册集中在
`tf-a/Makefile`。

在 `tf-a/Makefile` 的 `TCSUPPORT_CPU_AN7583` 区块之后加：

```make
# Build a BL2 that skips chain-of-trust verification, so an FIP without
# certificates can be booted.  See bl2/bl2_main.c for the call site.
ifneq ($(strip $(TCSUPPORT_DISABLE_AUTH)),)
$(eval $(call add_define,TCSUPPORT_DISABLE_AUTH))
endif
```

## 五、验证

编译时传入 `TCSUPPORT_DISABLE_AUTH=1`，然后反汇编确认调用真的进去了：

```
$ arm-none-eabi-objdump -d build/en7523/release/bl2/bl2.elf | grep -A12 '<bl2_main>:'
  81000e7c  bl  crypto_mod_init
  81000e80  bl  auth_mod_init
  81000e84  bl  dyn_disable_auth     ← 补丁生效
  81000e88  bl  bl2_plat_preload_setup
  81000e8c  bl  bl2_load_images
```

`bl2.bin` 从 116,146 B 变成 116,170 B（+24 字节，正是那次 `bl` 指令）。

只加补丁一、不加补丁二时，反汇编里**看不到** `dyn_disable_auth`——因为
`#if defined(TCSUPPORT_DISABLE_AUTH)` 恒假，整个代码块被预处理器删掉了。

## 六、运行时的实际效果

启动串口会打印：

```
NOTICE:  BL2: v2.10(...)
INFO:    Disabling authentication of images dynamically
...
INFO:    4-2
```

`4-2` 就是 `load_image()` 分支（跳过验签）；如果看到 `4-1` 说明仍在验签。

## 七、构建命令

```sh
export CROSS_COMPILE=aarch64-linux-gnu-
export ARM32_CROSS_COMPILE=arm-none-eabi-
export MBEDTLS_DIR=/opt/mbedtls-3.4.1   # 必须是 3.4.x，3.6.x 删了 hash_info.c

# 上游脚本不透传 TCSUPPORT_DISABLE_AUTH，需要手工驱动 TF-A，
# 参数照抄 scripts/build-an758x.sh 里的 common_atf_args，再加这一项：
TCSUPPORT_DISABLE_AUTH=1
```

## 八、安全性说明

这个补丁**降低了引导阶段的安全保证**：BL2 不再校验 BL31/BL33 的签名。
对本项目而言这是刻意的取舍——

- 原厂私钥拿不到，无法生成原厂能验过的 FIP
- 自签名 FIP 只能配合自编 BL2
- 而自编 BL2 本身也要写进 flash，这一步只能靠 XMODEM 救

如果只是临时测试，**更安全的做法是不要写 flash**：用 x 模式
（`tools/xmodem-send.ps1`）把 FIP 送进内存再启动，FIP 不落盘，重启即失效。
