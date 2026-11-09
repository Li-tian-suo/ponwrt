# HG5380A vs HG5580A 硬件对照

> 两台都是 FiberHome 基于 Airoha AN7583 的 10G PON 光猫。
> 本文只列**有依据**的差异，依据写在备注里。

## 一、总览

| 项目 | HG5380A | HG5580A | 差异影响 |
| --- | --- | --- | --- |
| SoC | Airoha **AN7583** | Airoha **AN7583** | 相同 |
| CPU | Cortex-A53 ×2 | Cortex-A53 ×2 | 相同 |
| 内存 | **512 MiB** @0x80000000 | **512 MiB** @0x80000000 | 相同 |
| 闪存 | SPI-NAND 128 MiB | SPI-NAND **256 MiB** | 5580A 更大 |
| 擦除块 | 128 KiB | 128 KiB | 相同 |
| 页大小 | 2 KiB | 2 KiB | 相同 |

闪存型号（5580A，U-Boot 实测）：

```
Detected SPI NAND Flash : _SPI_NAND_DEVICE_ID_S35ML02G3, Flash Size=0x10000000
mfr_id=0x1, dev_id=0x25
```

`0x10000000` = 256 MiB。5380A 是 `0x8000000` = 128 MiB。

---

## 二、关键差异：2.5G PHY

| 项目 | HG5380A | HG5580A |
| --- | --- | --- |
| 型号 | **Airoha EN8811H** | **Motorcomm YT8821** |
| MDIO 地址 | `0xf` | `0x07` |
| compatible | `ethernet-phy-id03a2.a411` | 由 motorcomm 驱动匹配 |
| phy-mode | `2500base-x` | `2500base-x` |
| 所在端口 | lan1 | lan1 |
| 内核驱动 | `kmod-phy-airoha-en8811h` | `kmod-phy-motorcomm` |

5580A 实测：

```
airoha_eth 1fb50000.ethernet lan1: PHY [1fb00000.system-controller:mdio-bus@c8-mii:07]
                                  driver [YT8821 2.5Gbps PHY] (irq=POLL)
lan1: configuring for phy/2500base-x link mode
lan1: Link is Up - 2.5Gbps/Full - flow control rx/tx
```

**这是两个机型最容易搞错的地方**：设备树里的 PHY 地址和驱动包完全不同。
用 5380A 的 DTS 刷 5580A，lan1 不会起来。

### 2.5G PHY 的一个坑（5580A）

**U-Boot 里的 YT8821 只跑 100M**：

```
U-Boot> mii info 7
PHY 0x07: OUI = 0x13D47A, Model = 0x21, Rev = 0x09, 100baseT, FDX
```

所以刷机时 PC 网卡必须固定 100M，否则 TFTP 不通。
内核起来后是正常的 2.5G。

---

## 三、光模块（BOSA）

| 项目 | HG5380A | HG5580A |
| --- | --- | --- |
| 型号 | 待确认（`hg5x-bosa`） | **UX3363** |
| I2C 地址 | `0x51` | `0x51` |
| compatible | `fiberhome,hg5x-bosa`, `airoha,paged-bosa` | `airoha,paged-bosa` |
| 校准分区 | 无独立分区 | **`bosacal`**（128 KiB） |
| 校准格式 | — | 厂商私有 `fiberhomebdbob` |

5580A 实测：

```
airoha-paged-bosa 0-0051: UX3363 frontend registered, ID 55583333363331, calibration invalid
```

**`calibration invalid` 是真实问题**：`bosacal` 分区里是厂商私有格式
（`fiberhomebdbob` + `202404291559VB`），不是 Airoha paged-bosa 期望的格式。
光功率读数会不准，但不影响 PON 协议栈启动。

---

## 四、分区表差异

| 分区 | HG5380A | HG5580A |
| --- | --- | --- |
| bootloader | 0x0 +0x280000 | 0x0 +0x280000 |
| bootflag | 0x280000 +0x80000 | 0x280000 +0x80000 |
| KernelA | 0x300000 +0x600000 | 0x300000 +0x600000 |
| RootfsA | 0x900000 +0x2800000 | 0x900000 +0x2800000 |
| KernelB | 0x3100000 +0x600000 | 0x3100000 +0x600000 |
| RootfsB | 0x3700000 +0x2800000 | 0x3700000 +0x2800000 |
| apps | 0x5F00000 +**0x6800000** | 0x5F00000 +**0x2000000** |
| **bosacal** | ❌ 无 | **0xEC00000 +0x20000** |
| **identity** | ❌ 无 | **0xEC20000 +0x20000** |
| **rootfs_data / overlay** | ❌ 无 | **0x7F00000 +0x4800000** |
| frameworka | 0xC700000 +0x1000000 | 0xC700000 +0x1000000 |
| frameworkb | 0xD700000 +0x1000000 | 0xD700000 +0x1000000 |
| factory | 0xE700000 +0x500000 | 0xE700000 +0x500000 |

### 5580A 的 `apps` 被切成三段

厂商 U-Boot 的分区表里 `apps` 是**整段** 104 MiB：

```
0x000005f00000-0x00000c700000 : "apps"
```

PonWrt 的设备树把它切成两段，合计正好等于厂商那一段：

```
apps        0x5F00000 +0x2000000   32 MiB
overlay     0x7F00000 +0x4800000   72 MiB   <- OpenWrt 的 overlay
```

**`overlay` 这个分区原本装的是厂商的 UBI 数据卷**（开头 `UBI#`，
约 15.4 MiB 真实数据）。已完整备份到 `backup/rootfs_data.bin`
（75,497,472 B，288 个擦除块偏移全部 CRC 校验吻合）。

### 为什么 overlay 分区要改名

OpenWrt 的 `fstools` 默认找名字是 `rootfs_data` 的分区做 overlay。
但 5580A 上 `mtd6`（squashfs-split 从 RootfsB 尾部自动切出来的那段）
有一个 ECC 不可纠正的坏块：

```
jffs2: cannot read OOB for EB at 020e0000, requested 8 bytes, read 8 bytes, error -74
mount_root: failed to mount -t jffs2 /dev/mtdblock6 /tmp/overlay: I/O error
```

`-74` 是 `EBADMSG`。所以把 72 MiB 那段改名为 `overlay`，并在 bootargs 里
指定 `fstools_overlay_name=overlay`，避开坏块区。

---

## 五、无线

| 项目 | HG5380A | HG5580A |
| --- | --- | --- |
| WiFi 芯片 | **MediaTek MT7916**（2×2，WED 卸载） | ❌ **无** |
| 固件 | `WIFI_RAM_CODE_MT7916.bin` 等 | — |
| 设备树 | `wed` / `wed2` 节点 | 无 |

**5580A 没有无线硬件。** 这是最直观的差别：5380A 是 WiFi 光猫，
5580A 是有线光猫。

所以 5580A 的 DTS 不需要 wifi 相关节点，也不用装 `kmod-mt7916`、
`wpad`、hostapd 等。

---

## 六、PON 侧

| 项目 | HG5380A | HG5580A |
| --- | --- | --- |
| 原厂 PON 驱动 | `fhdrv_pon_dev.ko` / `fhdrv_pon_drv.ko` / `fhdrv_pon_service.ko` + `libxpon.so` | 同类私有模块 |
| PonWrt 驱动 | `airoha-xpon`（开源） | `airoha-xpon`（开源） |
| 本机 PON 类型 | 待确认 | **GPON**（`pon_mode=2`） |
| 光模块型号 | 待确认 | UX3363 |

5580A 的 PON 身份（从 `factory` UBI 卷的 `factory_conf` 读出）：

```
GponSN         = 46485454C255B8F9     ("FHTT" + C2:55:B8:F9)
GPONPassWord   = 48473236303132333435 ("HG26012345")
pon_mode       = 2                    (GPON)
transceiver_type   = PLDM588-815-C10
transceiver_serial = 000059BTK39007495
```

**开源 `airoha-xpon` 没有 GPON 实现**，所以 5580A 光口无法同步。
详见 `docs/hg5580a-gpon-feasibility.md`。

---

## 七、MAC 地址分配

5580A 的真实值（`factory` UBI 卷 `factory_conf`）：

```
APMAC_1 / APMAC_2   00:0a:c2:d6:00:00    （无 WLAN，无意义）
macnum              12

brmac               24:E3:A4:96:2F:20    <- 桥 / gdm1 / pon0
base_mac            24:E3:A4:96:2F:20
ponmac              24:E3:A4:96:2F:20
internetmac         24:E3:A4:96:2F:21
tr069mac            24:E3:A4:96:2F:22
voipmac             24:E3:A4:96:2F:23
priprotocolmac      24:E3:A4:96:2F:24

eth1mac             24:E4:A4:96:2F:41    <- 注意 OUI 不同！
eth2mac             24:E4:A4:96:2F:42
eth3mac             24:E4:A4:96:2F:43
eth4mac             24:E4:A4:96:2F:44
```

**厂商给网口用的是 `24:E4:A4`，与桥的 `24:E3:A4` 不是一个 OUI。**

而驱动 `airoha_set_macaddr()` 要求同一控制器上所有 GDM 的高 3 字节一致，
否则拒绝：

```
airoha_eth 1fb50000.ethernet: eth1: wrong mac addr, MSBs must be 24:e3:a4
```

**厂商自己的数据违反了自己的驱动约束。** 目前的处理是用 `brmac` 末字节 +1
派生 lan1 的地址（`24:E3:A4:96:2F:21`），放弃 `eth1mac` 的 OUI。

---

## 八、适配难度对比

| 方面 | HG5380A | HG5580A |
| --- | --- | --- |
| SoC / 内存 / 分区骨架 | 一致 | 一致 |
| 2.5G PHY 驱动 | EN8811H | **YT8821（不同驱动）** |
| DTS | 已有 | 需按 PHY/光模块改写 |
| 无线 | MT7916 需 wifi 支持 | 无需 |
| overlay 分区 | 无（用 apps 剩余空间？） | 需独立 overlay + 避开坏块 |
| MAC 来源 | 待确认 | identity 全 0xFF，需从 factory 提取 |
| PON | 同样缺 GPON | 同样缺 GPON |

**结论**：5580A 的适配工作是「换 PHY + 换光模块 + 加 overlay 分区 +
补 MAC 来源」，SoC 和引导链完全复用 5380A 的经验。
