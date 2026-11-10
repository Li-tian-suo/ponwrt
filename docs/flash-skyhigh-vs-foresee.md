# 闪存差异说明：SkyHigh vs FORESEE

> 同一块 AN7583 主板，两个批次的 SPI-NAND 不同。
> 本文记录两者的实测参数、驱动支持情况和由此产生的约束。

---

## 1. 实测对比

| 项 | SkyHigh S35ML02G300 | FORESEE F35SQB002G |
| --- | --- | --- |
| 厂商 ID | `0x01` | `0xCD` |
| 器件 ID | `0x25` | 待确认 |
| 页大小 | 2048 | 2048 |
| **OOB** | **128** | **64** |
| 块大小 | 128 KiB | 128 KiB |
| ECC 位置 | 隐藏区 | 见下 |
| 可用 OOB | 126 字节 | 驱动报 0 |
| 报告容量 | 256 MiB | 238 MiB (`0xee00000`) |

---

## 2. SkyHigh S35ML02G300（旧批次）

驱动：`drivers/mtd/nand/spi/skyhigh.c`

```c
#define SPINAND_MFR_SKYHIGH   0x01

SPINAND_INFO("S35ML02G3", SPINAND_ID(..., 0x25),
             /* pagesize 2048, oobsize 128 */
             ...)
```

OOB 布局：

```c
static int skyhigh_spinand_ooblayout_ecc(struct mtd_info *mtd,
                                          int section,
                                          struct mtd_oob_region *region)
{
        return -ERANGE;      /* ECC 全部在隐藏区 */
}

static int skyhigh_spinand_ooblayout_free(struct mtd_info *mtd,
                                           int section,
                                           struct mtd_oob_region *region)
{
        if (section)
                return -ERANGE;

        region->offset = 2;
        region->length = mtd->oobsize - 2;    /* 128 - 2 = 126 */
        return 0;
}
```

**结论：128 字节 OOB 里 126 字节完全可用**（前 2 字节留作坏块标记）。
这是一个相当宽松的布局 —— ECC 不占主 OOB，文件系统想用什么就能用什么。

驱动还带 `SPINAND_NO_RAW_ACCESS`，意味着不能做 raw 读写。

---

## 3. FORESEE F35SQB002G（新批次）

驱动：`drivers/mtd/nand/spi/foresee.c`

```c
#define SPINAND_MFR_FORESEE   0xCD

SPINAND_INFO("F35SQA002G", SPINAND_ID(..., 0x72, 0x72),
             NAND_MEMORG(1, 2048, 64, 64, 2048, 40, 1, 1, 1), ...)

SPINAND_INFO("F35SQA001G", SPINAND_ID(..., 0x71, 0x71),
             NAND_MEMORG(1, 2048, 64, 64, 1024, 20, 1, 1, 1), ...)
```

OOB 布局：

```c
static int f35sqa002g_ooblayout_ecc(struct mtd_info *mtd, int section,
                                     struct mtd_oob_region *region)
{
        return -ERANGE;
}

static int f35sqa002g_ooblayout_free(struct mtd_info *mtd, int section,
                                      struct mtd_oob_region *region)
{
        if (section)
                return -ERANGE;

        /* Reserve 2 bytes for the BBM. */
        region->offset = 2;
        region->length = 62;        /* 64 - 2 */
        return 0;
}
```

**注意 `region->length = 62` 是硬编码的**，不是 `mtd->oobsize - 2`。
如果实际芯片 OOB 不是 64，这个值就是错的。

ECC 状态解析：

```c
static int f35sqa002g_ecc_get_status(struct spinand_device *spinand, u8 status)
{
        switch (status & STATUS_ECC_MASK) {
        case STATUS_ECC_NO_BITFLIPS:
                return 0;
        case STATUS_ECC_HAS_BITFLIPS:
                return nanddev_get_ecc_conf(nand)->strength;
        default:
                return -EBADMSG;        /* 不可纠正 */
        }
}
```

只有一个可纠正位翻转的档位，其余全部报 `-EBADMSG`。

---

## 4. `OOB available: 0 bytes` 是怎么回事

原厂 U-Boot 2023.04 在 FORESEE 机器上报：

```
- OOB size: 64 bytes
- OOB available: 0 bytes
```

看起来像「OOB 完全不可用」，那样 UBI 就无法工作。但实测

```
mtd dump apps 0x0 0x800
0x00000000:  55 42 49 23 01 00 00 00  00 00 00 00 00 00 00 00
```

`apps` 分区开头就是 `UBI#`，**原厂在这颗芯片上正常跑着 UBI**。

所以 `OOB available: 0` 是 ecnt legacy NAND 驱动（`aiorha-flash (legacy)`，
注意驱动名里有个拼写错误）的报告方式，不是物理约束。新版 U-Boot 走的是
`drivers/mtd/nand/spi/` 的通用层，不会受这个值影响。

---

## 5. 容量差异

| 来源 | 值 |
| --- | --- |
| 器件型号标称 | 2 Gbit = 256 MiB |
| 原厂 U-Boot 报告 | `0xee00000` = 238 MiB |
| `apps` 结束地址 | `0xc700000` = 199 MiB |

分区表最后一项 `factory` 结束于 `0xec00000` = 236 MiB，也在 238 MiB 之内。
所以实际可用范围是 236 MiB，与报告的 238 MiB 吻合。

按 238 MiB 规划是安全的；不要假设 256 MiB 全可用。

---

## 6. 对文件系统选择的影响

| | SkyHigh | FORESEE |
| --- | --- | --- |
| 可用 OOB | 126 字节 | 62 字节（按新版驱动） |
| UBI | ✅ | ✅ 实测原厂在用 |
| JFFS2 | 理论可行 | OOB 少，ECC 档位少，风险更高 |

旧批次上 JFFS2 的结论**不能直接套到新批次**：OOB 从 126 降到 62，
且 `ecc_get_status` 只有「无错 / 可纠正 / 不可纠正」三档，没有更细的错误计数。
JFFS2 需要写 OOB 中的 cleanmarker 和坏块信息，空间紧得多。

**UBI 在两个批次上都已确认可用**，所以固件统一走 UBI。

---

## 7. 认出芯片的前提

BL2 和 U-Boot 各有一张独立的表，两边都必须命中：

### BL2（TF-A）

```
tf-a/plat/ecnt/common/drivers/flash/spi_nand_flash_table.c
```

BL2 是**最危险的一半** —— 它在一切之前运行，认不出芯片就写不了 bootloader
分区，写下去直接变砖。

现有 FORESEE 表项：

```c
mfr 0xCD + dev 0xA1   FS35ND01GD1F1   1 Gbit   OOB 64
mfr 0xCD + dev 0xA2   FS35ND02GS2F1   2 Gbit   OOB 128
mfr 0xCD + dev 0xB2   FS35ND02GD1F1   2 Gbit   OOB 128
```

SkyHigh 表项：

```c
mfr 0x01 + dev 0x25   S35ML02G3
```

### U-Boot

```
drivers/mtd/nand/spi/foresee.c    0x72  F35SQA002G
                                  0x71  F35SQA001G
drivers/mtd/nand/spi/skyhigh.c    0x25  S35ML02G3
```

### `F35SQB002G` 的缺口

型号不在任何一张表里。两种可能：

1. **它的 ID 恰好等于某个已有表项**（最可能 `0xA2` 或 `0xB2`，都是 2 Gbit）
   → 直接能识别，不需要改代码
2. **ID 不在表里** → 需要在 U-Boot 加 `foresee.c` 表项，BL2 加表项

因为原厂 BL2 能识别它（UBI 正常工作），所以 BL2 侧肯定有对应项。
U-Boot 侧是否命中，要在实机上启动一次才知道。

---

## 8. 为什么读不到 READID

实机尝试过的路径全部失败：

| 命令 | 结果 | 原因 |
| --- | --- | --- |
| `sf probe` | `-19` (`ENODEV`) | 走 spi-nor 层，而芯片挂在 NAND 驱动上 |
| `sspi 0:0.0@1000000 40 9f...` | `-38` (`ENOSYS`) | 通用 DM SPI 层不支持该控制器 |
| `md` / `md.b` | 命令不存在 | 该 U-Boot 构建未启用 |
| `spinand info` | 只打子命令列表 | 该构建没有 info 子命令 |

能用的只有 `mtd dump`（能读数据，不暴露 ID）和 `crc32`。

### 替代取 ID 的方法

1. **原厂 Linux 侧**：`dmesg | grep -i -E 'nand|spi'` 通常会打印
   `mfr=0xcd dev=0x..`，这是最省事的路径
2. **`loglevel=9` 下重新触发 probe**：`setenv loglevel 9` 后 `mtd list`，
   legacy 驱动可能打印表项匹配
3. **逻辑分析仪**抓 SPI 总线上的 READID (0x9F) 响应

---

## 9. 结论

| 问题 | 答案 |
| --- | --- |
| UBI 在新批次能用吗 | ✅ 能，原厂已在用 |
| 必须刷 BL2 才能用 PonWrt 吗 | ❌ 不必。FIP 写进 UBI 的 `fip` 卷即可 |
| 刷 BL2 前必须确认什么 | BL2 能识别该芯片的 device ID |
| 闪存差异影响固件吗 | 不影响。UBI 参数（页/块/LEB）由 BL2 和 U-Boot 从芯片读，固件不关心 |
