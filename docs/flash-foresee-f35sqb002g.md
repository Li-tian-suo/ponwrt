# FORESEE F35SQB002G 适配笔记

> HG5580A 生产批次所用 SPI-NAND
> 本文记录从「认不出芯片」到「完整识别」的全部过程与证据

---

## 1. 现象

新机用我们编的 U-Boot 从 RAM 启动（`go`），打印：

```
U-Boot 2026.07 (Nov 10 2026 - 12:13:46 +0800)
CPU:   Airoha AN7583
DRAM:  512 MiB
Core:  38 devices, 22 uclasses, devicetree: separate
Loading Environment from UBI... spi-nand: spi_nand nand@0: unknown raw ID cd 52 52 cd
Partition ubi not found!
```

原厂 U-Boot 却能正常读写同一颗芯片。

---

## 2. 关键证据：真实 raw ID 是 `cd 52 52`

U-Boot 的报错把三个字节直接打出来了：

```
unknown raw ID cd 52 52 cd
              ^^ ^^ ^^
              mfr dev dev  （第三个 cd 是驱动回读的冗余值）
```

拆解：

| 字节 | 值 | 含义 |
| --- | --- | --- |
| mfr | `0xCD` | FORESEE，**已在表里** |
| dev | `0x52` | **不在表里** |

对比 `drivers/mtd/nand/spi/foresee.c` 已有的两个型号：

| 型号 | ID | 页 | OOB | 块数 |
| --- | --- | --- | --- | --- |
| `F35SQA002G` | `0x72` | 2048 | 64 | 2048 |
| `F35SQA001G` | `0x71` | 2048 | 64 | 1024 |

**`0x52` 一个都没有。** 这就是根因。

---

## 3. 为什么读不到 ID（走了三条死路）

在动代码之前先想确认 ID，但原厂 U-Boot 的所有常规路径都堵死了：

| 尝试 | 结果 | 原因 |
| --- | --- | --- |
| `sf probe` | `Invalid chip select 0:0 (err=-19)` | `sf` 走 spi-nor 层，而这颗芯片挂在 NAND 驱动上 |
| `sf id` | `No SPI flash selected` | 同上 |
| `sspi 0:0.0@1000000 40 9f0000000000` | `Error -38 during SPI transaction` | `-ENOSYS`，通用 DM SPI 层不支持该控制器 |
| `spinand info` | 只打印子命令列表 | 该构建没编 info 子命令 |
| `md` / `md.b` | `Unknown command` | 该构建未启用内存显示命令 |

能用的只有 `mtd read` / `mtd dump` / `crc32`，它们能读数据但不暴露芯片 ID。

**所以 ID 是从 U-Boot 自己的报错里拿到的** —— 这反而是最可靠的来源，因为它是驱动实际发出的 READID 响应。

---

## 4. 修法

在 `drivers/mtd/nand/spi/foresee.c` 的表里加一条：

```c
SPINAND_INFO("F35SQB002G",
	     SPINAND_ID(SPINAND_READID_METHOD_OPCODE_DUMMY, 0x52, 0x52),
	     NAND_MEMORG(1, 2048, 64, 64, 2048, 40, 1, 1, 1),
	     NAND_ECCREQ(1, 512),
	     SPINAND_INFO_OP_VARIANTS(&read_cache_variants,
				      &write_cache_variants,
				      &update_cache_variants),
	     SPINAND_HAS_QE_BIT,
	     SPINAND_ECCINFO(&f35sqa002g_ooblayout,
			     f35sqa002g_ecc_get_status)),
```

### `NAND_MEMORG` 各参数怎么定的

```c
NAND_MEMORG(bpc, pages_per_eraseblock, pagesize, oobsize, eraseblocks_per_lun, ..., nand_dies, ..., nplanes)
```

| 参数 | 值 | 依据 |
| --- | --- | --- |
| `bpc` | 1 | 单 plane |
| `pages_per_eraseblock` | 2048 页? → 不，是 64 | 128 KiB 块 ÷ 2 KiB 页 = 64 页 |
| `pagesize` | 2048 | 原厂 `mtd list` 报 `min I/O: 0x800` |
| `oobsize` | 64 | 原厂 `mtd list` 报 `OOB size: 64 bytes` |
| `eraseblocks` | 2048 | 256 MiB ÷ 128 KiB = 2048 |
| `nand_dies` | 1 | 单 die |

### 为什么复用 `f35sqa002g_ooblayout` 和 `f35sqa002g_ecc_get_status`

这两个函数描述的是**页/OOB 布局和状态位解码方式**，不是具体的 die：

```c
static int f35sqa002g_ooblayout_free(struct mtd_info *mtd, int section,
                                     struct mtd_oob_region *region)
{
        if (section)
                return -ERANGE;

        /* Reserve 2 bytes for the BBM. */
        region->offset = 2;
        region->length = 62;      /* 64 - 2 */
        return 0;
}
```

同一 FORESEE 系列的 64 字节 OOB 型号布局一致，直接复用是对的。

---

## 5. 修完的效果

```
U-Boot 2026.07 (Nov 10 2026 - 12:13:46 +0800)
Loading Environment from UBI... spi-nand: spi_nand nand@0: FORESEE SPI NAND was found.
spi-nand: spi_nand nand@0: 256 MiB, block size: 128 KiB, page size: 2048, OOB size: 64
UBI partition 'ubi' already selected
```

`mtd list` 的完整输出：

```
* spi-nand0
  - device: nand@0
  - driver: spi_nand
  - type: NAND flash
  - block size: 0x20000 bytes     (128 KiB)
  - min I/O: 0x800 bytes          (2048)
  - OOB size: 64 bytes
  - OOB available: 62 bytes       ← 原厂报 0
  - ECC strength: 1 bits
  - ECC step size: 512 bytes
  - bitflip threshold: 1 bits
  - 0x000000000000-0x000010000000 : "spi-nand0"     (256 MiB)
	  - bootloader / bootflag / KernelA / RootfsA
	  - KernelB / RootfsB / ubi / frameworka
	  - frameworkb / factory
```

---

## 6. 与原厂驱动的三处差异

| 项 | 原厂 U-Boot 2023.04 | 我们的 U-Boot 2026.07 |
| --- | --- | --- |
| 驱动 | `aiorha-flash (legacy)`（驱动名有笔误） | `spi_nand`（通用层） |
| OOB available | **0 bytes** | **62 bytes** |
| 总容量 | `0xee00000` = 238 MiB | `0x10000000` = 256 MiB |
| ECC 报告 | 无 | strength 1, step 512, threshold 1 |

**原厂报 `OOB available: 0` 是它自己驱动的报告缺陷，不是物理限制。**
证据：原厂在同一颗芯片上正常跑着 UBI（`apps` 分区起始是 `55 42 49 23` = `UBI#`），
UBI 必然要写 OOB 里的坏块标记和 VID 头。

容量也一样：原厂只声明到 `0xee00000`，实际芯片是 256 MiB。

---

## 7. 与 SkyHigh 批次的对比

同一块主板，不同生产批次装了不同的闪存：

| | SkyHigh S35ML02G300 | FORESEE F35SQB002G |
| --- | --- | --- |
| mfr ID | `0x01` | `0xCD` |
| dev ID | `0x25` | **`0x52`** |
| OOB | 128 | 64 |
| 驱动文件 | `skyhigh.c` | `foresee.c` |

**两台机器的 U-Boot 二进制不能互刷** —— 各自需要对应的表项。
好在两个表项现在都在同一份源码里，一次编译同时支持两种芯片。

---

## 8. 可复用的排查手法

以后遇到「新批次闪存认不出」：

1. **先看 U-Boot 的报错原文**。`unknown raw ID xx yy yy` 直接把 mfr 和 dev 给出来了，比任何外部工具都快。
2. **查 `mtd list` 拿几何参数**（页、OOB、块大小、总容量）——这些能反过来推出 `NAND_MEMORG` 的每一项。
3. **不要指望 `sf` / `sspi`**：前者只覆盖 spi-nor，后者需要控制器支持 DM SPI 传输，ecnt 的 SNFI 都不满足。
4. **`mtd dump` 看 `UBI#` 魔数**：如果原厂在这颗芯片上跑 UBI，说明 BL2 侧已能识别，只是 U-Boot 侧缺表项。
