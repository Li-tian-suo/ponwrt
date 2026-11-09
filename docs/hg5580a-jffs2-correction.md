# HG5580A 启动日志解析更正：jffs2 报错来自 rootfs_data，不是 RootfsB

> 2026-11-08。上一版 `hg5580a-flash-success.md` 里我把 jffs2 报错
> 归因于“squashfs 根挂载失败、回退到 jffs2”，这个判断是**错的**。
> 本文给出基于数字的更正。

## 一、证据

启动日志里 jffs2 的收尾统计是：

```
jffs2: Cowardly refusing to erase blocks on filesystem with no valid JFFS2 nodes
jffs2: empty_blocks 0, bad_blocks 0, c->nr_blocks 576
```

`c->nr_blocks` 是被扫描分区的擦除块总数。本机 SPI-NAND 擦除块
是 128 KiB，用各分区大小反推：

| 分区 | 偏移 | 大小 | 擦除块数 |
| --- | --- | --- | --- |
| KernelB | 0x03100000 | 0x00600000 | 48 |
| RootfsB | 0x03700000 | 0x02800000 | 320 |
| apps | 0x05f00000 | 0x02000000 | 256 |
| **rootfs_data** | **0x07f00000** | **0x04800000** | **576** ← 完全吻合 |

**所以 jffs2 扫的是 `rootfs_data`，不是 `RootfsB`。**

## 二、更正后的启动流程

```
1. 内核把 /dev/mtdblock5（RootfsB，squashfs）挂成 /     ← 成功
2. fstools 去找 overlay 分区 rootfs_data
3. rootfs_data 里不是空的，开头是厂商的 UBI EC 头 "UBI#"
4. fstools 按 jffs2 去解析 → 576 块全是垃圾
5. "Cowardly refusing to erase blocks" → 不给格式化
6. 没有可写 overlay → 系统进受限模式
```

**根文件系统是好的，坏的是 overlay。**

这一点在 DTS 注释里其实早就记过：

> 第二段里原本不是空的：实测它的开头就是 UBI EC 头（`"UBI#"`），
> 72 MiB 全部非空，是厂商在那 104 MiB 里放的 UBI 数据卷。

## 三、影响

| 之前的结论 | 更正 |
| --- | --- |
| `linux,rootfs` 是修根挂载的关键 | **不是必需的**（加了也无害，属于双保险） |
| squashfs 挂不上 | **能挂上** |
| 系统完全起不来 | 起得来，但没有可写 overlay，配置存不住 |

所以真正要解决的是 **overlay 分区里有厂商 UBI 残留**。

## 四、两个修法

### 方案 A（一次性，最快）

在 U-Boot 里擦掉这个分区：

```
mtd erase rootfs_data
```

擦完 `rootfs_data` 就是全 0xFF，fstools 能正常格式化成 jffs2。
只需做一次。

**代价**：会永久丢掉厂商那 72 MiB UBI 数据卷的内容。
按 DTS 注释，这段已完整备份到 `backup/rootfs_data.bin`，
并按每块设备的 CRC32 逐个偏移验证过（288 个偏移全部吻合），
真需要可以写回。

### 方案 B（改 DTS，和 nokia 板一样用 UBI）

把 `rootfs_data` 换成 `ubi` 卷方案，参考 `target/linux/airoha/image/an7583.mk`
里的 `nokia_xg-040g-mf-ubi`。这样 overlay 走 UBI，不用 jffs2。

**优点**：不依赖擦除，UBI 自己管理坏块，更适合 NAND。
**代价**：要改分区布局、换镜像格式，改动面大。

## 五、下次刷机的正确步骤

```
# 1. 刷两个分区（脚本已备好）
#    barefitB.bin  -> KernelB   crc32 0xec6fcf53
#    rootfsB.bin   -> RootfsB   crc32 0x46020fe0

# 2. 关键：擦掉 overlay 分区里的厂商残留
mtd erase rootfs_data

# 3. 重启
reset
```

第 2 步是我之前漏掉的，也是这次启动“看起来失败”的真正原因。

## 六、验证成功的标志

重启后 dmesg 里应该看到：

```
mtd: setting mtd5 (RootfsB) as root device      # linux,rootfs 生效
...
[  ok ] Starting uhttpd                          # 网页能开
```

并且**不再出现** `Cowardly refusing to erase blocks`。

如果 `rootfs_data` 擦干净了，fstools 会打印类似：

```
jffs2: notice: (xxx) jffs2_build_xattr_subsystem: complete building xattr subsystem
```

而不是一堆 magic bitmask 错误。
