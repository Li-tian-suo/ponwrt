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
cp /path/to/this/uboot-port/board/*   board/airoha/an7583/
cp /path/to/this/uboot-port/dts/*     arch/arm/dts/

patch -p1 < /path/to/this/uboot-port/patches/foresee-f35sqb002g.diff
patch -p1 < /path/to/this/uboot-port/patches/tfa-foresee-f35sqb002g.diff
```

> **DTS 必须放进 `arch/arm/dts/`，不是 `dts/upstream/src/arm64/airoha/`。**
>
> U-Boot 通过 `dtstree := arch/$(SRCARCH)/boot/dts` 找板级 DTS，实际解析到
> `arch/arm/dts/`。`dts/upstream/` 只用于 `#include` 搜索路径，放在那里的板级
> DTS 是死代码，永远不会被编译。
>
> 板级 DTS 依赖同目录下已有的三个文件，上游树里本来就有：
>
> ```
> arch/arm/dts/an7583.dtsi                         11,662 B
> arch/arm/dts/an758x-recovery-layout-u-boot.dtsi     244 B
> arch/arm/dts/an758x-status-led-u-boot.dtsi          207 B
> ```

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

**必须用 `scripts/build-an758x.sh`，不能只跑 `make`。** 直接 `make` 只产出
`u-boot.bin` 和 `.dtb`，不产出 FIP 和 preloader——它们由脚本驱动 TF-A、
lzma、`airoha_pack_bl2.sh` 和 `fiptool` 打包出来。

```sh
export CROSS_COMPILE=aarch64-openwrt-linux-      # 注意 OpenWrt 工具链名里没有 gnu
export ARM32_CROSS_COMPILE=arm-none-eabi-
export MBEDTLS_DIR=/opt/mbedtls-3.4.1
./scripts/build-an758x.sh hg5580a
```

> `MBEDTLS_DIR` 必须是含 `library/hash_info.c` 的完整源码树。
> TF-A 的 `drivers/auth/mbedtls/mbedtls_common.mk` 硬编码引用这个文件，
> 而 mbedtls 3.6.x 已经删掉了它。所以**只能用 3.4.1**（或 3.5 及更早）。
> OpenWrt 的 `build_dir/.../mbedtls-*` 是 CMake 配置过的目录，不能直接用。

> `CROSS_COMPILE` 一定要显式指定。不指定的话 make 会回退到宿主机的 x86 `cc`，
> 报 `cc1: error: bad value 'armv8-a+crc' for '-march=' switch`。
> 另外 OpenWrt 的工具链文件名是 `aarch64-openwrt-linux-gcc` 和
> `aarch64-openwrt-linux-musl-gcc`，**都没有 `gnu`**，写
> `aarch64-openwrt-linux-gnu-gcc` 会检测不到。

> `O=` 输出目录不要和已有子目录重名。`O=build/hg5580a` 若已存在
> `build/hg5580a/u-boot` 目录，链接时会报
> `ld: cannot open output file u-boot: Is a directory`。

## 产物

```
output/hg5580a/
  an7583-fiberhome-hg5580a-preloader.bin      117,760 B   BL2 FIP
  an7583-fiberhome-hg5580a-bl31-u-boot.fip    373,760 B   BL31 + U-Boot
  u-boot.bin                                  898,080 B
  u-boot.dtb                                   14,560 B
  u-boot.lzma                                 317,185 B
  bl31.lzma                                    54,823 B
  bl2.bin                                     116,156 B
```

> FIP 里的 BL31 与 BL33 都是 LZMA 流，**直接 grep 字符串没有意义**。
> 要按 TOC 解压后再验证：
>
> ```
> BL31 uuid 47d4086d4cfe98469b952950cbbd5a00
> BL33 uuid d6d0eea7fcead54b97829934f234b6e4
> ```
>
> 解压 BL33 后应与 `u-boot.bin` 的 md5 一致，且含 `F35SQB002G`。

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

### FORESEE 批次需要两处补丁，缺一不可

FORESEE 批次的芯片是 `F35SQB002G`，裸 ID 是 `cd 52 52`。上游两个芯片表都不认识它，
而这两张表作用于完全不同的阶段，**必须分别打补丁**。

#### 补丁一：U-Boot 自己的芯片表

```
patches/foresee-f35sqb002g.diff
```

改的是 `drivers/mtd/nand/spi/foresee.c`。不打的话，U-Boot 起来后：

```
spi-nand: unknown raw ID cd 52 52 cd
```

NAND 设备注册失败，U-Boot 读不到自己要启动的闪存。

#### 补丁二：TF-A 的芯片表（BL23 用）

```
patches/tfa-foresee-f35sqb002g.diff
```

改的是 `tf-a/plat/ecnt/common/drivers/flash/spi_nand_flash_table.c` 和
`tf-a/plat/ecnt/en7523/include/ecnt_spi_nand_flash.h`。

**这个补丁才是关键。** 不打的话，连 U-Boot 都到不了：

```
ERROR:   NAND initialization failed: selected=spi
ERROR:   BL23 storage setup failed: status=1
NOTICE:  UBI: scanning [0x0 - 0x0] ...
NOTICE:  UBI: PEB size: 0 bytes (0 KiB), LEB size: 0 bytes
ERROR:   UBI error: No volume named fip could be found
ERROR:   BL2: Failed to load image id 3 (-2)
Press x to load BL31 + U-Boot FIP via XMODEM
```

`PEB size: 0` 说明 MTD 设备根本没建出来，失败发生在 BL23 的 SPI-NAND 探测里，
不是 UBI、也不是 `fip` 卷的问题。

**为什么改 U-Boot 的表不够：** BL23 是 TF-A 编译出来的，用 TF-A 自己的表。
更麻烦的是，在 BL2 优化模式下（`TCSUPPORT_BL2_OPTIMIZATION=1`，
`build-an758x.sh` 总是传这个）那张编译表会被整段条件编译掉：

```c
/* spi_nand_flash_table.c:23 */
#if !defined(TCSUPPORT_BL2_OPTIMIZATION) || defined(FLASH_TABLE_OPEN) || !defined(IMAGE_BL2)
```

BL23 走 `#else` 分支，从 `ECNT_FLASH_TABLE_BASE`（`0x81100000`）读一个**打包进镜像的**
blob：

```c
get_spi_nand_from_mem():
    unsigned char *currentP = (unsigned char *)ECNT_FLASH_TABLE_BASE;
    memcpy(&flash_h, currentP, sizeof(struct bl2_flash_H));
    for (i = 0; i < flash_h.flash_entry; i++) { ...逐字段 memcpy... }
```

所以真实链路是：

```
spi_nand_flash_table.c
  -> cc -DFLASH_TABLE_OPEN -DTCSUPPORT_BL2_OPTIMIZATION
  -> airoha-atf-gen-flash-table        生成 flash_table.bin
  -> lzma
  -> airoha_pack_bl2.sh                打进 bl2.bin
  -> BL23 从 0x81100000 读
```

改源码后必须重新生成 `flash_table.bin` 才生效。验证方法是解压 preloader 里的
`flash_table.lzma`，确认 `flash_entry` 和 FORESEE 表项都在：

```
flash_table.bin  21,188 B  flash_entry = 63
  0x08e7  cd a1  1Gbit  page 2048  erase 128K  OOB 64
  0x0910  cd a2  2Gbit  page 2048  erase 128K  OOB 128
  0x0939  cd b2  2Gbit  page 2048  erase 128K  OOB 128
  0x0962  cd 52  2Gbit  page 2048  erase 128K  OOB 64   <- 新增
```

**注意 OOB 必须是 64，不是 128。** 已有两个 2 Gbit FORESEE 项都是 128 字节 OOB，
直接抄任何一个都会给出错误的 ECC 布局。

打了这个补丁后启动日志变成：

```
NOTICE:  UBI: PEB size: 131072 bytes (128 KiB), LEB size: 126976 bytes
NOTICE:  UBI: Volume fip (Id #0) size is 373760 bytes
NOTICE:  BL23: Booting BL31
spi-nand: FORESEE SPI NAND was found.
```

### 打补丁

在 U-Boot 源码树根目录：

```sh
patch -p1 < uboot-port/patches/foresee-f35sqb002g.diff
patch -p1 < uboot-port/patches/tfa-foresee-f35sqb002g.diff
```

两个补丁都验证过正向应用无冲突、反向撤回后文件与原始完全一致。

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
