# PonWrt for FiberHome HG5580A

Airoha AN7583 XG-PON ONU 上的 OpenWrt 移植，含自研 U-Boot 引导链。

---

## 这是什么

FiberHome HG5580A 是一台 XG-PON 光猫，主控 Airoha AN7583。本仓库提供：

| 组成 | 内容 |
| --- | --- |
| **固件** | PonWrt（基于 ImmortalWrt 的 OpenWrt 分支），UBI 布局 |
| **U-Boot** | 自编译 U-Boot 2026.07 + TF-A 2.10，带 Web 恢复页面 |
| **驱动** | XG-PON 协议栈、UX3363 光模块、YT8821 2.5G PHY、MT7530 交换 |
| **云编译** | GitHub Actions 一键出固件 + bootloader |

---

## 硬件

| 项目 | 规格 |
| --- | --- |
| SoC | Airoha AN7583，2× Cortex-A53 |
| 内存 | 512 MiB DDR |
| 闪存 | SkyHigh ML02G300WH100 (S35ML02G300)，256 MiB SPI-NAND<br>128 KiB 块 / 2 KiB 页 / 128 B OOB |
| 2.5G PHY | Motorcomm **YT8821**（OUI `0x13D47A`，MDIO `0x07`），lan1 |
| 交换 | MediaTek **MT7530**，lan2~lan4 |
| 光模块 | Airoha **UX3363** paged BOSA，I2C `0x51` |
| 串口 | UART1 `0x1fbf0000`，115200 8N1 |
| 复位键 | GPIO 35，低有效 |

以上全部为**实机验证**（`mii info` / `spi-nand` 探测日志 / `/api/device`）。

---

## 为什么需要自研 U-Boot

原厂 U-Boot 2023.04 有四个硬伤：

| 问题 | 现象 |
| --- | --- |
| `ldkernel` 强制 X.509 验签 | 未签名内核直接卡死，无法启动自制固件 |
| YT8821 只跑 100baseT | 实测协商到 **10baseT HDX**，TFTP 慢到无法使用 |
| 没有任何救援手段 | 刷错一次就变砖，只能上编程器 |
| 不支持 UBI 启动 | 只能从裸分区 `mtd read` + `bootm` |

自研 U-Boot 解决全部四项：

```
U-Boot 2026.07 (Nov 10 2026)
CPU:   Airoha AN7583
DRAM:  512 MiB
spi_nand nand@0: SkyHigh SPI NAND was found.
spi-nand: 256 MiB, block size: 128 KiB, page size: 2048, OOB size: 128

U-Boot HG5580A
1. Boot system          5. Flash U-Boot via TFTP
2. Web recovery         6. Flash BL2 via TFTP
3. Boot initramfs       7. Show storage
4. Flash system         8. Reboot

HTTP management: http://192.168.0.1/
```

---

## 分区布局：保留原厂，只动 apps

这是本方案的核心设计决策。

```
0x00000000  0x280000  bootloader     原厂 BL2+FIP（刷 U-Boot 时替换）
0x0280000   0x80000   bootflag       原厂 A/B 选择器
0x0300000   0x600000  KernelA        原厂系统槽 A ┐
0x0900000   0x2800000 RootfsA        原厂系统槽 A ┘ 可回退
0x3100000   0x600000  KernelB        原厂系统槽 B ┐
0x3700000   0x2800000 RootfsB        原厂系统槽 B ┘ 可回退
0x5f00000   0x6800000 apps      ★    UBI（104 MiB）
0xc700000   0x1000000 frameworka
0xd700000   0x1000000 frameworkb
0xe700000   0x500000  factory   ★★   永不写入
```

**为什么不全盘改 UBI：** `factory` 存放 MAC 地址、PON 序列号、光模块校准数据，是这台机器上唯一不可恢复的数据。把它排除在任何 U-Boot 写入范围之外，意味着即使刷机失败也绝不会丢设备身份。

UBI 卷（全部在 `apps` 内）：

```
fip          1 MiB static    BL31 + U-Boot
fit          dynamic         系统固件
rootfs_data  dynamic         可写 overlay
ubootenv     124 KiB         U-Boot 环境（双份，掉电安全）
ubootenv2    124 KiB
bosa         372 KiB         UX3363 校准
ri           372 KiB         板级身份
```

---

## 关键技术点

### 1. 关闭链式验签

TF-A `defaults.mk` 无条件设置 `TRUSTED_BOARD_BOOT := 1`，BL2 会走
`load_auth_image()` 要求完整信任链。原厂 FIP 带 6 张证书，我们的一张也没有：

```
原厂 FIP:  BL2 / BL31 / BL33
         + trusted-key-cert / soc-fw-key-cert / nt-fw-key-cert
         + tb-fw-cert / soc-fw-cert / nt-fw-cert

我们的 FIP: BL31 / BL33
```

TF-A 自带逃生门：

```c
#if TRUSTED_BOARD_BOOT
        if (dyn_is_auth_disabled() == 0)
                return load_auth_image_recursive(...);   /* 验签 */
#endif
        return load_image(...);                          /* 跳过 */
```

但 ecnt 平台**从不填充 fconf TBBR**（全仓搜索 `fconf_populate_tbbr_dyn_config`
在 `plat/ecnt/` 下无调用点），所以 `disable_auth` 永远是 0，从设备树走不到。

补丁直接在 `bl2_main.c` 里调 `dyn_disable_auth()`。**关键的第二半**：
`TCSUPPORT_*` 变量不会自动变成 `-D`，必须在 `tf-a/Makefile` 里 `add_define`
注册，否则 `#if` 恒假、代码被预处理器删掉——这是第一次尝试失败的真实原因。

验证方式（反汇编）：

```
81000e80  bl  auth_mod_init
81000e84  bl  dyn_disable_auth     ← 必须出现这一行
81000e8c  bl  bl2_load_images
```

### 2. 从 RAM 测试，不写 flash

`go 0x90000000` 直接运行 TFTP 下载的 `u-boot.bin`，全程不碰 flash。
这让我们能在零风险下确认：板级 DTS、SPI-NAND 驱动、网络、Web 服务全部正常。

### 3. Web 恢复 + XMODEM 双救援

**XMODEM（x 模式）**：BL2 找不到 FIP 时请求 XMODEM，FIP 只进内存，可无限重试。

**Web 恢复**：`http://192.168.0.1/`，中英文，功能包括

- Flash BL2 / Flash U-Boot / Install system
- Rebuild UBI
- Backup（分区级备份，支持 factory）
- RAM boot（上传 initramfs 只在内存跑）
- Clear bad block markers（`erase.scrub=1`）
- Command console

### 4. 闪存：SkyHigh 的特殊性

SkyHigh 驱动把 ECC 存在**隐藏区**，OOB 只留 2 字节给坏块标记：

```c
static int skyhigh_spinand_ooblayout_free(...)
{
        region->offset = 2;
        region->length = mtd->oobsize - 2;   /* 128 - 2 = 126 字节可用 */
}
```

这与某些 NAND（OOB 全被 ECC 占用）不同，直接影响文件系统选择。

---

## 固件特性

基于 ImmortalWrt 快照，面向光猫场景裁剪：

| 类别 | 包 |
| --- | --- |
| PON | `kmod-airoha-xpon` / `kmod-airoha-paged-bosa` / `airoha-ponctl` / `airoha-pond` |
| 网络 | `kmod-phy-motorcomm`（YT8821）/ `kmod-phy-airoha-en8811h` |
| 存储 | `fitblk`（必须，用于从 FIT 释放 rootfs 块设备）|
| Web | `luci-light` / `luci-app-pon` / `luci-app-firewall` |
| 代理 | `homeproxy` + `sing-box-tiny`（替代 openclash，体积更小）|
| 工具 | `htop` / `e2fsprogs` / `dropbear` |

**刻意去掉**：USB 相关（本机无 USB）、硬盘休眠、`libcronet`（`sing-box` 的
`NAIVE_OUTBOUND` 是 `def_bool y`，会拉 Chromium 工具链导致编译卡死）。

---

## 快速开始

```powershell
# 1. 备份（必做，尤其 factory）
.\tools\backup-via-web.ps1 -Only factory

# 2. 进 U-Boot，Web 页面三步
#    Rebuild UBI -> Flash U-Boot -> Install system

# 3. 最后才刷 BL2
#    Web -> Flash BL2
```

详细步骤见 [hg5580a-flash-guide.md](hg5580a-flash-guide.md)。

---

## 仓库结构

```
board/
  an7583-fiberhome-hg5580a.dts      Linux 设备树
  hg5580a-ubi.mk.snippet            UBI 设备定义
  hg5580a.mk.snippet                原厂布局设备定义
  airoha-paged-bosa-an7583.patch    修正 AN7583 下 BOSA 包不可见

uboot-port/
  configs/an7583_fiberhome_hg5580a_defconfig
  board/an7583_fiberhome_hg5580a.env
  dts/an7583-fiberhome-hg5580a.dts           U-Boot 设备树（原厂 10 分区）
  dts/an7583-fiberhome-hg5580a-u-boot.dtsi
  patch-tfa-unsigned.sh                      关闭链式验签（两处补丁）

tools/
  backup-via-web.ps1      分区备份（走 Web API）
  xmodem-send.ps1         XMODEM 发送（x 模式救援）
  serial-batch.ps1        串口批量命令

docs/
  hg5580a-flash-guide.md         刷机教程（本文档配套）
  hg5580a-uboot-port-guide.md    U-Boot 移植详解
  hg5580a-uboot-disable-auth.md  验签补丁推导
  hg5580a-overlay-postmortem.md  overlay 排查记录
  hg5580a-flash-risks.md         刷机风险说明
  hg5380a-vs-hg5580a-hardware.md 两机型硬件对比
```

---

## 云编译

`.github/workflows/build-hg5580a-ubi.yml`

```
Actions -> Build HG5580A UBI + U-Boot -> Run workflow
```

同时产出：

```
固件:
  ponwrt-...-hg5580a-ubi-squashfs-sysupgrade.itb
  ponwrt-...-hg5580a-ubi-initramfs-recovery.itb
引导:
  an7583-fiberhome-hg5580a-preloader.bin
  an7583-fiberhome-hg5580a-bl31-u-boot.fip
```

workflow 里有硬性校验（设备被选中、`fitblk` 在、`kmod-airoha-paged-bosa` 在、
`bl2_main` 真的调了 `dyn_disable_auth`），任何一项不满足直接失败，不会产出半成品。

---

## 已知限制

| 项 | 状态 |
| --- | --- |
| XG-PON 注册 | 需接光纤验证（开发时无光纤） |
| GPON | 不支持，`airoha-xpon` 的 GPON 入口故意省略 `.mac_supported` |
| 光口测速 | 待光纤接入 |
| 2.5G 吞吐 | 早期镜像实测 down 2.17 Gbps / up 1.26 Gbps |
| `calibration invalid` | 原厂 `bosacal` 是私有格式，未解析 |

---

## 致谢

- [pbs05/uboot-an758x](https://github.com/pbs05/uboot-an758x) — U-Boot/TF-A AN758x 支持
- [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha) — TF-A Airoha 平台
- ImmortalWrt / OpenWrt — 固件基础
- openwrt-pon-drivers — PON 驱动栈

## 许可

固件部分遵循 GPL-2.0。U-Boot/TF-A 补丁遵循各自上游许可。
