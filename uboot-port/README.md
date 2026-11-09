# HG5580A 专用 U-Boot

基于 [pbs05/uboot-an758x](https://github.com/pbs05/uboot-an758x)（U-Boot 2026.07 + TF-A），
为 FiberHome HG5580A 新增板级支持。

完整刷机指南见 [docs/hg5580a-uboot-port-guide.md](../docs/hg5580a-uboot-port-guide.md)。

## 目录

```
configs/an7583_fiberhome_hg5580a_defconfig       defconfig
board/an7583_fiberhome_hg5580a.env               环境变量（Web/TFTP/UBI）
dts/an7583-fiberhome-hg5580a.dts                 板级设备树
dts/an7583-fiberhome-hg5580a-u-boot.dtsi         U-Boot 专用节点（UBI 卷布局）
```

## 安装到上游源码树

```sh
git clone https://github.com/pbs05/uboot-an758x.git
cd uboot-an758x

cp /path/to/this/uboot-port/configs/* configs/
cp /path/to/this/uboot-port/board/* board/airoha/an7583/
cp /path/to/this/uboot-port/dts/*   arch/arm/dts/
```

然后注册构建目标——在 `scripts/build-an758x.sh` 的 `case "$board"` 里
`xg-040g-mf)` 之前插入：

```sh
hg5580a)
	defconfig=an7583_fiberhome_hg5580a_defconfig
	artifact_prefix=an7583-fiberhome-hg5580a
	soc=AN7583
	parallel_nand=0
	;;
```

同时把 `hg5580a` 加进 `usage` 那一行的目标列表。

## 编译

```sh
export CROSS_COMPILE=aarch64-linux-gnu-
export ARM32_CROSS_COMPILE=arm-none-eabi-
export MBEDTLS_DIR=/opt/mbedtls-3.4.1
./scripts/build-an758x.sh hg5580a
```

> `MBEDTLS_DIR` 必须是含 `library/hash_info.c` 的完整源码树。
> TF-A 的 `drivers/auth/mbedtls/mbedtls_common.mk` 硬编码引用这个文件，
> 而 mbedtls 3.6.x 已经删掉了它。所以**只能用 3.4.1**（或 3.5 及更早）。
> OpenWrt 的 `build_dir/.../mbedtls-*` 是 CMake 配置过的目录，不能直接用。

## 产物

```
output/hg5580a/
  an7583-fiberhome-hg5580a-preloader.bin      117,760 B   BL2 → NAND 0x0
  an7583-fiberhome-hg5580a-bl31-u-boot.fip    370,688 B   BL31+U-Boot
  u-boot.bin                                  890,024 B
  u-boot.dtb                                   14,304 B
```

## 硬件

| 项 | 值 |
| --- | --- |
| SoC | Airoha AN7583（2× Cortex-A53） |
| DRAM | 512 MiB |
| NAND | Gigadevice S35ML02G3，256 MiB，2 KiB page / 128 B OOB |
| 串口 | UART1 `0x1fbf0000`，115200 8N1 |
| 2.5G PHY | Motorcomm YT8821，MDIO 0x07，lan1（gdm3） |
| switch | MediaTek MT7530，lan2~lan4（gdm1） |
| PON | Airoha UX3363 paged BOSA，I2C 0x51 |
| 复位键 | GPIO 35，低有效 |
| PHY 复位 | GPIO 28，低有效（原厂名 `an8811_reset`） |
| PHY TX 使能 | GPIO 15，高有效（原厂名 `phy_tx_power_disable`） |

## 救援

**XMODEM（x 模式）**：上电后 BL2 请求 FIP 时按 `x`，用 XMODEM 发送
`*-bl31-u-boot.fip`。FIP 只在内存里，不写 flash，所以可以无限次重试。

**Web 恢复**：U-Boot 起来后网线插 lan1~lan4，PC 设 `192.168.0.2/24`，
浏览器开 `http://192.168.0.1/`。

详见完整指南。
