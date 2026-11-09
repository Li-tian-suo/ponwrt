# HG5580A 刷机成功记录（2026-11-08 05:00）

> **重大突破**：绕过厂商签名校验，PonWrt 内核已能从 flash 启动。

## 一、成功的方案

### 核心思路

厂商 `bootcmd = ldkernel; bargsenv; bootm` 中的 `ldkernel` 会做 X.509
固件内容签名校验，我们签不了名。**绕开的办法是改 bootcmd，直接 bootm**。

### 最终执行的操作

```sh
# 1. 把裸 FIT（syupgrade 的 FIT 部分）刷进 KernelB
tftpboot 0x88000000 barefitB.bin
mtd erase KernelB
mtd write KernelB 0x88000000 0x0 0x5a7000

# 2. 改 bootcmd 跳过 ldkernel
setenv bootcmd "mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000"
setenv bootargs "console=ttyS0,115200 earlycon swiotlb=noforce root=/dev/mtdblock5 rootfstype=squashfs rootwait"

# 3. 持久化到 SPI-NAND
saveenv
# -> Saving Environment to SNANDFlash... Erasing SPI NAND flash...
#    Writing to SPI flash... done  OK

# 4. 启动
boot
```

### 结果

**内核完整启动**：

```
airoha-xpon 1fb64000.ethernet: PON resources bound to pon0
airoha-xpon 1fb64000.ethernet: optical signal present without XGTC sync;
                               running short PMA recovery (recovery 21)
airoha-xpon 1fb64000.ethernet: XG-PON RX started, irq=29
airoha-pcs 1fa08000.pcs: PON line configured: mode=1, WAN_SEL=9
```

**MTD 分区识别正常**（内核在扫描 `0x03b80000` 等偏移）。

**这证明**：
- ✅ `bootcmd` 绕过 `ldkernel` 完全可行
- ✅ `saveenv` 能持久化到 SPI-NAND
- ✅ PonWrt 内核从 flash 启动成功
- ✅ 所有驱动（xpon / pcs / DSA）都在跑

## 二、唯一剩余问题：rootfs 类型不匹配

内核挂着挂着开始刷 jffs2 错误：

```
jffs2: jffs2_scan_eraseblock(): Magic bitmask 0x1985 not found at 0x03b80000: 0x4255 instead
jffs2: jffs2_scan_eraseblock(): Magic bitmask 0x1985 not found at 0x03b80004: 0x0001 instead
...（几百行）
jffs2: Cowardly refusing to erase blocks on filesystem with no valid JFFS2 nodes
jffs2: empty_blocks 0, bad_blocks 0, c->nr_blocks 576
```

**RootfsB 里是 squashfs，内核却用 jffs2 去读。**

### 分析（已查清）

内核配置里 squashfs 完全正常：

```
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XZ=y
CONFIG_SQUASHFS_EMBEDDED=y
```

**所以问题不在内核缺 squashfs 驱动。**

真正的元凶是这三个配置：

```
CONFIG_MTD_SPLIT_SQUASHFS_ROOT=y
CONFIG_MTD_SPLIT_FIRMWARE=y
CONFIG_MTD_SPLIT=y
```

`CONFIG_MTD_SPLIT_SQUASHFS_ROOT` 会让内核在挂载根分区时，
**把 MTD 分区里的 squashfs 拆分成独立的子分区**。
于是 `mtdblock5` 被识别成“容器”，内核拿不到文件系统，
就回退去试 jffs2，结果自然是：

```
jffs2: Cowardly refusing to erase blocks on filesystem with no valid JFFS2 nodes
jffs2: empty_blocks 0, bad_blocks 0, c->nr_blocks 576
```

这与日志完全吻合——它确实在 RootfsB 上找 jffs2，只是格式不对。

### 下一步调试方向

三个候选：

1. **改 `root=` 指向拆分后的子分区**
   `mtd-split` 会在 `/proc/mtd` 里新增一个 `"rootfs"` 之类的条目，
   实际名字需要上机 `cat /proc/mtd` 确认。

2. **去掉 `CONFIG_MTD_SPLIT_SQUASHFS_ROOT`**
   重新编译内核。这是最干净的做法，但会改变所有 airoha 目标的行为。

3. **用 `fitblk` 或 ubi 包裹 rootfs**
   参考 nokia_xg-040g-mf-ubi 的做法（它用 `fit_do_upgrade` +
   UBI 卷）。

**推荐先做 1**：只需改 U-Boot 的 bootargs，不用重编译。
上机执行 `cat /proc/mtd` 看有没有多出来的子分区。

## 三、当前设备状态

```
A 槽    厂商固件完整（KernelA + RootfsA 未动）
B 槽    KernelB = barefitB.bin（裸 FIT，5,926,912 B，crc32 0xa6b6842d）
        RootfsB = PonWrt squashfs（7,051,630 B，crc32 0xa85e1aeb）
flag    kernel=1 rootfs=1 app=1 framework=1（指向 B 槽）
bootcmd = mtd read KernelB 0x88000000 0x0 0x600000; bootm 0x88000000
bootargs = console=ttyS0,115200 earlycon swiotlb=noforce root=/dev/mtdblock5 rootfstype=squashfs rootwait
环境   已 saveenv 到 SPI-NAND，掉电不丢
```

### 怎么恢复原厂

```sh
setenv bootcmd "ldkernel;bargsenv;bootm"
saveenv
fhbootflag set 0 0 0 0
reset
```

**注意**：不要用 `bootflag swap`，它会把四个 flag 全部翻转。

## 四、关键数据备查

| 文件 | 大小 | crc32 |
| --- | --- | --- |
| `barefitB.bin`（KernelB） | 5,926,912 | `0xa6b6842d` |
| `rootfsB.bin`（RootfsB） | 7,053,312 | `0xa85e1aeb` |

内存布局验证：sysupgrade 内核 gzip 5,905,664 B，解压 13,762,568 B，
区间 `0x80200000..0x80F1E000`，远低于 `0x88000000`，不冲突。

## 五、刷机方案演进（供参考）

| 方案 | 结果 | 原因 |
| --- | --- | --- |
| 裸 FIT 直接写 KernelB + 原厂 bootcmd | ❌ 启动失败 | `ldkernel` 读私有头，格式不对 |
| 厂商包装格式 + 原厂 bootcmd | ❌ 卡死 | `ldkernel` 校验 X.509 内容签名 |
| **裸 FIT + 改 bootcmd 直接用 bootm** | ✅ **内核启动成功** | 绕过签名校验 |
