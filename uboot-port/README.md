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
  an7583-fiberhome-hg5580a-preloader.bin      117,760 B   BL2 FIP
  an7583-fiberhome-hg5580a-bl31-u-boot.fip    370,688 B   BL31 + U-Boot
  u-boot.bin                                  890,024 B
  u-boot.dtb                                   14,304 B
```

### 两个 FIP 分别写到哪里

`preloader.bin` 和 `bl31-u-boot.fip` 是**两种不同的 FIP**，落到完全不同的地方：

```
preloader.bin           单条 UUID[0]，是 BL2 自己
                        写入 bl2 分区（0x0，恰好一个 128 KiB 擦除块）
                        实际落在块内偏移 0x800

bl31-u-boot.fip         两条 UUID[1]+UUID[2]，是 BL31 与 U-Boot
                        写入 UBI 的 "fip" 卷
```

BL2 启动后从 UBI 的 `fip` 卷读取 BL31 与 U-Boot，所以真正换掉 U-Boot 的是
第二个文件，不是第一个。

### 刷 bl2 时的大小陷阱

U-Boot 的 `prepare_bl2_image()` 有两条分支，选错会**变砖**：

```c
/* 路径 A：输入恰好一个擦除块 */
if (size == block_size && boot_fip_valid(data + 0x800, size - 0x800, true)) {
        memcpy(image, data, size);        /* 0x0..0x800 保留 */
}

/* 路径 B：输入是裸 FIP */
if (size <= block_size - 0x800 && boot_fip_valid(data, size, true)) {
        memset(image, 0xff, block_size);  /* 0x0..0x800 被抹成 0xFF */
        memcpy(image + 0x800, data, size);
}
```

`0x0..0x800` 是 BL1 阶段的 ARM32 入口代码（写 SCTLR、切处理器模式、设 VBAR、
启 MMU），不是填充。直接上传 `preloader.bin`（117,760 字节）会走路径 B，把这段
代码抹掉，SoC 从 `0x0` 取指遇到全 `0xFF`，串口再无输出。

正确做法是构造 131,072 字节的镜像：

```
0x00000 - 0x00800   厂商 bootloader 的前 0x800 字节，原样保留
0x00800 - 0x1CE00   preloader.bin
0x1CE00 - 0x20000   0xFF 填充
```

细节与恢复步骤见 `docs/flashing-and-recovery-full.md`。

## 硬件

| 项 | 值 |
| --- | --- |
| SoC | Airoha AN7583（2× Cortex-A53） |
| DRAM | 512 MiB |
| NAND | 两种批次：SkyHigh S35ML02G300（OOB 128）或 FORESEE F35SQB002G（OOB 64），均 256 MiB，2 KiB page |
| 串口 | UART1 `0x1fbf0000`，115200 8N1 |
| 2.5G PHY | Motorcomm YT8821，MDIO 0x07，lan1（gdm3） |
| switch | MediaTek MT7530，lan2~lan4（gdm1） |
| PON | Airoha UX3363 paged BOSA，I2C 0x51 |
| 复位键 | GPIO 35，低有效 |
| PHY 复位 | GPIO 28，低有效（原厂名 `an8811_reset`） |
| PHY TX 使能 | GPIO 15，高有效（原厂名 `phy_tx_power_disable`） |

### FORESEE 批次需要额外补丁

上游 `foresee.c` 只认识 F35SQA 家族（设备 ID `0x71`/`0x72`）。FORESEE 批次的
裸 ID 是 `cd 52 52`，不在表里，于是：

```
spi_nand nand@0: unknown raw ID cd 52 52 cd
```

NAND 设备注册失败，U-Boot 读不到自己要启动的闪存。`patches/foresee-f35sqb002g.diff`
补上 `F35SQB002G`（设备 ID `0x52`），几何参数与 F35SQA002G 相同。

## 救援

**XMODEM（x 模式）**：上电后 BL2 请求 FIP 时按 `x`，用 XMODEM 发送
`*-bl31-u-boot.fip`。FIP 只在内存里，不写 flash，所以可以无限次重试。

**Web 恢复**：U-Boot 起来后网线插 lan1~lan4，PC 设 `192.168.0.2/24`，
浏览器开 `http://192.168.0.1/`。

**BL2 自身刷坏**（上电串口完全无输出）：Boot ROM 只从 `0x800` 读 FIP，那段代码
没了就没有任何软件入口。需要拆下 SPI-NAND 用编程器写回备份的
`bootloader.bin`（2,621,440 字节，md5 `986fee15e5ad66ead92cadc7089ebb44`），
写回地址 `0x0`。

详见 `docs/flashing-and-recovery-full.md`。
